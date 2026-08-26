import Foundation

public actor JSONFileStore<Value: Codable & Sendable> {
    private let fileURL: URL
    private let defaultValue: @Sendable () -> Value
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        defaultValue: @escaping @Sendable () -> Value
    ) {
        self.fileURL = fileURL
        self.defaultValue = defaultValue

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> Value {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultValue()
        }
        return try decoder.decode(Value.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}
