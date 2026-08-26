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
    @Published var advancedSettings = AdvancedLaunchSettings()
    @Published private(set) var diagnostics = DiagnosticReport(items: [])
    @Published private(set) var isDiagnosing = true
    @Published private(set) var repairStatus: String?
    @Published private(set) var clientStatus: String?
    @Published private(set) var processState: EngineProcessState = .stopped
    @Published private(set) var healthStatus = "Stopped"

    let host = HostSystemProfile.current
    let paths: AppPaths

    private let runtimeLibrary: RuntimeLibrary
    private let modelLibrary: ModelLibrary
    private let supervisor = EngineProcessSupervisor()
    private var monitorTask: Task<Void, Never>?
    private var currentSettingsKey = "custom"

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
        await runDiagnostics()
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
            if let preset = modelPresets.first(where: { $0.displayPath == modelPath }) {
                currentSettingsKey = preset.id
                advancedSettings = loadAdvancedSettings(for: preset)
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
        saveAdvancedSettings()
        modelPath = preset.displayPath
        useMLX = preset.defaultMLX
        currentSettingsKey = preset.id
        advancedSettings = loadAdvancedSettings(for: preset)
        if let installation = installations.first(where: { $0.manifest.engine == preset.engine }) {
            selectedInstallationID = installation.id
        }
    }

    func resetAdvancedSettings() {
        if let preset = modelPresets.first(where: { $0.id == currentSettingsKey }) {
            UserDefaults.standard.removeObject(forKey: "advanced-launch.\(currentSettingsKey)")
            advancedSettings = AdvancedLaunchSettings(
                servedModelName: preset.repository,
                maxRunningRequests: preset.engine == .sglangOmni ? "1" : "",
                logLevel: "info"
            )
        } else {
            advancedSettings = AdvancedLaunchSettings()
        }
    }

    func prepareSelection() {
        if selectedInstallationID == nil {
            selectedInstallationID =
                installations.first(where: { $0.isActive })?.id
                ?? installations.first?.id
        }
        if let preset = modelPresets.first(where: { $0.displayPath == modelPath }) {
            currentSettingsKey = preset.id
            advancedSettings = loadAdvancedSettings(for: preset)
        }
    }

    func startEngine() async {
        do {
            let configuration = try makeLaunchConfiguration()
            saveAdvancedSettings()
            try await supervisor.start(configuration)
            processState = await supervisor.state()
            healthStatus = "Loading model…"
            monitorTask?.cancel()
            monitorTask = Task { [weak self] in
                guard let self else { return }
                await self.monitorEngine(configuration: configuration, port: configuration.port)
            }
        } catch {
            processState = .failed(message: error.localizedDescription)
            healthStatus = "Failed"
            lastError = error.localizedDescription
        }
    }

    func makeLaunchConfiguration() throws -> EngineLaunchConfiguration {
        guard let installation = selectedInstallation else {
            throw DesktopLaunchError.missingRuntime
        }
        guard !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopLaunchError.missingModel
        }
        guard let port = UInt16(portText), port > 0 else {
            throw DesktopLaunchError.invalidValue(name: "Port", value: portText)
        }

        var arguments =
            installation.manifest.defaultArguments.isEmpty
            ? ["serve"] : installation.manifest.defaultArguments
        arguments += [
            "--model-path", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        var environment: [String: String] = [
            "SGLANG_CACHE_DIR": paths.root.appending(path: "cache").path,
            "HF_HOME": paths.models.appending(path: "huggingface").path,
        ]
        if useMLX { environment["SGLANG_USE_MLX"] = "1" }

        let servedModelName = effectiveServedModelName
        if installation.manifest.engine == .sglangOmni {
            environment["SGLANG_OMNI_STRICT_PORT"] = "1"
            arguments += ["--model-name", servedModelName]
            try appendPositiveInteger(
                advancedSettings.maxRunningRequests.isEmpty
                    ? "1" : advancedSettings.maxRunningRequests,
                flag: "--asr.engine.max_running_requests",
                name: "Max running requests",
                to: &arguments
            )
            try appendPositiveInteger(
                advancedSettings.contextLength,
                flag: "--asr.engine.context_length",
                name: "Context length",
                to: &arguments
            )
            try appendPositiveInteger(
                advancedSettings.maxTotalTokens,
                flag: "--asr.engine.max_total_tokens",
                name: "Max total tokens",
                to: &arguments
            )
            let ffmpeg = "/opt/homebrew/opt/ffmpeg@7/lib"
            if FileManager.default.fileExists(atPath: ffmpeg) {
                environment["DYLD_LIBRARY_PATH"] = ffmpeg
            }
        } else {
            arguments += [
                "--model-type", "llm",
                "--served-model-name", servedModelName,
            ]
            try appendPositiveInteger(
                advancedSettings.maxRunningRequests,
                flag: "--max-running-requests",
                name: "Max running requests",
                to: &arguments
            )
            try appendPositiveInteger(
                advancedSettings.contextLength,
                flag: "--context-length",
                name: "Context length",
                to: &arguments
            )
            try appendPositiveInteger(
                advancedSettings.maxTotalTokens,
                flag: "--max-total-tokens",
                name: "Max total tokens",
                to: &arguments
            )
        }

        try appendFraction(
            advancedSettings.memoryFractionStatic,
            flag: "--mem-fraction-static",
            name: "Memory fraction",
            to: &arguments
        )
        if advancedSettings.logLevel != "info" {
            arguments += ["--log-level", advancedSettings.logLevel]
        }
        if installation.manifest.engine == .sglang {
            if advancedSettings.trustRemoteCode { arguments.append("--trust-remote-code") }
            if advancedSettings.disableRadixCache { arguments.append("--disable-radix-cache") }
            if advancedSettings.disableOverlapSchedule {
                arguments.append("--disable-overlap-schedule")
            }
        } else {
            if advancedSettings.disableRadixCache {
                arguments += ["--asr.engine.disable_radix_cache", "true"]
            }
            if advancedSettings.disableOverlapSchedule {
                arguments += ["--asr.engine.disable_overlap_schedule", "true"]
            }
        }

        let extraArguments = try LaunchInputParser.arguments(from: advancedSettings.extraArguments)
        try validateExtraArguments(extraArguments)
        arguments += extraArguments
        environment.merge(
            try LaunchInputParser.environment(from: advancedSettings.extraEnvironment),
            uniquingKeysWith: { _, custom in custom }
        )
        return EngineLaunchConfiguration(
            installationID: installation.id,
            executableURL: installation.executableURL,
            workingDirectory: installation.rootDirectory,
            arguments: arguments,
            environment: environment,
            port: port
        )
    }

    var launchCommandPreview: String {
        do {
            let configuration = try makeLaunchConfiguration()
            return LaunchInputParser.shellEscapedPreview(
                [configuration.executableURL.path] + configuration.arguments
            )
        } catch {
            return error.localizedDescription
        }
    }

    var launchEnvironmentPreview: String {
        do {
            return try makeLaunchConfiguration().environment
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        } catch {
            return ""
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

    var openAIBaseURL: String {
        "http://127.0.0.1:\(portText)/v1"
    }

    var effectiveServedModelName: String {
        let configured = advancedSettings.servedModelName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !configured.isEmpty { return configured }
        return modelPresets.first(where: { $0.displayPath == modelPath })?.repository
            ?? URL(fileURLWithPath: modelPath).lastPathComponent
    }

    var canUseChatClient: Bool {
        healthStatus.hasPrefix("Ready") && selectedInstallation?.manifest.engine == .sglang
    }

    func copyOpenAIBaseURL() {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(openAIBaseURL, forType: .string)
            clientStatus = "Copied \(openAIBaseURL)"
        #endif
    }

    func launchAnythingLLM() {
        #if os(macOS)
            guard canUseChatClient else {
                lastError = "Start a chat-capable SGLang model before opening AnythingLLM."
                return
            }
            guard
                let appURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.anythingllm"
                )
            else {
                lastError = "AnythingLLM is not installed in /Applications."
                return
            }
            let setup = """
                Provider: Generic OpenAI
                Base URL: \(openAIBaseURL)
                Model: \(effectiveServedModelName)
                API key: leave blank
                """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(setup, forType: .string)
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = error.localizedDescription
                    } else {
                        self?.clientStatus =
                            "AnythingLLM opened. Generic OpenAI settings were copied to the clipboard."
                    }
                }
            }
        #endif
    }

    func runDiagnostics() async {
        isDiagnosing = true
        defer { isDiagnosing = false }
        let port = UInt16(portText) ?? 8000
        diagnostics = await AppleSystemDiagnostics().run(
            host: host,
            installations: installations,
            models: models,
            paths: paths,
            port: port,
            activePortIsExpected: isEngineRunning
        )
    }

    func repairDiagnostic(_ item: DiagnosticItem) async {
        guard let action = item.repairAction else { return }
        repairStatus = "Repairing \(item.title)…"
        defer { repairStatus = nil }
        switch action {
        case .redetect:
            await bootstrapAndLoad()
        case .chooseFreePort:
            if let port = LocalPort.availablePort() { portText = String(port) }
        case .openSoftwareUpdate:
            #if os(macOS)
                NSWorkspace.shared.open(
                    URL(
                        string:
                            "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
                    )!
                )
            #endif
        case .openInstallations:
            selection = .installations
        case .openModels:
            selection = .models
        }
        await runDiagnostics()
    }

    func repairAllDiagnostics() async {
        for item in diagnostics.items where item.status == .failed && item.repairAction != nil {
            await repairDiagnostic(item)
        }
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

    private func appendPositiveInteger(
        _ rawValue: String,
        flag: String,
        name: String,
        to arguments: inout [String]
    ) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let parsed = Int(value), parsed > 0 else {
            throw DesktopLaunchError.invalidValue(name: name, value: rawValue)
        }
        arguments += [flag, String(parsed)]
    }

    private func appendFraction(
        _ rawValue: String,
        flag: String,
        name: String,
        to arguments: inout [String]
    ) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let parsed = Double(value), parsed > 0, parsed <= 1 else {
            throw DesktopLaunchError.invalidValue(name: name, value: rawValue)
        }
        arguments += [flag, String(parsed)]
    }

    private func validateExtraArguments(_ arguments: [String]) throws {
        let reserved = [
            "--model-path", "--host", "--port", "--model-name", "--served-model-name",
            "--model-type", "--context-length", "--max-running-requests",
            "--max-total-tokens", "--mem-fraction-static", "--log-level",
            "--trust-remote-code", "--disable-radix-cache", "--disable-overlap-schedule",
            "--asr.engine.context_length", "--asr.engine.max_running_requests",
            "--asr.engine.max_total_tokens", "--asr.engine.disable_radix_cache",
            "--asr.engine.disable_overlap_schedule",
        ]
        for argument in arguments {
            if let flag = reserved.first(where: {
                argument == $0 || argument.hasPrefix("\($0)=")
            }) {
                throw DesktopLaunchError.reservedArgument(flag)
            }
        }
    }

    private func loadAdvancedSettings(for preset: ModelPreset) -> AdvancedLaunchSettings {
        let key = "advanced-launch.\(preset.id)"
        if let data = UserDefaults.standard.data(forKey: key),
            var decoded = try? JSONDecoder().decode(AdvancedLaunchSettings.self, from: data)
        {
            if (try? LaunchInputParser.environment(from: decoded.extraEnvironment)) == nil {
                decoded.extraEnvironment = ""
            }
            return decoded
        }
        return AdvancedLaunchSettings(
            servedModelName: preset.repository,
            maxRunningRequests: preset.engine == .sglangOmni ? "1" : "",
            logLevel: "info"
        )
    }

    private func saveAdvancedSettings() {
        guard (try? LaunchInputParser.environment(from: advancedSettings.extraEnvironment)) != nil
        else { return }
        guard let data = try? JSONEncoder().encode(advancedSettings) else { return }
        UserDefaults.standard.set(data, forKey: "advanced-launch.\(currentSettingsKey)")
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

private enum DesktopLaunchError: LocalizedError {
    case missingRuntime
    case missingModel
    case invalidValue(name: String, value: String)
    case reservedArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            "Select an SGLang or SGLang-Omni runtime."
        case .missingModel:
            "Select a model directory or enter a model repository ID."
        case .invalidValue(let name, let value):
            "\(name) has an invalid value: \(value)"
        case .reservedArgument(let flag):
            "Extra arguments cannot override the Desktop-managed option \(flag)."
        }
    }
}
