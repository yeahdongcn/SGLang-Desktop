import Combine
import Foundation
import SGLangDesktopCore

#if os(macOS)
    import AppKit
#endif

@MainActor
final class DesktopViewModel: ObservableObject {
    struct ModelPreset: Identifiable, Equatable {
        let id: String
        let title: String
        let repository: String
        let engine: EngineKind
        let defaultMLX: Bool
        let localPath: String?

        var displayPath: String { localPath ?? repository }
    }

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
    @Published var selectedInstallationID: UUID?
    @Published var modelPath = ""
    @Published var portText = "8000"
    @Published var useMLX = true
    @Published private(set) var processState: EngineProcessState = .stopped
    @Published private(set) var healthStatus = "Stopped"

    let host = HostSystemProfile.current
    let paths: AppPaths

    private let runtimeLibrary: RuntimeLibrary
    private let modelLibrary: ModelLibrary
    private let supervisor = EngineProcessSupervisor()
    private var monitorTask: Task<Void, Never>?

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

        Task { await bootstrapAndLoad() }
        Task { await collectLogs() }
    }

    private func bootstrapAndLoad() async {
        // First launch should discover the developer runtimes and model caches
        // already present on this Mac. This is read-only and never installs
        // packages or downloads weights.
        let discoveredRuntimes = LocalRuntimeDiscovery().discover()
        for installation in discoveredRuntimes {
            do {
                try await runtimeLibrary.register(installation)
                try await runtimeLibrary.activate(id: installation.id)
            } catch {
                // Already registered or not executable; continue discovery.
            }
        }
        let preferredEngines = Set(
            discoveredRuntimes
                .filter { $0.rootDirectory.path.contains("SGLang Desktop/runtimes") }
                .map { $0.manifest.engine }
        )
        if !preferredEngines.isEmpty {
            for installation in (try? await runtimeLibrary.installations()) ?? []
            where preferredEngines.contains(installation.manifest.engine)
                && installation.rootDirectory.path.contains(".venv-apple")
            {
                try? await runtimeLibrary.removeRegistration(id: installation.id)
            }
        }
        for model in catalogModels {
            do { try await modelLibrary.upsert(model) } catch {
                // Keep the UI usable when one catalog record cannot persist.
            }
        }
        for model in ModelCacheDiscovery().discover() {
            do { try await modelLibrary.upsert(model) } catch {
                // Keep the UI usable when one cache record cannot persist.
            }
        }
        await load()
    }

    private var catalogModels: [ManagedModel] {
        [
            ManagedModel(
                repository: "Qwen/Qwen3-0.6B",
                displayName: "Qwen3 0.6B",
                compatibleEngines: [.sglang],
                state: .available
            ),
            ManagedModel(
                repository: "mlx-community/Qwen3-ASR-0.6B-4bit",
                displayName: "Qwen3-ASR 0.6B 4-bit",
                compatibleEngines: [.sglangOmni],
                state: .available
            ),
        ]
    }

    func load() async {
        isLoading = true
        do {
            async let runtimeRecords = runtimeLibrary.installations()
            async let modelRecords = modelLibrary.models()
            installations = try await runtimeRecords
            models = try await modelRecords
            if selectedInstallationID == nil {
                selectedInstallationID =
                    installations.first(where: { $0.isActive })?.id
                    ?? installations.first?.id
            }
            if modelPath.isEmpty {
                let preferred =
                    models.first {
                        $0.repository == "mlx-community/Qwen3-ASR-0.6B-4bit"
                    } ?? models.first {
                        $0.repository == "Qwen/Qwen3-0.6B"
                    } ?? models.first(where: { $0.state == .ready })
                modelPath = preferred?.localDirectory?.path ?? ""
                if preferred?.repository == "mlx-community/Qwen3-ASR-0.6B-4bit",
                    let omni = installations.first(where: { $0.manifest.engine == .sglangOmni })
                {
                    selectedInstallationID = omni.id
                    useMLX = true
                }
            }
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
            var activeInstallation = installation
            activeInstallation.isActive = true
            try await runtimeLibrary.register(activeInstallation)
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
            var activeInstallation = installation
            activeInstallation.isActive = true
            try await runtimeLibrary.register(activeInstallation)
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

    func selectModelDirectory(_ url: URL) async {
        let path = url.standardizedFileURL.path
        modelPath = path
        let model = ManagedModel(
            repository: path,
            displayName: url.lastPathComponent,
            localDirectory: url.standardizedFileURL,
            compatibleEngines: Set(EngineKind.allCases),
            state: .ready
        )
        do {
            try await modelLibrary.upsert(model)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var modelPresets: [ModelPreset] {
        let qwen = models.first {
            $0.repository == "Qwen/Qwen3-0.6B"
                || $0.repository.lowercased().contains("qwen3-0.6b")
                    && !$0.repository.lowercased().contains("asr")
        }
        let asr = models.first {
            $0.repository == "mlx-community/Qwen3-ASR-0.6B-4bit"
                || $0.repository.lowercased().contains("qwen3-asr-0.6b-4bit")
        }
        return [
            ModelPreset(
                id: "qwen3-0.6b",
                title: "Qwen3 0.6B · SGLang",
                repository: "Qwen/Qwen3-0.6B",
                engine: .sglang,
                defaultMLX: true,
                localPath: qwen?.localDirectory?.path
            ),
            ModelPreset(
                id: "qwen3-asr-0.6b-4bit",
                title: "Qwen3-ASR 0.6B 4-bit · SGLang-Omni",
                repository: "mlx-community/Qwen3-ASR-0.6B-4bit",
                engine: .sglangOmni,
                defaultMLX: true,
                localPath: asr?.localDirectory?.path
            ),
        ]
    }

    func choosePreset(_ preset: ModelPreset) {
        modelPath = preset.displayPath
        useMLX = preset.defaultMLX
        if let installation = installations.first(where: { $0.manifest.engine == preset.engine }) {
            selectedInstallationID = installation.id
        }
    }

    func prepareSelection() {
        if selectedInstallationID == nil {
            selectedInstallationID =
                installations.first(where: { $0.isActive })?.id
                ?? installations.first?.id
        }
    }

    func startEngine() async {
        guard let installation = selectedInstallation else {
            lastError = "先在 Installations 中添加一个本地 sglang 或 sgl-omni CLI。"
            return
        }
        guard !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "请选择模型目录，或填写 Hugging Face 模型 ID。"
            return
        }
        guard let port = UInt16(portText), port > 0 else {
            lastError = "端口必须是 1–65535 之间的数字。"
            return
        }

        var arguments = [
            "serve",
            "--model-path", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        var environment: [String: String] = [
            "SGLANG_CACHE_DIR": paths.root.appending(path: "cache").path,
            "HF_HOME": paths.models.appending(path: "huggingface").path,
            "SGLANG_OMNI_STRICT_PORT": "1",
        ]
        if useMLX {
            environment["SGLANG_USE_MLX"] = "1"
        }
        let servedModelName =
            modelPresets.first(where: { $0.displayPath == modelPath })?.repository
            ?? URL(fileURLWithPath: modelPath).lastPathComponent
        if installation.manifest.engine == .sglangOmni {
            arguments += [
                "--model-name", servedModelName,
                "--asr.engine.max_running_requests", "1",
            ]
            let ffmpeg = "/opt/homebrew/opt/ffmpeg@7/lib"
            if FileManager.default.fileExists(atPath: ffmpeg) {
                environment["DYLD_LIBRARY_PATH"] = ffmpeg
            }
        } else {
            arguments += [
                "--model-type", "llm",
                "--served-model-name", servedModelName,
            ]
        }

        let configuration = EngineLaunchConfiguration(
            installationID: installation.id,
            executableURL: installation.executableURL,
            workingDirectory: installation.rootDirectory,
            arguments: arguments,
            environment: environment,
            port: port
        )

        do {
            try await supervisor.start(configuration)
            processState = await supervisor.state()
            healthStatus = "Loading model…"
            monitorTask?.cancel()
            monitorTask = Task { [weak self] in
                guard let self else { return }
                await self.monitorEngine(configuration: configuration, port: port)
            }
        } catch {
            processState = .failed(message: error.localizedDescription)
            healthStatus = "Failed"
            lastError = error.localizedDescription
        }
    }

    func stopEngine() async {
        monitorTask?.cancel()
        await supervisor.stop()
        processState = await supervisor.state()
        healthStatus = "Stopped"
    }

    func openAPI() {
        guard let port = UInt16(portText), let url = URL(string: "http://127.0.0.1:\(port)/docs")
        else {
            return
        }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #endif
    }

    var selectedInstallation: RuntimeInstallation? {
        guard let selectedInstallationID else { return nil }
        return installations.first(where: { $0.id == selectedInstallationID })
    }

    var isEngineRunning: Bool {
        if case .running = processState { return true }
        if case .starting = processState { return true }
        if case .stopping = processState { return true }
        return false
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

    private func monitorEngine(
        configuration: EngineLaunchConfiguration,
        port: UInt16
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        var becameReady = false

        while !Task.isCancelled {
            let state = await supervisor.state()
            processState = state
            switch state {
            case .failed(let message):
                healthStatus = "Failed"
                lastError = message
                return
            case .stopped:
                healthStatus = becameReady ? "Stopped" : "Exited during startup"
                return
            case .starting, .running, .stopping:
                break
            }

            if !becameReady, await HealthProbe().isReady(url: configuration.healthURL) {
                becameReady = true
                healthStatus = "Ready · http://127.0.0.1:\(port)"
            } else if !becameReady, clock.now >= deadline {
                healthStatus = "Startup timed out"
                return
            }
            try? await clock.sleep(for: .milliseconds(500))
        }
    }

    deinit {
        monitorTask?.cancel()
    }
}
