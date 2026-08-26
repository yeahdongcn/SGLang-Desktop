import CryptoKit
import Foundation

public struct LocalRuntimeAdopter: Sendable {
    public init() {}

    public func makeInstallation(
        executableURL: URL,
        engine: EngineKind? = nil,
        displayName: String? = nil,
        stableIdentity: String? = nil
    ) throws -> RuntimeInstallation {
        let executable = executableURL.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalRuntimeAdopterError.notExecutable(executable)
        }

        let inferredEngine = try engine ?? inferEngine(from: executable.lastPathComponent)
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        let relativeEntrypoint = try relativePath(of: executable, under: root)
        let identifier = stableIdentity ?? UUID().uuidString.lowercased()
        let manifest = RuntimeManifest(
            id: "local-\(inferredEngine.rawValue)-\(identifier)",
            displayName: displayName ?? "Local \(inferredEngine.displayName)",
            engine: inferredEngine,
            version: identifier,
            channel: .local,
            distribution: .localVirtualEnvironment,
            artifactKind: .complete,
            containsNativeCode: true,
            entrypoint: relativeEntrypoint,
            capabilities: ["developer-managed"]
        )
        try manifest.validate()
        return RuntimeInstallation(manifest: manifest, rootDirectory: root)
    }

    public func stableIdentity(for executableURL: URL) -> String {
        let digest = SHA256.hash(data: Data(executableURL.standardizedFileURL.path.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func inferEngine(from executableName: String) throws -> EngineKind {
        switch executableName {
        case "sgl-omni":
            .sglangOmni
        case "sglang":
            .sglang
        default:
            throw LocalRuntimeAdopterError.unknownEntrypoint(executableName)
        }
    }

    private func relativePath(of child: URL, under parent: URL) throws -> String {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : "\(parentPath)/"
        guard childPath.hasPrefix(prefix) else {
            throw LocalRuntimeAdopterError.pathEscapesRoot(child)
        }
        return String(childPath.dropFirst(prefix.count))
    }
}

public enum LocalRuntimeAdopterError: LocalizedError, Equatable {
    case notExecutable(URL)
    case unknownEntrypoint(String)
    case pathEscapesRoot(URL)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let url):
            "The selected local runtime is not executable: \(url.path)"
        case .unknownEntrypoint(let name):
            "Select an sglang or sgl-omni executable, not \(name)."
        case .pathEscapesRoot(let url):
            "The selected executable is outside its inferred runtime root: \(url.path)"
        }
    }
}
