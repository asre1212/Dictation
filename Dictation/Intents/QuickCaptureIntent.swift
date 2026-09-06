import AppIntents
import SwiftUI

/// "Hey Siri, take a dictation" — and the Action Button.
///
/// Disproportionate value for the size of the file: it is the only way to start a
/// dictation without first tapping into a text field and switching keyboards, which
/// is the one UX gap iOS gives no way to close from the keyboard side.
///
/// It opens the app rather than recording in the background. Recording without a
/// foreground app is not something iOS grants, and the intent is not the keyboard,
/// so guideline 4.4.1's "must not launch other apps" does not apply here.
struct QuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Take a Dictation"
    static var description = IntentDescription(
        "Opens Dictation and starts listening straight away."
    )

    /// Recording needs the app in front of the user.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCapture.request()
        return .result()
    }
}

/// The handoff between the intent and the capture screen.
///
/// A flag rather than a direct call because the intent may run before the scene
/// exists — on a cold launch from the Action Button, `perform()` finishes first and
/// the view reads the flag when it appears.
enum QuickCapture {
    private static let key = "quickCapture.pending"

    static func request() {
        AppGroup.defaults.set(true, forKey: key)
    }

    /// Reads and clears the flag. Returns `true` if a capture was requested.
    static func consume() -> Bool {
        guard AppGroup.defaults.bool(forKey: key) else { return false }
        AppGroup.defaults.set(false, forKey: key)
        return true
    }
}

struct DictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: [
                "Take a dictation with \(.applicationName)",
                "Start \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "Take a Dictation",
            systemImageName: "mic.fill"
        )
    }
}
