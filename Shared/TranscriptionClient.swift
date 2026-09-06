import Foundation

/// What comes back from the proxy.
public struct TranscriptionResult: Codable, Equatable, Sendable {
    /// The cleaned-up text. This is what gets inserted.
    public let text: String
    /// The transcript before cleanup, when the server returns it. Recorded in
    /// history so you can see when cleanup is rewriting more than it should.
    public let rawText: String?

    enum CodingKeys: String, CodingKey {
        case text
        case rawText = "raw_text"
    }
}

/// Everything the server needs besides the audio itself.
public struct DictationOptions: Codable, Sendable {
    public var style: CleanupStyle
    /// Names and jargon the recogniser gets wrong on its own.
    public var vocabulary: [String]
    /// The text immediately before the cursor, so the cleanup pass can match tense,
    /// capitalisation and whether it is mid-sentence. Truncated, and unreliable in
    /// some host apps — see limitation 6 in the plan.
    public var context: String?
    public var locale: String

    public init(
        style: CleanupStyle,
        vocabulary: [String],
        context: String?,
        locale: String = Locale.current.identifier
    ) {
        self.style = style
        self.vocabulary = vocabulary
        self.context = context
        self.locale = locale
    }

    /// Built from whatever the container app last saved.
    public static func current(context: String?) -> DictationOptions {
        DictationOptions(
            style: SettingsStore.load().cleanupStyle,
            vocabulary: VocabularyStore.hints(),
            context: context
        )
    }

    enum CodingKeys: String, CodingKey {
        case style, vocabulary, context, locale
    }
}

/// Uploads a finished recording and waits for the cleaned-up text.
///
/// The simple path: one request, one answer. Higher latency than streaming because
/// nothing starts until you stop speaking, which is the Phase 4 problem.
///
/// All requests go to your own proxy rather than to an ASR vendor directly, so no
/// provider API key ever ships inside the app binary where it could be extracted.
public struct TranscriptionClient: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration)
    }

    public func transcribe(
        audio: RecordedAudio,
        options: DictationOptions
    ) async throws -> TranscriptionResult {
        let settings = SettingsStore.load()
        guard let base = settings.resolvedServerURL else { throw DictationError.notConfigured }
        guard !audio.pcm.isEmpty else { throw DictationError.emptyTranscript }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: base.appendingPathComponent("v1/dictate"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = KeychainStore.loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try Self.multipartBody(
            boundary: boundary,
            audio: audio,
            options: options
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw DictationError.cancelled }
            throw DictationError.network(error.localizedDescription)
        } catch {
            throw DictationError.network(error.localizedDescription)
        }

        try Self.validate(response: response, data: data)

        do {
            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch {
            throw DictationError.server(status: 200, message: "unreadable response")
        }
    }

    // MARK: - Wire format

    private static func multipartBody(
        boundary: String,
        audio: RecordedAudio,
        options: DictationOptions
    ) throws -> Data {
        var body = Data()

        func appendField(name: String, value: Data, contentType: String, filename: String? = nil) {
            var disposition = "form-data; name=\"\(name)\""
            if let filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: \(disposition)\r\n".utf8))
            body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
            body.append(value)
            body.append(Data("\r\n".utf8))
        }

        appendField(
            name: "options",
            value: try JSONEncoder().encode(options),
            contentType: "application/json"
        )
        appendField(
            name: "sample_rate",
            value: Data(String(Int(audio.sampleRate)).utf8),
            contentType: "text/plain"
        )
        appendField(
            name: "encoding",
            value: Data("pcm_s16le".utf8),
            contentType: "text/plain"
        )
        appendField(
            name: "audio",
            value: audio.pcm,
            contentType: "application/octet-stream",
            filename: "speech.pcm"
        )

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DictationError.network("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DictationError.unauthorized
            }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw DictationError.server(status: http.statusCode, message: message)
        }
    }

    struct ServerError: Decodable {
        let error: String
    }
}
