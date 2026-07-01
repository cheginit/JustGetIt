import SwiftUI
import SwiftData

@main
struct JustGetItApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .modelContainer(for: DownloadRecord.self)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra("JustGetIt", systemImage: "arrow.down.circle") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
