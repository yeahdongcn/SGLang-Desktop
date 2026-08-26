import Foundation

public struct ModelCacheDiscovery: Sendable {
    public init() {}

    public func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalRoots: [URL] = []
    ) -> [ManagedModel] {
        let roots =
            [
                homeDirectory.appending(path: ".cache/huggingface/hub"),
                homeDirectory.appending(path: "Library/Caches/huggingface/hub"),
                homeDirectory.appending(path: "Library/Application Support/huggingface/hub"),
                homeDirectory.appending(path: ".cache/modelscope/hub"),
                homeDirectory.appending(path: "Library/Caches/modelscope/hub"),
            ] + additionalRoots

        var results: [String: ManagedModel] = [:]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            if root.path.contains("modelscope") {
                for model in discoverModelScopeModels(in: root) {
                    results[model.repository.lowercased()] = model
                }
                continue
            }
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for child in children where child.lastPathComponent.hasPrefix("models--") {
                guard let snapshot = latestSnapshot(in: child) else { continue }
                guard hasModelWeights(snapshot) else { continue }
                let repository = repositoryName(from: child.lastPathComponent)
                let key = repository.lowercased()
                let engineSet: Set<EngineKind> =
                    repository.lowercased().contains("asr")
                    ? [.sglangOmni]
                    : Set(EngineKind.allCases)
                let model = ManagedModel(
                    repository: repository,
                    displayName: repository,
                    localDirectory: snapshot,
                    // Do not walk multi-gigabyte model trees during app launch.
                    // Size can be hydrated lazily by the model manager.
                    sizeBytes: nil,
                    compatibleEngines: engineSet,
                    state: .ready
                )
                results[key] = model
            }
        }
        return results.values.sorted { $0.displayName < $1.displayName }
    }

    private func latestSnapshot(in modelRoot: URL) -> URL? {
        let snapshots = modelRoot.appending(path: "snapshots")
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        return
            children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private func repositoryName(from cacheName: String) -> String {
        let parts = cacheName.dropFirst("models--".count).split(separator: "--", maxSplits: 1)
        return parts.map(String.init).joined(separator: "/")
    }

    private func hasModelWeights(_ snapshot: URL) -> Bool {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: snapshot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return false }
        return entries.contains { entry in
            let name = entry.lastPathComponent.lowercased()
            return name.hasSuffix(".safetensors")
                || name == "model.safetensors.index.json"
                || name.hasSuffix(".bin")
                || name.hasSuffix(".gguf")
                || name.hasSuffix(".mlx")
        }
    }

    private func discoverModelScopeModels(in hubRoot: URL) -> [ManagedModel] {
        let modelsRoot = hubRoot.appending(path: "models")
        guard
            let owners = try? FileManager.default.contentsOfDirectory(
                at: modelsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var models: [ManagedModel] = []
        for owner in owners {
            guard (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                let repositories = try? FileManager.default.contentsOfDirectory(
                    at: owner,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for repositoryDirectory in repositories {
                guard hasModelWeights(repositoryDirectory) else { continue }
                let modelName = repositoryDirectory.lastPathComponent.replacingOccurrences(
                    of: "___",
                    with: "."
                )
                let repository = "\(owner.lastPathComponent)/\(modelName)"
                let engines: Set<EngineKind> =
                    repository.lowercased().contains("asr")
                    ? [.sglangOmni]
                    : [.sglang]
                models.append(
                    ManagedModel(
                        repository: repository,
                        displayName: repository,
                        localDirectory: repositoryDirectory,
                        compatibleEngines: engines,
                        state: .ready
                    )
                )
            }
        }
        return models
    }

}
