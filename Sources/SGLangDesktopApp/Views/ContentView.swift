import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DesktopViewModel

    var body: some View {
        NavigationSplitView {
            List(DesktopViewModel.Section.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("SGLang")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            Group {
                switch model.selection ?? .dashboard {
                case .dashboard:
                    DashboardView()
                case .installations:
                    InstallationsView()
                case .models:
                    ModelsView()
                case .logs:
                    LogsView()
                }
            }
            .alert(
                "SGLang Desktop",
                isPresented: Binding(
                    get: { model.lastError != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.lastError ?? "Unknown error")
            }
        }
    }
}
