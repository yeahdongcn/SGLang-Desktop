import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: DesktopViewModel

    var body: some View {
        Form {
            Section("Platform") {
                LabeledContent("Target", value: "Apple Silicon Mac")
                LabeledContent("Detected", value: model.host.platformLabel)
                LabeledContent(
                    "Status", value: model.host.isSupported ? "Supported" : "Unsupported")
            }

            Section("Storage") {
                LabeledContent("Application data") {
                    Text(model.paths.root.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Models") {
                    Text(model.paths.models.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
