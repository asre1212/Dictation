import AVFoundation
import Foundation

/// Captured speech, ready to upload.
public struct RecordedAudio: Sendable {
    /// 16 kHz mono signed 16-bit little-endian PCM, no header.
    public let pcm: Data
    public let sampleRate: Double
    public let duration: TimeInterval
}

/// Microphone capture for both targets.
///
/// The output format is fixed at 16 kHz mono Int16 — what speech recognisers want,
/// and small enough that a minute of it is under 2 MB. That matters more than usual
/// here: the keyboard extension runs under a memory cap of roughly 48 MB and is
/// killed outright if it goes over, so this class never retains audio it does not
/// have to. In streaming mode it retains none at all, handing each converted chunk
/// straight to `onChunk` and dropping it.
///
/// Whether this works *at all* inside a keyboard extension is the open question the
/// whole project hangs on — see `docs/iphone-dictation-feasibility.md`, Phase 0.
/// The failure is not subtle: `setActive` throws, or the tap delivers silence.
public final class AudioRecorder {
    public struct Configuration: Sendable {
        public var sampleRate: Double = 16_000
        /// Hard stop. Guards the memory cap in buffered mode and protects against a
        /// mic key left latched on.
        public var maximumDuration: TimeInterval = 60
        /// Frames per tap callback at the hardware rate. ~2048 keeps callbacks
        /// frequent enough for a responsive level meter without thrashing.
        public var tapBufferSize: AVAudioFrameCount = 2048

        public init() {}
    }

    /// A converted chunk of 16 kHz mono Int16 PCM. Streaming mode only.
    public var onChunk: ((Data) -> Void)?
    /// Normalised 0...1 input level, for the waveform.
    public var onLevel: (@MainActor (Float) -> Void)?
    /// Fired when recording ends for any reason, including hitting the duration cap.
    public var onFinish: (@MainActor (Result<RecordedAudio, DictationError>) -> Void)?

    public private(set) var isRecording = false

    private let configuration: Configuration
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    /// Buffered mode only. Empty while streaming.
    private var buffered = Data()
    private var isStreaming = false
    private var startedAt: CFAbsoluteTime = 0
    private var capTimer: DispatchSourceTimer?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        capTimer?.cancel()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Current microphone authorisation. Note this can only be *requested* from the
    /// container app — a keyboard extension can read the answer but never prompt.
    public static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// - Parameter streaming: `true` sends chunks to `onChunk` and keeps nothing;
    ///   `false` accumulates and hands the whole recording to `onFinish`.
    public func start(streaming: Bool) throws {
        guard !isRecording else { return }

        guard Self.permission == .granted else {
            throw DictationError.microphonePermissionDenied
        }

        isStreaming = streaming
        buffered.removeAll(keepingCapacity: false)

        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` disables the processing that would otherwise gate and
            // compress the signal; speech recognisers do better without it.
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.duckOthers, .allowBluetooth]
            )
            try session.setActive(true, options: [])
        } catch {
            throw DictationError.microphoneUnavailable(Self.describe(error))
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // A zero sample rate means the session handed back a dead input — the shape
        // the keyboard-extension entitlement failure takes in practice.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            deactivateSession()
            throw DictationError.microphoneUnavailable("no input available")
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            deactivateSession()
            throw DictationError.microphoneUnavailable("unsupported input format")
        }

        outputFormat = target
        self.converter = converter

        inputNode.installTap(
            onBus: 0,
            bufferSize: configuration.tapBufferSize,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            deactivateSession()
            throw DictationError.microphoneUnavailable(Self.describe(error))
        }

        startedAt = CFAbsoluteTimeGetCurrent()
        isRecording = true
        scheduleDurationCap()
    }

    /// Ends recording and fires `onFinish` with whatever was captured.
    public func stop() {
        finish(with: nil)
    }

    /// Ends recording and fires `onFinish` with `.cancelled`. Nothing is uploaded.
    public func cancel() {
        finish(with: .cancelled)
    }

    // MARK: - Capture

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }

        publishLevel(from: buffer)

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        // The converter pulls; hand it this tap buffer exactly once, then report
        // starvation so it returns what it has rather than blocking for more.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        let chunk = Data(bytes: channel[0], count: byteCount)

        if isStreaming {
            onChunk?(chunk)
        } else {
            // Belt and braces alongside the duration cap: never let the buffer grow
            // past what the extension's memory ceiling can survive.
            let limit = Int(configuration.sampleRate * configuration.maximumDuration) * MemoryLayout<Int16>.size
            if buffered.count < limit {
                buffered.append(chunk)
            }
        }
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }

        var sum: Float = 0
        let frames = Int(buffer.frameLength)
        // Every fourth frame is plenty for a 60 fps meter and a quarter of the work.
        var index = 0
        var counted = 0
        while index < frames {
            let sample = channel[index]
            sum += sample * sample
            counted += 1
            index += 4
        }
        guard counted > 0 else { return }

        let rms = sqrt(sum / Float(counted))
        // -50 dBFS reads as silence, 0 dBFS as full scale.
        let db = 20 * log10(max(rms, 0.000_001))
        let level = max(0, min(1, (db + 50) / 50))

        onMain { [weak self] in
            self?.onLevel?(level)
        }
    }

    // MARK: - Teardown

    private func scheduleDurationCap() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + configuration.maximumDuration)
        timer.setEventHandler { [weak self] in
            self?.stop()
        }
        timer.resume()
        capTimer = timer
    }

    private func finish(with error: DictationError?) {
        guard isRecording else { return }
        isRecording = false

        capTimer?.cancel()
        capTimer = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        deactivateSession()

        let duration = CFAbsoluteTimeGetCurrent() - startedAt
        let pcm = buffered
        buffered.removeAll(keepingCapacity: false)

        let result: Result<RecordedAudio, DictationError>
        if let error {
            result = .failure(error)
        } else {
            result = .success(
                RecordedAudio(
                    pcm: pcm,
                    sampleRate: configuration.sampleRate,
                    duration: duration
                )
            )
        }

        onMain { [weak self] in
            self?.onFinish?(result)
        }
    }

    /// Hops to the main actor. The audio tap runs on a real-time thread, so every
    /// callback out of this class crosses a queue boundary exactly here.
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    /// The audio-session errors that matter here are the ones a keyboard extension
    /// hits without the right entitlement, and they are opaque numbers in the log.
    /// Name them, so a Phase 0 failure is diagnosable from the device.
    private static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case 561_015_905:
            return "session activation refused (!act) — check Full Access"
        case 561_145_187:
            return "recording not permitted (!pri) — extension lacks audio entitlement"
        case 561_017_449:
            return "session busy (!int)"
        default:
            return "error \(code)"
        }
    }
}
