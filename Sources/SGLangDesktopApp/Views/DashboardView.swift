import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: DesktopViewModel

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
                    Text("Run SGLang locally")
                        .font(.largeTitle.bold())
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
