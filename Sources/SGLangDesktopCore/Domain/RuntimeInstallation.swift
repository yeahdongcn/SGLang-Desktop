import Foundation

public struct RuntimeInstallation: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case installing
        case broken
    }

    public let id: UUID
    public var manifest: RuntimeManifest
    public var rootDirectory: URL
    public var installedAt: Date
    public var status: Status
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        manifest: RuntimeManifest,
        rootDirectory: URL,
        installedAt: Date = Date(),
        status: Status = .ready,
        isActive: Bool = false
    ) {
        self.id = id
        self.manifest = manifest
        self.rootDirectory = rootDirectory
        self.installedAt = installedAt
        self.status = status
        self.isActive = isActive
    }

    public var executableURL: URL {
        rootDirectory.appending(path: manifest.entrypoint)
    }
}
