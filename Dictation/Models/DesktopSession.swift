import AVFoundation
import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Separate from the legacy cloud DictationEngine: no API calls, shared history,
/// App Group settings, analytics, or persistent recording files in this path.
@MainActor
final class DesktopSession: ObservableObject {
    @Published var pairingLink = ""
    @Published private(set) var connected = false
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Open Dictation Desktop on your computer, then scan its pairing code."
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var canRetry = false

    private var endpoint: URL?
    private var token = ""
    private var deviceID = UUID().uuidString
    private var session: URLSession?
    private var recorder: AudioRecorder?
    private var pending: Data?
    private var pendingID: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    func pair(_ link: String) {
        guard !busy, !recording else { return }
        disconnect()
        guard let parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "dictation", parts.host == "desktop",
              let items = parts.queryItems,
              items.filter({ $0.name == "endpoint" }).count == 1,
              items.filter({ $0.name == "token" }).count == 1,
              items.filter({ $0.name == "fingerprint" }).count == 1,
              let address = items.first(where: { $0.name == "endpoint" })?.value,
              let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let secret = items.first(where: { $0.name == "token" })?.value,
              secret.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let fingerprint = items.first(where: { $0.name == "fingerprint" })?.value,
              fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { status = "Invalid pairing link. Scan a fresh code from your computer."; return }
        let attempt = generation
        busy = true
        status = "Verify your identity to pair."
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let auth = LAContext()
                guard try await auth.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Connect to your private medical dictation session.") else { throw DesktopError.message("Authentication required.") }
                guard self.generation == attempt, !Task.isCancelled else { return }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 180
                configuration.timeoutIntervalForResource = 200
                self.endpoint = url
                self.token = secret
                self.session = URLSession(configuration: configuration, delegate: DesktopTrustDelegate(host: url.host!, fingerprint: fingerprint), delegateQueue: nil)
                self.status = "Connecting to computer…"
                let body = try JSONSerialization.data(withJSONObject: ["deviceId": self.deviceID])
                _ = try await self.request(path: "v1/pair", data: body, contentType: "application/json")
                guard self.generation == attempt, !Task.isCancelled else { return }
                self.connected = true
                self.pairingLink = ""
                self.status = "Connected. Audio will be transcribed on your computer."
            } catch {
                guard self.generation == attempt else { return }
                self.session?.invalidateAndCancel(); self.session = nil
                self.token = ""; self.endpoint = nil
                self.status = "Connection failed. Check the computer, Wi-Fi/VPN, firewall and pairing code."
            }
            if self.generation == attempt { self.busy = false }
        }
    }

    func toggleRecording() {
        if recording { recorder?.stop(); return }
        guard connected, !busy, !canRetry else { return }
        let attempt = generation
        busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard self.generation == attempt, !Task.isCancelled else { return }
            self.busy = false
            guard granted else { self.status = "Allow microphone access in iPhone Settings."; return }
            let recorder = AudioRecorder()
            recorder.onLevel = { [weak self] value in self?.level = value }
            recorder.onFinish = { [weak self] result in
                guard let self, self.generation == attempt else { return }
                self.recording = false; self.level = 0
                switch result {
                case .success(let audio):
                    guard audio.pcm.count >= 3200 else { self.status = "Recording was too short. Try again."; return }
                    self.pending = Data(audio.pcm.prefix(16000 * 2 * 60))
                    self.pendingID = UUID().uuidString
                    self.sendPending()
                case .failure:
                    self.status = "Recording stopped. Try again."
                }
            }
            self.recorder = recorder
            do {
                try recorder.start(streaming: false)
                self.recording = true
                self.status = "Recording · tap Stop to send · 60-second maximum"
            } catch { self.status = "Microphone unavailable. Close other audio apps and retry." }
        }
    }

    func sendPending() {
        guard connected, !busy, let audio = pending, let requestID = pendingID else { return }
        let attempt = generation
        busy = true; canRetry = false
        status = "Transcribing on your computer…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request(path: "v1/audio", data: audio, contentType: "audio/pcm", requestID: requestID)
                guard self.generation == attempt, !Task.isCancelled else { return }
                let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
                guard let text = object?["text"] as? String else { throw DesktopError.message("Invalid response.") }
                let alreadyDelivered = object?["alreadyDelivered"] as? Bool == true
                if !alreadyDelivered { self.transcript = text }
                self.pending = nil; self.pendingID = nil
                self.status = alreadyDelivered ? "Already delivered. Review the draft on the computer." : text.isEmpty ? "No speech detected. Try again closer to the microphone." : "Received on computer. Review the draft there before using it."
            } catch {
                guard self.generation == attempt else { return }
                self.canRetry = true
                self.status = "Transfer incomplete. Retry sends the same recording without duplicating the draft."
            }
            if self.generation == attempt { self.busy = false }
        }
    }

    func discardRecording() {
        pending = nil; pendingID = nil; canRetry = false
        status = "Recording discarded. Ready to dictate."
    }

    func interrupted() {
        if recording { recorder?.cancel(); recording = false; level = 0; status = "Audio interrupted. Please record again." }
    }

    func disconnect() {
        generation = UUID()
        operation?.cancel(); operation = nil
        recorder?.onFinish = nil; recorder?.cancel(); recorder = nil
        session?.invalidateAndCancel(); session = nil
        endpoint = nil; token = ""; pairingLink = ""; deviceID = UUID().uuidString
        pending = nil; pendingID = nil; transcript = ""; canRetry = false
        connected = false; recording = false; busy = false; level = 0
        status = "Session cleared. Start a new pairing session on the computer."
    }

    private func request(path: String, data: Data, contentType: String, requestID: String? = nil) async throws -> Data {
        guard let endpoint, let session else { throw DesktopError.message("Not connected.") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let requestID { request.setValue(requestID, forHTTPHeaderField: "X-Dictation-Id") }
        let (result, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DesktopError.message("Request failed.") }
        return result
    }
}

private enum DesktopError: Error { case message(String) }

/// Trust exactly the certificate in the QR code, for exactly the paired host.
/// No global ATS bypass, no accepting arbitrary self-signed certificates.
private final class DesktopTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let host: String
    let fingerprint: String
    init(host: String, fingerprint: String) { self.host = host; self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
