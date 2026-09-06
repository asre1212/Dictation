import Foundation

/// The single place the App Group identifier is written down.
///
/// Both targets are members of this group; it is how the keyboard extension reads
/// settings, vocabulary and the auth token written by the container app. The
/// extension cannot reach the container app's private storage any other way.
///
/// If you change this string you must also change it in:
///   - `Dictation/Dictation.entitlements`
///   - `DictationKeyboard/DictationKeyboard.entitlements`
///   - the App Group capability on both targets in Xcode.
public enum AppGroup {
    public static let identifier = "group.com.asre1212.dictation"

    /// Shared defaults. Falls back to standard defaults so a misconfigured App Group
    /// degrades into "settings don't sync between app and keyboard" rather than a crash.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// `nil` when the App Group capability is missing or the identifier is wrong.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// True when the group is actually wired up. Surfaced in the container app's
    /// diagnostics, because a silent misconfiguration here looks like "the keyboard
    /// ignores my settings" and is otherwise very hard to diagnose.
    public static var isConfigured: Bool {
        containerURL != nil
    }
}
