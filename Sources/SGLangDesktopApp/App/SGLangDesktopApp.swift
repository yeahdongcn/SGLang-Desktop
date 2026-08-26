import SGLangDesktopCore
import SwiftUI

@main
struct SGLangDesktopApp: App {
    @StateObject private var model = DesktopViewModel()

    var body: some Scene {
        WindowGroup("SGLang Desktop") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 360)
        }
    }
}
