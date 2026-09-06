import SwiftUI

/// The setup the keyboard extension cannot do for itself.
///
/// Three steps, in this order, because each depends on the last: the microphone
/// prompt only exists in this process; Full Access is what lets the extension reach
/// the network at all; and neither matters until there is a server to talk to.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speak anywhere")
                            .font(.title2.weight(.semibold))
                        Text("""
                            Three things need setting up before the keyboard can \
                            dictate. Only this app can do them — the keyboard is \
                            not allowed to ask on its own.
                            """)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("1. Microphone") {
                    StepRow(
                        title: "Allow the microphone",
                        detail: "The keyboard can use the microphone, but only this app can ask for permission.",
                        isDone: model.isMicrophoneGranted
                    )
                    if model.microphonePermission == .undetermined {
                        Button("Allow microphone") {
                            Task { await model.requestMicrophonePermission() }
                        }
                    } else if model.microphonePermission == .denied {
                        Button("Open Settings") { model.openSettings() }
                    }
                }

                Section("2. Keyboard") {
                    StepRow(
                        title: "Add the keyboard",
                        detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard › Dictation.",
                        isDone: model.isKeyboardInstalled
                    )
                    StepRow(
                        title: "Turn on Full Access",
                        detail: "Tap Dictation in that same list and turn on Allow Full Access. Without it the keyboard can type, but not reach the network to transcribe.",
                        isDone: nil
                    )
                    Button("Open Settings") { model.openSettings() }
                }

                Section("3. Server") {
                    StepRow(
                        title: "Point it at your server",
                        detail: "Audio goes to a proxy you run, which holds the API keys. See server/README.md.",
                        isDone: model.isServerConfigured
                    )
                    TextField("https://…", text: $model.settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Access token", text: $model.token)
                        .onSubmit { model.saveToken() }
                }

                if !AppGroup.isConfigured {
                    Section {
                        Label(
                            "The App Group isn't set up, so the keyboard can't read these settings. Check the App Group capability on both targets.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.saveToken()
                        // Closes the sheet: the presentation binding reads this.
                        model.hasCompletedOnboarding = true
                    }
                }
            }
        }
    }
}

/// One setup step. `isDone == nil` means the app has no way to check — Full Access
/// in particular is invisible from here.
private struct StepRow: View {
    let title: String
    let detail: String
    let isDone: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch isDone {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "circle"
        case nil: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch isDone {
        case .some(true): return .green
        case .some(false): return .secondary
        case nil: return .secondary
        }
    }
}
