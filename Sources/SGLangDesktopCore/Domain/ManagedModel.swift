import Foundation

public struct ManagedModel: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case available
        case downloading
        case verifying
        case ready
        case failed
    }

    public let id: UUID
    public var repository: String
    public var revision: String?
    public var displayName: String
    public var localDirectory: URL?
    public var sizeBytes: Int64?
    public var compatibleEngines: Set<EngineKind>
    public var state: State
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        repository: String,
        revision: String? = nil,
        displayName: String,
        localDirectory: URL? = nil,
        sizeBytes: Int64? = nil,
        compatibleEngines: Set<EngineKind>,
        state: State = .available,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.displayName = displayName
        self.localDirectory = localDirectory
        self.sizeBytes = sizeBytes
        self.compatibleEngines = compatibleEngines
        self.state = state
        self.addedAt = addedAt
    }
}
