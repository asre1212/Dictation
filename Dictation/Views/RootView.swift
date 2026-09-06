import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Dictate", systemImage: "mic") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }

            VocabularyView()
                .tabItem { Label("Words", systemImage: "textformat.abc") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .sheet(
            isPresented: Binding(
                get: { !model.hasCompletedOnboarding },
                set: { isPresented in
                    // Dismissed means setup is done. Driven through the model so
                    // "Show setup again" in Settings can reopen it.
                    if !isPresented { model.hasCompletedOnboarding = true }
                }
            )
        ) {
            OnboardingView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }
}
