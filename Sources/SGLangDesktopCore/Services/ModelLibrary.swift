import Foundation

public actor ModelLibrary {
    private let store: JSONFileStore<[ManagedModel]>

    public init(paths: AppPaths) {
        self.store = JSONFileStore(fileURL: paths.modelsFile) { [] }
    }

    public func models() async throws -> [ManagedModel] {
        try await store.load().sorted { lhs, rhs in
            lhs.addedAt > rhs.addedAt
        }
    }

    public func upsert(_ model: ManagedModel) async throws {
        var records = try await store.load()
        records.removeAll {
            $0.id == model.id
                || ($0.repository == model.repository
                    && (model.localDirectory == nil || $0.localDirectory == model.localDirectory))
        }
        records.append(model)
        try await store.save(records)
    }
}
