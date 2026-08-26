import Foundation

public struct RuntimeInstallProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case verifying
        case extracting
        case registering
    }

    public let phase: Phase
    public let fractionCompleted: Double
    public let message: String

    public init(phase: Phase, fractionCompleted: Double, message: String) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.message = message
    }
}

/// Installs a runtime archive without invoking a package manager.
///
/// The archive is verified and extracted into a private staging directory. The
/// final runtime directory is moved into place only after its manifest and
/// executable have been validated. Existing installations are never replaced.
public actor RuntimeArtifactInstaller {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func install(
        archiveURL: URL,
        manifest: RuntimeManifest,
        paths: AppPaths,
        runtimeLibrary: RuntimeLibrary,
        progress: @escaping @Sendable (RuntimeInstallProgress) -> Void = { _ in }
    ) async throws -> RuntimeInstallation {
        try manifest.validate()
        guard fileManager.isReadableFile(atPath: archiveURL.path) else {
            throw RuntimeArtifactInstallerError.archiveNotReadable(archiveURL)
        }

        try paths.createRequiredDirectories(fileManager: fileManager)
        let staging = paths.runtimeStaging.appending(
            path: "install-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let extractionRoot = staging.appending(path: "extracted", directoryHint: .isDirectory)
        let stagedArchive = staging.appending(path: "runtime.tar.gz")
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        // Hash, list, and extract the same private copy to avoid a path-swap
        // race against a mutable download location.
        try fileManager.copyItem(at: archiveURL, to: stagedArchive)
        progress(
            RuntimeInstallProgress(
                phase: .verifying,
                fractionCompleted: 0,
                message: "Checking runtime archive"
            )
        )
        try verifyArchive(archiveURL: stagedArchive, manifest: manifest)

        progress(
            RuntimeInstallProgress(
                phase: .extracting,
                fractionCompleted: 0.2,
                message: "Extracting verified runtime"
            )
        )
        try validateArchiveEntries(archiveURL: stagedArchive)
        try runTar(arguments: ["-xzf", stagedArchive.path, "-C", extractionRoot.path])

        let runtimeRoot = try locateRuntimeRoot(
            extractionRoot: extractionRoot,
            expectedManifest: manifest
        )
        let installedManifest = try decodeManifest(at: runtimeRoot.appending(path: "runtime.json"))
        guard installedManifest.matchesRuntimeIdentity(manifest) else {
            throw RuntimeArtifactInstallerError.manifestMismatch
        }
        try validateExtractedTree(runtimeRoot: runtimeRoot, manifest: manifest)

        let destination = paths.runtimes
            .appending(path: manifest.id, directoryHint: .isDirectory)
            .appending(path: manifest.version, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RuntimeArtifactInstallerError.installationAlreadyExists(destination)
        }

        progress(
            RuntimeInstallProgress(
                phase: .registering,
                fractionCompleted: 0.85,
                message: "Activating runtime generation"
            )
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: runtimeRoot, to: destination)

        let installation = RuntimeInstallation(manifest: manifest, rootDirectory: destination)
        do {
            try await runtimeLibrary.register(installation)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        progress(
            RuntimeInstallProgress(
                phase: .registering,
                fractionCompleted: 1,
                message: "Runtime is ready"
            )
        )
        return installation
    }

    private func verifyArchive(archiveURL: URL, manifest: RuntimeManifest) throws {
        if let expectedSize = manifest.archiveSizeBytes {
            let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value
            guard actualSize == expectedSize else {
                throw RuntimeArtifactInstallerError.archiveSizeMismatch(
                    expected: expectedSize,
                    actual: actualSize ?? -1
                )
            }
        }
        if let expectedSHA256 = manifest.sha256 {
            guard try SHA256Checksum.verify(fileAt: archiveURL, expected: expectedSHA256) else {
                throw RuntimeArtifactInstallerError.archiveChecksumMismatch
            }
        } else if manifest.distribution == .prebuilt {
            throw RuntimeArtifactInstallerError.missingArchiveChecksum
        }
    }

    private func validateArchiveEntries(archiveURL: URL) throws {
        let listing = try runTar(arguments: ["-tzf", archiveURL.path])
        for rawEntry in listing.split(whereSeparator: \.isNewline) {
            let entry = String(rawEntry)
            guard !entry.isEmpty, !entry.hasPrefix("/") else {
                throw RuntimeArtifactInstallerError.unsafeArchiveEntry(entry)
            }
            let components = entry.split(separator: "/")
            guard !components.contains("..") else {
                throw RuntimeArtifactInstallerError.unsafeArchiveEntry(entry)
            }
        }
    }

    private func locateRuntimeRoot(
        extractionRoot: URL,
        expectedManifest: RuntimeManifest
    ) throws -> URL {
        let directManifest = extractionRoot.appending(path: "runtime.json")
        if fileManager.fileExists(atPath: directManifest.path) {
            return extractionRoot
        }

        let children = try fileManager.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = try children.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        guard directories.count == 1 else {
            throw RuntimeArtifactInstallerError.runtimeRootNotFound(expectedManifest.id)
        }
        let nestedManifest = directories[0].appending(path: "runtime.json")
        guard fileManager.fileExists(atPath: nestedManifest.path) else {
            throw RuntimeArtifactInstallerError.runtimeRootNotFound(expectedManifest.id)
        }
        return directories[0]
    }

    private func decodeManifest(at url: URL) throws -> RuntimeManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    private func validateExtractedTree(
        runtimeRoot: URL,
        manifest: RuntimeManifest
    ) throws {
        let root = runtimeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: runtimeRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
        else {
            throw RuntimeArtifactInstallerError.runtimeTreeInvalid(runtimeRoot.path)
        }

        var entryCount = 0
        while let item = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= 500_000 else {
                throw RuntimeArtifactInstallerError.runtimeTreeTooLarge
            }
            let values = try item.resourceValues(forKeys: keys)
            guard
                values.isDirectory == true
                    || values.isRegularFile == true
                    || values.isSymbolicLink == true
            else {
                throw RuntimeArtifactInstallerError.unsupportedArchiveEntry(item.path)
            }
            if values.isSymbolicLink == true {
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path == root.path || resolved.path.hasPrefix(rootPrefix),
                    fileManager.fileExists(atPath: resolved.path)
                else {
                    throw RuntimeArtifactInstallerError.escapingSymbolicLink(item.path)
                }
            }
        }

        let manifestURL = runtimeRoot.appending(path: "runtime.json")
        let executableURL = runtimeRoot.appending(path: manifest.entrypoint)
        try requireRegularFileInsideRoot(manifestURL, rootPrefix: rootPrefix)
        try requireRegularFileInsideRoot(executableURL, rootPrefix: rootPrefix)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw RuntimeArtifactInstallerError.entrypointNotExecutable(executableURL)
        }
    }

    private func requireRegularFileInsideRoot(
        _ url: URL,
        rootPrefix: String
    ) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw RuntimeArtifactInstallerError.runtimeTreeInvalid(url.path)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw RuntimeArtifactInstallerError.runtimeTreeInvalid(url.path)
        }
    }

    @discardableResult
    private func runTar(arguments: [String]) throws -> String {
        let operationID = UUID().uuidString
        let stdoutURL = fileManager.temporaryDirectory.appending(
            path: "sglang-desktop-tar-\(operationID).stdout"
        )
        let stderrURL = fileManager.temporaryDirectory.appending(
            path: "sglang-desktop-tar-\(operationID).stderr"
        )
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
        else {
            throw RuntimeArtifactInstallerError.archiveExtractionFailed(
                "Could not create temporary output files."
            )
        }
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        let stdout = try Data(contentsOf: stdoutURL)
        let stderr = try Data(contentsOf: stderrURL)
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? "tar failed"
            throw RuntimeArtifactInstallerError.archiveExtractionFailed(message)
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }
}

public enum RuntimeArtifactInstallerError: LocalizedError, Equatable {
    case archiveNotReadable(URL)
    case archiveSizeMismatch(expected: Int64, actual: Int64)
    case archiveChecksumMismatch
    case missingArchiveChecksum
    case unsafeArchiveEntry(String)
    case archiveExtractionFailed(String)
    case runtimeRootNotFound(String)
    case manifestMismatch
    case installationAlreadyExists(URL)
    case runtimeTreeInvalid(String)
    case runtimeTreeTooLarge
    case unsupportedArchiveEntry(String)
    case escapingSymbolicLink(String)
    case entrypointNotExecutable(URL)

    public var errorDescription: String? {
        switch self {
        case .archiveNotReadable(let url):
            "Runtime archive is not readable: \(url.path)"
        case .archiveSizeMismatch(let expected, let actual):
            "Runtime archive size mismatch (expected \(expected), got \(actual))."
        case .archiveChecksumMismatch:
            "Runtime archive SHA-256 verification failed."
        case .missingArchiveChecksum:
            "A prebuilt runtime must declare an archive SHA-256 checksum."
        case .unsafeArchiveEntry(let entry):
            "Runtime archive contains an unsafe path: \(entry)"
        case .archiveExtractionFailed(let message):
            "Runtime archive extraction failed: \(message)"
        case .runtimeRootNotFound(let id):
            "Runtime root for \(id) was not found after extraction."
        case .manifestMismatch:
            "The extracted runtime manifest does not match the catalog manifest."
        case .installationAlreadyExists(let url):
            "That runtime generation is already installed: \(url.path)"
        case .runtimeTreeInvalid(let path):
            "The extracted runtime tree is invalid: \(path)"
        case .runtimeTreeTooLarge:
            "The extracted runtime contains too many filesystem entries."
        case .unsupportedArchiveEntry(let path):
            "The runtime archive contains an unsupported filesystem entry: \(path)"
        case .escapingSymbolicLink(let path):
            "The runtime archive contains a symbolic link that escapes its root: \(path)"
        case .entrypointNotExecutable(let url):
            "The runtime entrypoint is not executable: \(url.path)"
        }
    }
}
