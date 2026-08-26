import Foundation

/// The non-secret launch identity needed to reconnect the desktop UI to an
/// engine that outlives it. Environment variables and raw launch arguments are
/// deliberately omitted so tokens and other credentials are never written to
/// the session store.
public struct EngineSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let installationID: UUID
    public let engine: EngineKind
    public let processIdentifier: Int32
    public let processGroupIdentifier: Int32
    public let runtimeExecutableURL: URL
    public let modelPath: String
    public let servedModelName: String?
    public let usesMLX: Bool
    public let port: UInt16
    public let healthPath: String
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        installationID: UUID,
        engine: EngineKind,
        processIdentifier: Int32,
        processGroupIdentifier: Int32,
        runtimeExecutableURL: URL,
        modelPath: String,
        servedModelName: String? = nil,
        usesMLX: Bool = true,
        port: UInt16,
        healthPath: String = "/health",
        startedAt: Date = Date()
    ) {
        self.id = id
        self.installationID = installationID
        self.engine = engine
        self.processIdentifier = processIdentifier
        self.processGroupIdentifier = processGroupIdentifier
        self.runtimeExecutableURL = runtimeExecutableURL.standardizedFileURL
        self.modelPath = modelPath
        self.servedModelName = servedModelName
        self.usesMLX = usesMLX
        self.port = port
        self.healthPath = healthPath.hasPrefix("/") ? healthPath : "/\(healthPath)"
        self.startedAt = startedAt
    }

    public init(
        id: UUID = UUID(),
        configuration: EngineLaunchConfiguration,
        engine: EngineKind,
        processIdentifier: Int32,
        processGroupIdentifier: Int32,
        modelPath: String,
        servedModelName: String? = nil,
        usesMLX: Bool = true,
        startedAt: Date = Date()
    ) {
        self.init(
            id: id,
            installationID: configuration.installationID,
            engine: engine,
            processIdentifier: processIdentifier,
            processGroupIdentifier: processGroupIdentifier,
            runtimeExecutableURL: configuration.executableURL,
            modelPath: modelPath,
            servedModelName: servedModelName,
            usesMLX: usesMLX,
            port: configuration.port,
            healthPath: configuration.healthPath,
            startedAt: startedAt
        )
    }

    public var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(healthPath)")!
    }

    private enum CodingKeys: String, CodingKey {
        case id, installationID, engine, processIdentifier, processGroupIdentifier
        case runtimeExecutableURL, modelPath, servedModelName, usesMLX, port, healthPath
        case startedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            installationID: try values.decode(UUID.self, forKey: .installationID),
            engine: try values.decode(EngineKind.self, forKey: .engine),
            processIdentifier: try values.decode(Int32.self, forKey: .processIdentifier),
            processGroupIdentifier: try values.decode(
                Int32.self,
                forKey: .processGroupIdentifier
            ),
            runtimeExecutableURL: try values.decode(URL.self, forKey: .runtimeExecutableURL),
            modelPath: try values.decode(String.self, forKey: .modelPath),
            servedModelName: try values.decodeIfPresent(String.self, forKey: .servedModelName),
            usesMLX: try values.decodeIfPresent(Bool.self, forKey: .usesMLX) ?? true,
            port: try values.decode(UInt16.self, forKey: .port),
            healthPath: try values.decode(String.self, forKey: .healthPath),
            startedAt: try values.decode(Date.self, forKey: .startedAt)
        )
    }
}

public actor EngineSessionStore {
    private let store: JSONFileStore<[EngineSession]>

    public init(paths: AppPaths) {
        self.store = JSONFileStore(fileURL: paths.sessionsFile) { [] }
    }

    public func sessions() async throws -> [EngineSession] {
        try await store.load().sorted { $0.startedAt > $1.startedAt }
    }

    public func upsert(_ session: EngineSession) async throws {
        var records = try await store.load()
        records.removeAll {
            $0.id == session.id || $0.processIdentifier == session.processIdentifier
        }
        records.append(session)
        try await store.save(records)
    }

    public func remove(id: UUID) async throws {
        var records = try await store.load()
        records.removeAll { $0.id == id }
        try await store.save(records)
    }

    public func remove(processIdentifier: Int32) async throws {
        var records = try await store.load()
        records.removeAll { $0.processIdentifier == processIdentifier }
        try await store.save(records)
    }

    @discardableResult
    public func prune(keepingProcessIdentifiers identifiers: Set<Int32>) async throws -> Int {
        var records = try await store.load()
        let previousCount = records.count
        records.removeAll { !identifiers.contains($0.processIdentifier) }
        if records.count != previousCount {
            try await store.save(records)
        }
        return previousCount - records.count
    }
}
