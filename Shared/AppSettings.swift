import Foundation

/// How aggressively the cleanup pass rewrites what you said.
public enum CleanupStyle: String, Codable, CaseIterable, Sendable {
    /// Punctuation and capitalisation only. Nothing is removed.
    case verbatim
    /// Filler words and false starts removed, punctuation added. The default.
    case clean
    /// As `clean`, plus light rephrasing into complete sentences.
    case polished

    public var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .polished: return "Polished"
        }
    }

    public var subtitle: String {
        switch self {
        case .verbatim: return "Punctuation only — nothing removed"
        case .clean: return "Drops filler words and false starts"
        case .polished: return "Also tidies phrasing into full sentences"
        }
    }
}

/// How the microphone key behaves.
public enum MicBehaviour: String, Codable, CaseIterable, Sendable {
    /// Press and hold to record, release to transcribe.
    case holdToTalk
    /// Tap to start, tap again to stop.
    case tapToToggle
    /// Hold if you hold, toggle if you tap. Decided by how long the press lasts.
    case automatic

    public var title: String {
        switch self {
        case .holdToTalk: return "Hold to talk"
        case .tapToToggle: return "Tap to start and stop"
        case .automatic: return "Automatic"
        }
    }
}

/// Settings shared between the container app and the keyboard extension.
///
/// Stored as JSON in the App Group's `UserDefaults` under a single key. One key
/// rather than many so that a read from the keyboard is atomic — a partially
/// written settings object mid-dictation would be worse than a stale one.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Base URL of your proxy service, e.g. `https://dictation.example.workers.dev`.
    public var serverURL: String
    public var cleanupStyle: CleanupStyle
    public var micBehaviour: MicBehaviour
    /// Stream audio while you speak instead of uploading after you stop.
    /// Off means higher latency but fewer moving parts; see Phase 4 of the plan.
    public var streamingEnabled: Bool
    /// Insert a trailing space after dictated text so the next word doesn't run on.
    public var insertTrailingSpace: Bool
    /// Capitalise the first word when the cursor is at the start of a sentence.
    public var autoCapitalise: Bool
    /// Keyboard click sound. Independent of the system setting, which extensions
    /// cannot read.
    public var keyClicks: Bool
    /// Haptic feedback on key presses. Requires Full Access; ignored without it.
    public var haptics: Bool
    /// Keep a local record of what you dictated. Off wipes existing history.
    public var keepHistory: Bool
    /// Extra keyboard height, in points, over the calculated default.
    public var extraKeyboardHeight: Double

    public static let `default` = AppSettings(
        serverURL: "",
        cleanupStyle: .clean,
        micBehaviour: .automatic,
        streamingEnabled: true,
        insertTrailingSpace: true,
        autoCapitalise: true,
        keyClicks: true,
        haptics: true,
        keepHistory: true,
        extraKeyboardHeight: 0
    )

    /// Lenient decoding: a settings object written by an older build is missing the
    /// keys added since, and losing every setting on upgrade is a worse failure than
    /// silently defaulting the new ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? fallback.serverURL
        cleanupStyle = try c.decodeIfPresent(CleanupStyle.self, forKey: .cleanupStyle) ?? fallback.cleanupStyle
        micBehaviour = try c.decodeIfPresent(MicBehaviour.self, forKey: .micBehaviour) ?? fallback.micBehaviour
        streamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? fallback.streamingEnabled
        insertTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .insertTrailingSpace) ?? fallback.insertTrailingSpace
        autoCapitalise = try c.decodeIfPresent(Bool.self, forKey: .autoCapitalise) ?? fallback.autoCapitalise
        keyClicks = try c.decodeIfPresent(Bool.self, forKey: .keyClicks) ?? fallback.keyClicks
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? fallback.haptics
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? fallback.keepHistory
        extraKeyboardHeight = try c.decodeIfPresent(Double.self, forKey: .extraKeyboardHeight) ?? fallback.extraKeyboardHeight
    }

    public init(
        serverURL: String,
        cleanupStyle: CleanupStyle,
        micBehaviour: MicBehaviour,
        streamingEnabled: Bool,
        insertTrailingSpace: Bool,
        autoCapitalise: Bool,
        keyClicks: Bool,
        haptics: Bool,
        keepHistory: Bool,
        extraKeyboardHeight: Double
    ) {
        self.serverURL = serverURL
        self.cleanupStyle = cleanupStyle
        self.micBehaviour = micBehaviour
        self.streamingEnabled = streamingEnabled
        self.insertTrailingSpace = insertTrailingSpace
        self.autoCapitalise = autoCapitalise
        self.keyClicks = keyClicks
        self.haptics = haptics
        self.keepHistory = keepHistory
        self.extraKeyboardHeight = extraKeyboardHeight
    }

    /// `true` once there is somewhere to send audio. The keyboard checks this before
    /// enabling the microphone key.
    public var isConfigured: Bool {
        resolvedServerURL != nil
    }

    /// The server URL as a `URL`, or `nil` if it is blank or unusable.
    /// Requires https, because the audio is your speech.
    public var resolvedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

/// Reads and writes `AppSettings` in the shared App Group container.
public enum SettingsStore {
    private static let key = "settings.v1"

    public static func load() -> AppSettings {
        guard let data = AppGroup.defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }

    public static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }
}
