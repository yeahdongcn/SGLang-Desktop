import Foundation

/// Finds developer runtimes that are already installed on this Mac.
///
/// Discovery is intentionally shallow and bounded. It checks common project
/// layouts instead of recursively walking a home directory or a dependency
/// tree, so first launch remains immediate.
public struct LocalRuntimeDiscovery: Sendable {
    public init() {}

    public func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraRoots: [URL] = []
    ) -> [RuntimeInstallation] {
        var executableCandidates: [URL] = []
        let projectRoots =
            [
                homeDirectory.appending(path: "go/src/github.com"),
                homeDirectory.appending(path: "src"),
                homeDirectory.appending(path: "Projects"),
                homeDirectory.appending(
                    path: "Library/Application Support/SGLang Desktop/runtimes"
                ),
            ] + extraRoots

        for projectRoot in projectRoots {
            appendVenvExecutables(at: projectRoot, to: &executableCandidates)
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: projectRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            // Inspect one project level only; never enter dependency/model trees.
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                appendVenvExecutables(at: child, to: &executableCandidates)
                guard
                    let projects = try? FileManager.default.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                else { continue }
                for project in projects {
                    guard
                        (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                            == true
                    else { continue }
                    appendVenvExecutables(at: project, to: &executableCandidates)
                }
            }
        }

        var selected: [EngineKind: URL] = [:]
        for executable in executableCandidates {
            guard let engine = engine(for: executable),
                FileManager.default.isExecutableFile(atPath: executable.path)
            else { continue }
            if selected[engine] == nil
                || preference(of: executable) > preference(of: selected[engine]!)
            {
                selected[engine] = executable
            }
        }

        return selected.compactMap { engine, executable in
            do {
                let runtimeRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
                let manifestURL = runtimeRoot.appending(path: "runtime.json")
                if let data = try? Data(contentsOf: manifestURL),
                    let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data)
                {
                    try manifest.validate()
                    return RuntimeInstallation(
                        manifest: manifest,
                        rootDirectory: runtimeRoot,
                        isActive: true
                    )
                }
                var installation = try LocalRuntimeAdopter().makeInstallation(
                    executableURL: executable,
                    engine: engine,
                    displayName: engine == .sglangOmni
                        ? "SGLang-Omni · Apple Silicon local runtime"
                        : "SGLang · Apple Silicon local runtime",
                    stableIdentity: LocalRuntimeAdopter().stableIdentity(for: executable)
                )
                installation.isActive = true
                return installation
            } catch {
                return nil
            }
        }
        .sorted { $0.manifest.engine.rawValue < $1.manifest.engine.rawValue }
    }

    private func appendVenvExecutables(at root: URL, to candidates: inout [URL]) {
        let layouts = [
            root.appending(path: ".venv-apple/bin"),
            root.appending(path: ".venv/bin"),
            root.appending(path: "venv/bin"),
            root.appending(path: "bin"),
        ]
        for layout in layouts where FileManager.default.fileExists(atPath: layout.path) {
            candidates.append(layout.appending(path: "sglang"))
            candidates.append(layout.appending(path: "sgl-omni"))
        }
    }

    private func engine(for executable: URL) -> EngineKind? {
        switch executable.lastPathComponent {
        case "sglang": .sglang
        case "sgl-omni": .sglangOmni
        default: nil
        }
    }

    private func preference(of executable: URL) -> Int {
        if executable.path.contains("Library/Application Support/SGLang Desktop/runtimes") {
            return 3
        }
        if executable.path.contains(".venv-apple/bin/") {
            return 2
        }
        return 1
    }
}
