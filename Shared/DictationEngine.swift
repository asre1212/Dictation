import Foundation

/// Drives one dictation from button press to finished text.
///
/// Shared by the keyboard extension and the container app's capture screen so there
/// is exactly one implementation of the ordering that matters: open the socket
/// before the first audio frame, stop the microphone before waiting on the server,
/// and never fire a result twice.
///
/// Main-actor throughout: every caller is a view or a view controller, and the two
/// lower layers (`AudioRecorder`, `StreamingTranscriber`) already hop here before
/// calling back. The one exception is the audio chunk path, which stays on the tap's
/// own thread so a converted buffer goes straight out to the socket.
@MainActor
public final class DictationEngine {
    public enum State: Equatable {
        case idle
        case listening
        case transcribing
        case failed(DictationError)
    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Input level, 0...1, while listening.
    public var onLevel: (@MainActor (Float) -> Void)?
    public var onStateChange: (@MainActor (State) -> Void)?
    /// A revised in-progress transcript. Streaming mode only. Each replaces the last.
    public var onPartial: (@MainActor (String) -> Void)?
    /// The finished text, ready to insert.
    public var onFinal: (@MainActor (String) -> Void)?

    private let source: DictationRecord.Source
    private let recorder: AudioRecorder
    private var stream: StreamingTranscriber?
    private var options: DictationOptions = .current(context: nil)
    private var startedAt: CFAbsoluteTime = 0
    private var stoppedAt: CFAbsoluteTime = 0
    private var recordedDuration: TimeInterval = 0
    private var transcribeTask: Task<Void, Never>?

    public init(source: DictationRecord.Source) {
        self.source = source
        self.recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
        recorder.onFinish = { [weak self] result in self?.recordingFinished(result) }
    }

    public var isBusy: Bool {
        state == .listening || state == .transcribing
    }

    /// - Parameters:
    ///   - context: text immediately before the cursor, for tense and casing.
    ///   - hasFullAccess: pass the extension's `hasFullAccess`; the container app
    ///     passes `true`. Network is unreachable from a keyboard without it, so
    ///     failing here gives a message that names the actual cause instead of a
    ///     confusing timeout.
    public func start(context: String?, hasFullAccess: Bool = true) {
        guard !isBusy else { return }

        guard hasFullAccess else {
            state = .failed(.fullAccessDisabled)
            return
        }

        let settings = SettingsStore.load()
        guard settings.isConfigured else {
            state = .failed(.notConfigured)
            return
        }

        options = .current(context: context)
        startedAt = CFAbsoluteTimeGetCurrent()

        let streaming = settings.streamingEnabled
        if streaming {
            let stream = StreamingTranscriber()
            stream.onPartial = { [weak self] text in self?.onPartial?(text) }
            stream.onFinal = { [weak self] result in self?.deliver(result) }
            stream.onError = { [weak self] error in self?.failed(error) }
            do {
                // Opened first so the socket handshake overlaps with the microphone
                // spinning up rather than following it.
                try stream.start(options: options, sampleRate: 16_000)
                self.stream = stream
                recorder.onChunk = { [weak stream] chunk in stream?.send(chunk: chunk) }
            } catch let error as DictationError {
                state = .failed(error)
                return
            } catch {
                state = .failed(.network(error.localizedDescription))
                return
            }
        } else {
            recorder.onChunk = nil
        }

        do {
            try recorder.start(streaming: streaming)
            state = .listening
        } catch let error as DictationError {
            stream?.cancel()
            stream = nil
            state = .failed(error)
        } catch {
            stream?.cancel()
            stream = nil
            state = .failed(.microphoneUnavailable(error.localizedDescription))
        }
    }

    /// Ends speech. The result arrives later, via `onFinal` or a `.failed` state.
    public func stop() {
        guard state == .listening else { return }
        stoppedAt = CFAbsoluteTimeGetCurrent()
        recorder.stop()
    }

    /// Abandons the dictation. Nothing is inserted and nothing is recorded.
    public func cancel() {
        transcribeTask?.cancel()
        transcribeTask = nil
        stream?.cancel()
        stream = nil
        recorder.cancel()
        state = .idle
    }

    /// Clears a `.failed` state once the message has been shown.
    public func acknowledgeFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: - Private

    private func recordingFinished(_ result: Result<RecordedAudio, DictationError>) {
        switch result {
        case .failure(.cancelled):
            stream?.cancel()
            stream = nil
            state = .idle

        case .failure(let error):
            stream?.cancel()
            stream = nil
            failed(error)

        case .success(let audio):
            recordedDuration = audio.duration
            if stoppedAt == 0 { stoppedAt = CFAbsoluteTimeGetCurrent() }

            // Too short to be speech — almost always a mis-tap on the mic key.
            guard audio.duration > 0.25 else {
                stream?.cancel()
                stream = nil
                failed(.emptyTranscript)
                return
            }

            state = .transcribing

            if let stream {
                // Streaming: the audio is already up there. The `final` frame is
                // what completes the dictation, via `deliver`.
                stream.finishSending()
            } else {
                transcribeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let result = try await TranscriptionClient().transcribe(
                            audio: audio,
                            options: self.options
                        )
                        if Task.isCancelled { return }
                        self.deliver(result)
                    } catch let error as DictationError {
                        if Task.isCancelled { return }
                        self.failed(error)
                    } catch {
                        if Task.isCancelled { return }
                        self.failed(.network(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func deliver(_ result: TranscriptionResult) {
        stream = nil
        transcribeTask = nil

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failed(.emptyTranscript)
            return
        }

        HistoryStore.shared.append(
            DictationRecord(
                text: text,
                rawText: result.rawText,
                durationSeconds: recordedDuration,
                latencySeconds: max(0, CFAbsoluteTimeGetCurrent() - stoppedAt),
                source: source
            )
        )

        state = .idle
        onFinal?(text)
    }

    private func failed(_ error: DictationError) {
        stream = nil
        transcribeTask = nil
        state = .failed(error)
    }
}
