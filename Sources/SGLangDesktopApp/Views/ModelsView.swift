import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var model: DesktopViewModel

    var body: some View {
        Group {
            if model.models.isEmpty {
                ContentUnavailableView {
                    Label("No models yet", systemImage: "externaldrive")
                } description: {
                    Text(
                        "The model catalog, resumable downloads, integrity verification, and shared storage are part of the initial product scope."
                    )
                }
            } else {
                List(model.models) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName).font(.headline)
                        Text(item.repository)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        Text(item.state.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(item.state == .ready ? .green : .secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Models")
        .toolbar {
            Text("HF / ModelScope cache autodiscovery")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
