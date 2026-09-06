import Foundation

/// Streams audio to the proxy over a WebSocket while you are still speaking, and
/// receives partial transcripts as they firm up.
///
/// This is the difference between "feels instant" and "feels like a round trip":
/// upload starts on the first audio frame rather than on release, so by the time
/// you stop speaking most of the work is already done. Phase 4 in the plan.
///
/// Wire protocol, in order:
///   → `{"type":"start", "sample_rate":16000, "encoding":"pcm_s16le", "options":{…}}`
///   → binary frames of 16 kHz mono Int16 PCM
///   → `{"type":"stop"}`
///   ← `{"type":"partial","text":"…"}`  (zero or more, each replacing the last)
///   ← `{"type":"final","text":"…","raw_text":"…"}`
///   ← `{"type":"error","message":"…"}`
public final class StreamingTranscriber: NSObject, @unchecked Sendable {
    /// A revised in-progress transcript. Each one replaces the previous.
    public var onPartial: (@MainActor (String) -> Void)?
    /// The cleaned-up final text. Terminal — fires at most once.
    public var onFinal: (@MainActor (TranscriptionResult) -> Void)?
    /// Terminal — fires at most once, and never alongside `onFinal`.
    public var onError: (@MainActor (DictationError) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var hasFinished = false
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Opens the socket and sends the start frame. Throws only for configuration
    /// problems; transport failures arrive via `onError`.
    public func start(options: DictationOptions, sampleRate: Double) throws {
        let settings = SettingsStore.load()
        guard let base = settings.resolvedServerURL else { throw DictationError.notConfigured }

        // https base, wss socket.
        var components = URLComponents(
            url: base.appendingPathComponent("v1/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = "wss"
        guard let url = components?.url else { throw DictationError.notConfigured }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = KeychainStore.loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)

        self.session = session
        self.task = task

        task.resume()
        receiveNext()

        let start = StartFrame(
            type: "start",
            sampleRate: Int(sampleRate),
            encoding: "pcm_s16le",
            options: options
        )
        send(json: start)
    }

    /// Sends one converted chunk. Safe to call from the audio tap thread.
    public func send(chunk: Data) {
        guard !isFinished else { return }
        task?.send(.data(chunk)) { [weak self] error in
            if let error { self?.fail(.network(error.localizedDescription)) }
        }
    }

    /// Signals end of speech. The server replies with a `final` frame, which is when
    /// `onFinal` fires — this method does not itself end the exchange.
    public func finishSending() {
        guard !isFinished else { return }
        send(json: StopFrame(type: "stop"))
    }

    /// Tears the socket down without waiting for a final transcript.
    public func cancel() {
        guard !markFinished() else { return }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    // MARK: - Receiving

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let urlError = error as? URLError
                if urlError?.code == .cancelled { return }
                self.fail(.network(error.localizedDescription))
            case .success(let message):
                self.handle(message: message)
                self.receiveNext()
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return
        }

        guard let frame = try? JSONDecoder().decode(ServerFrame.self, from: data) else { return }

        switch frame.type {
        case "partial":
            guard let text = frame.text else { return }
            onMain { [weak self] in self?.onPartial?(text) }
        case "final":
            guard !markFinished() else { return }
            let result = TranscriptionResult(text: frame.text ?? "", rawText: frame.rawText)
            closeSocket()
            onMain { [weak self] in self?.onFinal?(result) }
        case "error":
            fail(.server(status: frame.status ?? 500, message: frame.message))
        default:
            break
        }
    }

    // MARK: - Plumbing

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasFinished
    }

    /// Marks the exchange over. Returns `true` if it was *already* over, so callers
    /// can bail — exactly one of `onFinal` / `onError` ever fires.
    private func markFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if hasFinished { return true }
        hasFinished = true
        return false
    }

    private func fail(_ error: DictationError) {
        guard !markFinished() else { return }
        closeSocket()
        onMain { [weak self] in self?.onError?(error) }
    }

    /// URLSession delivers on its own queue; every callback out of this class
    /// crosses to the main actor here.
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private func closeSocket() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
    }

    private func send<T: Encodable>(json value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.fail(.network(error.localizedDescription)) }
        }
    }

    // MARK: - Frames

    private struct StartFrame: Encodable {
        let type: String
        let sampleRate: Int
        let encoding: String
        let options: DictationOptions

        enum CodingKeys: String, CodingKey {
            case type, encoding, options
            case sampleRate = "sample_rate"
        }
    }

    private struct StopFrame: Encodable {
        let type: String
    }

    private struct ServerFrame: Decodable {
        let type: String
        let text: String?
        let rawText: String?
        let message: String?
        let status: Int?

        enum CodingKeys: String, CodingKey {
            case type, text, message, status
            case rawText = "raw_text"
        }
    }
}
