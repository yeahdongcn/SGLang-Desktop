import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var model: DesktopViewModel

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        Group {
            if model.logEvents.isEmpty {
                ContentUnavailableView(
                    "No engine logs",
                    systemImage: "text.alignleft",
                    description: Text(
                        "Engine and supervisor output will appear here when a managed runtime starts."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.logEvents.enumerated()), id: \.offset) { _, event in
                            Text(
                                "\(Self.timestampFormatter.string(from: event.timestamp)) "
                                    + "[\(event.stream.rawValue)] \(event.message)"
                            )
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle("Logs")
    }
}
