import Foundation

/// Every failure the dictation pipeline can present to the user.
///
/// The keyboard has roughly one line of space to explain what went wrong, so each
/// case carries a short message written for that constraint rather than a
/// developer-facing description.
public enum DictationError: LocalizedError, Equatable {
    case fullAccessDisabled
    case microphonePermissionDenied
    case microphoneUnavailable(String)
    case notConfigured
    case network(String)
    case server(status: Int, message: String?)
    case unauthorized
    case emptyTranscript
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .fullAccessDisabled:
            return "Turn on Full Access to dictate"
        case .microphonePermissionDenied:
            return "Allow the microphone in the Dictation app"
        case .microphoneUnavailable(let detail):
            return "Microphone unavailable — \(detail)"
        case .notConfigured:
            return "Add your server address in the Dictation app"
        case .network(let detail):
            return "No connection — \(detail)"
        case .server(let status, let message):
            return message.map { "Server error: \($0)" } ?? "Server error (\(status))"
        case .unauthorized:
            return "Sign in again in the Dictation app"
        case .emptyTranscript:
            return "Didn't catch that"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Whether retrying the same request could plausibly succeed. Drives whether the
    /// keyboard offers a retry affordance or sends the user to the container app.
    public var isRetryable: Bool {
        switch self {
        case .network, .server, .emptyTranscript, .microphoneUnavailable:
            return true
        case .fullAccessDisabled, .microphonePermissionDenied, .notConfigured, .unauthorized, .cancelled:
            return false
        }
    }
}
