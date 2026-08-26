import SGLangDesktopCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct DashboardView: View {
    @EnvironmentObject private var model: DesktopViewModel
    @State private var isChoosingModel = false
    @State private var isShowingDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        SGLangLogo()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Run SGLang locally")
                                .font(.largeTitle.bold())
                            Text("SGLang Desktop")
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(
                        "A native Apple Silicon control plane for managed SGLang runtimes and models."
                    )
                    .font(.title3)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    Button {
                        isShowingDiagnostics = true
                        Task { await model.runDiagnostics() }
                    } label: {
                        MetricCard(
                            title: "This Mac",
                            value: model.isDiagnosing
                                ? "Checking…"
                                : (model.diagnostics.isReady ? "Ready" : "Needs attention"),
                            detail: "\(model.host.platformLabel) · Diagnose",
                            symbol: model.diagnostics.isReady
                                ? "checkmark.circle.fill" : "stethoscope",
                            tint: model.diagnostics.isReady ? .green : .orange
                        )
                    }
                    .buttonStyle(.plain)
                    MetricCard(
                        title: "Runtimes",
                        value: "\(model.installations.count)",
                        detail: "Managed installations",
                        symbol: "shippingbox.fill",
                        tint: .blue
                    )
                    MetricCard(
                        title: "Models",
                        value: "\(model.models.count)",
                        detail: "Known model payloads",
                        symbol: "externaldrive.fill",
                        tint: .purple
                    )
                }

                EngineControlCard(isChoosingModel: $isChoosingModel)
            }
            .padding(28)
        }
        .navigationTitle("Dashboard")
        .task {
            model.prepareSelection()
        }
        .fileImporter(
            isPresented: $isChoosingModel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            Task {
                await model.selectModelDirectory(url)
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 620)
        }
    }
}

private struct SGLangLogo: View {
    var body: some View {
        #if os(macOS)
            if let url = Bundle.module.url(
                forResource: "sglang-logo-square",
                withExtension: "png"
            ), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .foregroundStyle(.tint)
            }
        #endif
    }
}

private struct EngineControlCard: View {
    @EnvironmentObject private var model: DesktopViewModel
    @Binding var isChoosingModel: Bool
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Run a local model", systemImage: "play.circle.fill")
                    .font(.title2.bold())
                Spacer()
                Text(model.healthStatus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(model.healthStatus.hasPrefix("Ready") ? .green : .secondary)
            }

            HStack(spacing: 12) {
                Picker("Runtime", selection: $model.selectedInstallationID) {
                    Text("Select runtime").tag(Optional<UUID>.none)
                    ForEach(model.installations.filter { $0.manifest.artifactKind == .complete }) {
                        runtime in
                        Text(runtime.manifest.displayName).tag(Optional(runtime.id))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 280)

                Picker(
                    "Model preset",
                    selection: Binding(
                        get: {
                            model.modelPresets.first(where: { $0.displayPath == model.modelPath })?
                                .id ?? ""
                        },
                        set: { id in
                            if let preset = model.modelPresets.first(where: { $0.id == id }) {
                                model.choosePreset(preset)
                            }
                        }
                    )
                ) {
                    Text("Choose a model preset").tag("")
                    ForEach(model.modelPresets) { preset in
                        Text(
                            preset.title
                                + (preset.localPath == nil
                                    ? " · download on first run" : " · cached")
                        )
                        .tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 360)
            }

            HStack(spacing: 10) {
                TextField("Model path or Hugging Face ID", text: $model.modelPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { isChoosingModel = true }
            }

            HStack(spacing: 12) {
                TextField("Port", text: $model.portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                if model.selectedInstallation != nil {
                    Toggle("Use MLX", isOn: $model.useMLX)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if model.isEngineRunning {
                    Button("Stop") {
                        Task { await model.stopEngine() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start engine") {
                        Task { await model.startEngine() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading || model.isRecoveringSession)
                }
                Button("Open API") { model.openAPI() }
                    .disabled(!model.healthStatus.hasPrefix("Ready"))
                Menu("Use with…") {
                    Button("Copy OpenAI Base URL") { model.copyOpenAIBaseURL() }
                    Button("Launch AnythingLLM") { model.launchAnythingLLM() }
                        .disabled(!model.canUseChatClient)
                }
                .disabled(!model.healthStatus.hasPrefix("Ready"))
            }

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                AdvancedLaunchOptionsView()
                    .environmentObject(model)
                    .padding(.top, 10)
            }
            .disabled(model.isEngineRunning)

            if let clientStatus = model.clientStatus {
                Label(clientStatus, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if model.installations.isEmpty {
                Label(
                    "No local runtime was found. Open Installations and add the sglang or sgl-omni CLI.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            } else if model.models.isEmpty {
                Label(
                    "No Hugging Face or ModelScope cache was found yet. A model ID can still be entered; it will download on first start.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AdvancedLaunchOptionsView: View {
    @EnvironmentObject private var model: DesktopViewModel

    private let logLevels = ["debug", "info", "warning", "error", "critical"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Served model name")
                    TextField(
                        "Model name exposed by /v1/models",
                        text: $model.advancedSettings.servedModelName)
                    Text("Context length")
                    TextField("auto", text: $model.advancedSettings.contextLength)
                        .frame(width: 110)
                }
                GridRow {
                    Text("Max running requests")
                    TextField("auto", text: $model.advancedSettings.maxRunningRequests)
                    Text("Max total tokens")
                    TextField("auto", text: $model.advancedSettings.maxTotalTokens)
                        .frame(width: 110)
                }
                GridRow {
                    Text("Memory fraction")
                    TextField("0 < value ≤ 1", text: $model.advancedSettings.memoryFractionStatic)
                    Text("Log level")
                    Picker("Log level", selection: $model.advancedSettings.logLevel) {
                        ForEach(logLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            HStack(spacing: 18) {
                if model.selectedInstallation?.manifest.engine == .sglang {
                    Toggle("Trust remote code", isOn: $model.advancedSettings.trustRemoteCode)
                }
                Toggle("Disable radix cache", isOn: $model.advancedSettings.disableRadixCache)
                Toggle(
                    "Disable overlap schedule", isOn: $model.advancedSettings.disableOverlapSchedule
                )
            }
            .toggleStyle(.checkbox)

            Text("Extra arguments")
                .font(.subheadline.bold())
            TextField("--custom-option value", text: $model.advancedSettings.extraArguments)
                .textFieldStyle(.roundedBorder)

            Text("Extra environment · one KEY=VALUE per line")
                .font(.subheadline.bold())
            TextEditor(text: $model.advancedSettings.extraEnvironment)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 58, maxHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text("Effective command")
                .font(.subheadline.bold())
            ScrollView(.horizontal) {
                Text(model.launchCommandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("Protected runtime variables and secret-looking keys are rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Preset Defaults") { model.resetAdvancedSettings() }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: DesktopViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This Mac Diagnostics")
                        .font(.title2.bold())
                    Text(
                        model.diagnostics.isReady
                            ? "The Mac and runtime storage are ready. Launch-specific issues are listed below."
                            : "One or more required checks need attention."
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            List(model.diagnostics.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: diagnosticSymbol(item.status))
                        .foregroundStyle(diagnosticColor(item.status))
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.title).font(.headline)
                            if !item.blocksReadiness, item.status != .passed {
                                Text("LAUNCH CHECK")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let label = item.repairLabel {
                        Button(label) { Task { await model.repairDiagnostic(item) } }
                            .disabled(model.repairStatus != nil)
                    }
                }
                .padding(.vertical, 5)
            }

            HStack {
                if let repairStatus = model.repairStatus {
                    ProgressView().controlSize(.small)
                    Text(repairStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Again") { Task { await model.runDiagnostics() } }
                    .disabled(model.isDiagnosing)
                Button("Repair All") { Task { await model.repairAllDiagnostics() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isDiagnosing
                            || !model.diagnostics.items.contains(where: {
                                $0.status == .failed && $0.repairAction != nil
                            })
                    )
            }
        }
        .padding(22)
        .task { await model.runDiagnostics() }
    }

    private func diagnosticSymbol(_ status: DiagnosticStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func diagnosticColor(_ status: DiagnosticStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 106)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
