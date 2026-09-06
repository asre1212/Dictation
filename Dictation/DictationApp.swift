import SwiftUI

@main
struct DictationApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Permission and keyboard installation both change in Settings, i.e.
            // outside this process, and there is no notification for either.
            model.refreshPermissions()
            model.refreshHistory()
        }
    }
}
