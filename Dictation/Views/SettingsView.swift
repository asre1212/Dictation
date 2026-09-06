import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $model.settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Access token", text: $model.token)
                        .onSubmit { model.saveToken() }
                } header: {
                    Text("Server")
                } footer: {
                    Text("""
                        Audio goes to a proxy you run, which holds the provider API \
                        keys. Shipping those keys in the app would put them one \
                        binary inspection away from anyone. https is required.
                        """)
                }

                Section {
                    Picker("Cleanup", selection: $model.settings.cleanupStyle) {
                        ForEach(CleanupStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Text(model.settings.cleanupStyle.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Stream while speaking", isOn: $model.settings.streamingEnabled)
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("""
                        Streaming starts uploading on the first word instead of \
                        waiting until you stop, which is most of the difference \
                        between fast and sluggish. Turn it off to fall back to a \
                        single upload if your server doesn't support it.
                        """)
                }

                Section {
                    Picker("Microphone key", selection: $model.settings.micBehaviour) {
                        ForEach(MicBehaviour.allCases, id: \.self) { behaviour in
                            Text(behaviour.title).tag(behaviour)
                        }
                    }
                    Toggle("Space after dictation", isOn: $model.settings.insertTrailingSpace)
                    Toggle("Auto-capitalise", isOn: $model.settings.autoCapitalise)
                    Toggle("Key clicks", isOn: $model.settings.keyClicks)
                    Toggle("Haptics", isOn: $model.settings.haptics)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Haptic feedback needs Full Access. Sliding off the microphone key before letting go cancels a dictation.")
                }

                Section {
                    Toggle("Keep history", isOn: $model.settings.keepHistory)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("History is stored only on this device, in the container shared with the keyboard. Audio is never written to disk.")
                }

                Section("Setup") {
                    LabeledContent("Microphone") {
                        StatusText(isGood: model.isMicrophoneGranted, good: "Allowed", bad: "Not allowed")
                    }
                    LabeledContent("Keyboard added") {
                        StatusText(isGood: model.isKeyboardInstalled, good: "Yes", bad: "No")
                    }
                    LabeledContent("App Group") {
                        StatusText(isGood: AppGroup.isConfigured, good: "Working", bad: "Misconfigured")
                    }
                    Button("Open iOS Settings") { model.openSettings() }
                    Button("Show setup again") { model.hasCompletedOnboarding = false }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text("Full Access can't be checked from here — only the keyboard itself can see it. If dictation fails in the keyboard but works in this app, that's the first thing to check.")
                }
            }
            .navigationTitle("Settings")
            .onDisappear { model.saveToken() }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

private struct StatusText: View {
    let isGood: Bool
    let good: String
    let bad: String

    var body: some View {
        Text(isGood ? good : bad)
            .foregroundStyle(isGood ? .green : .orange)
    }
}
