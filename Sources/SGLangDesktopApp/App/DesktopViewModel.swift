import Combine
import Foundation
import SGLangDesktopCore

@MainActor
final class DesktopViewModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard
        case installations
        case models
        case logs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: "Dashboard"
            case .installations: "Installations"
            case .models: "Models"
            case .logs: "Logs"
            }
        }

        var symbol: String {
            switch self {
            case .dashboard: "square.grid.2x2"
            case .installations: "shippingbox"
            case .models: "externaldrive"
            case .logs: "text.alignleft"
            }
        }
    }

    @Published var selection: Section? = .dashboard
    @Published private(set) var installations: [RuntimeInstallation] = []
    @Published private(set) var models: [ManagedModel] = []
    @Published private(set) var logEvents: [EngineLogEvent] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = true

    let host = HostSystemProfile.current
    let paths: AppPaths

    private let runtimeLibrary: RuntimeLibrary
    private let modelLibrary: ModelLibrary
    private let supervisor = EngineProcessSupervisor()

    init() {
        do {
            let paths = try AppPaths.userDefault()
            try paths.createRequiredDirectories()
            self.paths = paths
            self.runtimeLibrary = RuntimeLibrary(paths: paths)
            self.modelLibrary = ModelLibrary(paths: paths)
        } catch {
            let fallback = AppPaths(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "SGLang Desktop", directoryHint: .isDirectory)
            )
            self.paths = fallback
            self.runtimeLibrary = RuntimeLibrary(paths: fallback)
            self.modelLibrary = ModelLibrary(paths: fallback)
            self.lastError = error.localizedDescription
        }

        Task { await load() }
        Task { await collectLogs() }
    }

    func load() async {
        isLoading = true
        do {
            async let runtimeRecords = runtimeLibrary.installations()
            async let modelRecords = modelLibrary.models()
            installations = try await runtimeRecords
            models = try await modelRecords
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func adoptRuntime(manifestURL: URL) async {
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(RuntimeManifest.self, from: data)
            try manifest.validate()
            let executableURL = manifestURL.deletingLastPathComponent().appending(
                path: manifest.entrypoint
            )
            let installation = try LocalRuntimeAdopter().makeInstallation(
                executableURL: executableURL,
                engine: manifest.engine,
                displayName: "Local \(manifest.displayName)"
            )
            try await runtimeLibrary.register(installation)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func adoptLocalExecutable(_ executableURL: URL) async {
        do {
            let installation = try LocalRuntimeAdopter().makeInstallation(
                executableURL: executableURL
            )
            try await runtimeLibrary.register(installation)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func activate(_ installation: RuntimeInstallation) async {
        do {
            try await runtimeLibrary.activate(id: installation.id)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func collectLogs() async {
        for await event in supervisor.logs {
            logEvents.append(event)
            if logEvents.count > 2_000 {
                logEvents.removeFirst(logEvents.count - 2_000)
            }
        }
    }
}
