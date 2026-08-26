import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var model: DesktopViewModel
    @State private var isChoosingModel = false

    private let productCapabilities = [
        (
            "Multiple installations", "Independent SGLang and SGLang-Omni runtimes",
            "square.stack.3d.up"
        ),
        (
            "Apple-ready runtime", "Relocatable Python, PyTorch MPS, MLX, and media libraries",
            "apple.logo"
        ),
        (
            "One-click updates", "Versioned runtime updates without mutating a working install",
            "arrow.triangle.2.circlepath"
        ),
        (
            "Snapshots & rollback", "Return to the previous runtime when an update fails",
            "clock.arrow.circlepath"
        ),
        (
            "Model library", "Download, verify, reuse, and relocate model weights",
            "externaldrive.badge.icloud"
        ),
        (
            "Built-in diagnostics", "Health checks, logs, and actionable startup failures",
            "stethoscope"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Image("sglang-logo-square", bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    MetricCard(
                        title: "This Mac",
                        value: model.host.isSupported ? "Ready" : "Unsupported",
                        detail: model.host.platformLabel,
                        symbol: model.host.isSupported
                            ? "checkmark.circle.fill" : "xmark.octagon.fill",
                        tint: model.host.isSupported ? .green : .red
                    )
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

                VStack(alignment: .leading, spacing: 14) {
                    Text("Product scope")
                        .font(.title2.bold())

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12
                    ) {
                        ForEach(productCapabilities, id: \.0) { capability in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: capability.2)
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(capability.0).font(.headline)
                                    Text(capability.1)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(
                                .background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
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
    }
}

private struct EngineControlCard: View {
    @EnvironmentObject private var model: DesktopViewModel
    @Binding var isChoosingModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Try a local runtime", systemImage: "play.circle.fill")
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
                if model.selectedInstallation?.manifest.engine == .sglangOmni {
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
                }
                Button("Open API") { model.openAPI() }
                    .disabled(!model.healthStatus.hasPrefix("Ready"))
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
