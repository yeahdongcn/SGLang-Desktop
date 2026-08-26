import Foundation

public actor RuntimeLibrary {
    private let store: JSONFileStore<[RuntimeInstallation]>

    public init(paths: AppPaths) {
        self.store = JSONFileStore(fileURL: paths.installationsFile) { [] }
    }

    public func installations() async throws -> [RuntimeInstallation] {
        try await store.load().sorted { lhs, rhs in
            lhs.installedAt > rhs.installedAt
        }
    }

    public func register(_ installation: RuntimeInstallation) async throws {
        try installation.manifest.validate()
        guard FileManager.default.isExecutableFile(atPath: installation.executableURL.path) else {
            throw RuntimeLibraryError.entrypointIsNotExecutable(installation.executableURL)
        }

        var records = try await store.load()
        if records.contains(where: {
            $0.manifest.id == installation.manifest.id
                && $0.manifest.version == installation.manifest.version
        }) {
            throw RuntimeLibraryError.installationAlreadyRegistered(
                installation.manifest.generationID
            )
        }
        records.append(installation)
        try await store.save(records)
    }

    public func activate(id: UUID) async throws {
        var records = try await store.load()
        guard let selected = records.first(where: { $0.id == id }) else {
            throw RuntimeLibraryError.installationNotFound(id)
        }

        switch selected.manifest.artifactKind {
        case .complete:
            for index in records.indices
            where records[index].manifest.engine == selected.manifest.engine {
                records[index].isActive = records[index].id == id
            }

        case .base:
            for index in records.indices
            where records[index].manifest.engine == selected.manifest.engine {
                switch records[index].manifest.artifactKind {
                case .complete, .base:
                    records[index].isActive = records[index].id == id
                case .engineOverlay:
                    if records[index].manifest.baseRuntimeID != selected.manifest.generationID
                        || records[index].manifest.compatibilityID
                            != selected.manifest.compatibilityID
                    {
                        records[index].isActive = false
                    }
                }
            }

        case .engineOverlay:
            guard
                let baseIndex = records.firstIndex(where: {
                    $0.manifest.engine == selected.manifest.engine
                        && $0.manifest.artifactKind == .base
                        && $0.manifest.generationID == selected.manifest.baseRuntimeID
                        && $0.manifest.compatibilityID == selected.manifest.compatibilityID
                })
            else {
                throw RuntimeLibraryError.compatibleBaseNotFound(
                    selected.manifest.baseRuntimeID ?? "none"
                )
            }

            for index in records.indices
            where records[index].manifest.engine == selected.manifest.engine {
                switch records[index].manifest.artifactKind {
                case .complete:
                    records[index].isActive = false
                case .base:
                    records[index].isActive = index == baseIndex
                case .engineOverlay:
                    records[index].isActive = records[index].id == id
                }
            }
        }
        try await store.save(records)
    }

    public func removeRegistration(id: UUID) async throws {
        var records = try await store.load()
        records.removeAll { $0.id == id }
        try await store.save(records)
    }
}

public enum RuntimeLibraryError: LocalizedError {
    case entrypointIsNotExecutable(URL)
    case installationNotFound(UUID)
    case compatibleBaseNotFound(String)
    case installationAlreadyRegistered(String)

    public var errorDescription: String? {
        switch self {
        case .entrypointIsNotExecutable(let url):
            "Runtime entrypoint is missing or not executable: \(url.path)"
        case .installationNotFound(let id):
            "Runtime installation was not found: \(id.uuidString)"
        case .compatibleBaseNotFound(let id):
            "The engine overlay requires a base runtime that is not installed: \(id)"
        case .installationAlreadyRegistered(let id):
            "A runtime generation with this identity is already registered: \(id)"
        }
    }
}
