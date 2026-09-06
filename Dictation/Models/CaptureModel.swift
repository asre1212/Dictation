import Combine
import SwiftUI

/// Drives the in-app capture screen.
///
/// Same engine the keyboard uses, so this screen doubles as the fastest way to tell
/// whether a transcription problem is in the pipeline or in the extension: if
/// dictation works here and not in the keyboard, the difference is Full Access or
/// the audio-session entitlement, not the server.
@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var state: DictationEngine.State = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var partial: String = ""
    @Published var text: String = ""

    private let engine = DictationEngine(source: .app)

    init() {
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            if state != .listening { self.level = 0 }
        }
        engine.onLevel = { [weak self] level in self?.level = level }
        engine.onPartial = { [weak self] text in self?.partial = text }
        engine.onFinal = { [weak self] text in
            guard let self else { return }
            self.partial = ""
            self.text = self.text.isEmpty ? text : self.text + " " + text
        }
    }

    var isListening: Bool { state == .listening }
    var isBusy: Bool { engine.isBusy }

    var errorMessage: String? {
        guard case .failed(let error) = state else { return nil }
        return error.errorDescription
    }

    func toggle() {
        switch state {
        case .listening:
            engine.stop()
        case .transcribing:
            engine.cancel()
        default:
            partial = ""
            engine.start(context: text.isEmpty ? nil : String(text.suffix(400)))
        }
    }

    func clear() {
        text = ""
        partial = ""
        engine.acknowledgeFailure()
    }
}
