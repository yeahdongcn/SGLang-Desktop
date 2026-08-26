import Foundation
import Testing

@testable import SGLangDesktopCore

@Test func prebuiltManifestRequiresArchiveChecksumAtInstallTime() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-desktop-installer-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let archive = root.appending(path: "runtime.tar.gz")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-an-archive".utf8).write(to: archive)

    let manifest = RuntimeManifest(
        id: "test-runtime",
        displayName: "Test Runtime",
        engine: .sglang,
        version: "1",
        distribution: .prebuilt,
        entrypoint: "bin/sglang"
    )
    let paths = AppPaths(root: root.appending(path: "data"))
    let library = RuntimeLibrary(paths: paths)
    let installer = RuntimeArtifactInstaller()

    await #expect(throws: RuntimeArtifactInstallerError.missingArchiveChecksum) {
        try await installer.install(
            archiveURL: archive,
            manifest: manifest,
            paths: paths,
            runtimeLibrary: library
        )
    }
}

@Test func installsAndRegistersAValidArchiveWithoutSelfReferentialHash() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sglang-desktop-installer-valid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = root.appending(path: "payload", directoryHint: .isDirectory)
    let runtimeRoot = payload.appending(path: "runtime", directoryHint: .isDirectory)
    let executable = runtimeRoot.appending(path: "bin/sglang")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let identity = RuntimeManifest(
        id: "test-runtime",
        displayName: "Test Runtime",
        engine: .sglang,
        version: "1",
        distribution: .prebuilt,
        entrypoint: "bin/sglang"
    )
    try JSONEncoder().encode(identity).write(to: runtimeRoot.appending(path: "runtime.json"))

    let archive = root.appending(path: "runtime.tar.gz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", archive.path, "-C", payload.path, "runtime"]
    try tar.run()
    tar.waitUntilExit()
    #expect(tar.terminationStatus == 0)

    let archiveSize = try FileManager.default.attributesOfItem(atPath: archive.path)[.size]
    let catalogManifest = RuntimeManifest(
        id: identity.id,
        displayName: identity.displayName,
        engine: identity.engine,
        version: identity.version,
        distribution: .prebuilt,
        entrypoint: identity.entrypoint,
        archiveSizeBytes: (archiveSize as? NSNumber)?.int64Value,
        sha256: try SHA256Checksum.digest(fileAt: archive)
    )
    let paths = AppPaths(root: root.appending(path: "data"))
    let library = RuntimeLibrary(paths: paths)
    let installation = try await RuntimeArtifactInstaller().install(
        archiveURL: archive,
        manifest: catalogManifest,
        paths: paths,
        runtimeLibrary: library
    )

    #expect(installation.manifest.id == "test-runtime")
    #expect(FileManager.default.isExecutableFile(atPath: installation.executableURL.path))
    #expect(try await library.installations().count == 1)
}
