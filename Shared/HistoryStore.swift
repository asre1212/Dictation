import Foundation

/// One completed dictation.
public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    /// What came back from the cleanup pass — the text that was actually inserted.
    public var text: String
    /// The raw transcript before cleanup, when the server returned it. Useful for
    /// noticing when cleanup is rewriting more than it should.
    public var rawText: String?
    public var durationSeconds: Double
    /// Round trip from the end of speech to inserted text.
    public var latencySeconds: Double
    /// Where it came from: the keyboard, or the container app's own capture screen.
    public var source: Source

    public enum Source: String, Codable, Sendable {
        case keyboard
        case app
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        rawText: String? = nil,
        durationSeconds: Double,
        latencySeconds: Double,
        source: Source
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.durationSeconds = durationSeconds
        self.latencySeconds = latencySeconds
        self.source = source
    }
}

/// Dictation history, in a JSON file in the App Group container.
///
/// A file rather than `UserDefaults` because history is the one shared value that
/// grows, and both processes append to it. Writes are serialised on a private queue
/// and land atomically, so a keyboard write racing an app write loses an entry at
/// worst — it cannot corrupt the file.
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()

    /// Old entries are dropped past this. The keyboard reads the whole file to
    /// append, so this bounds the extension's memory as much as the disk.
    public static let maximumRecords = 200

    private let queue = DispatchQueue(label: "com.asre1212.dictation.history")
    private let fileURL: URL?

    private init() {
        fileURL = AppGroup.containerURL?.appendingPathComponent("history.json")
    }

    public func load() -> [DictationRecord] {
        queue.sync { readUnsafely() }
    }

    /// Appends a record, newest first, and trims to `maximumRecords`.
    /// Silently does nothing when history is switched off in settings.
    public func append(_ record: DictationRecord) {
        guard SettingsStore.load().keepHistory else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var records = self.readUnsafely()
            records.insert(record, at: 0)
            self.writeUnsafely(Array(records.prefix(Self.maximumRecords)))
        }
    }

    public func delete(ids: Set<UUID>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeUnsafely(self.readUnsafely().filter { !ids.contains($0.id) })
        }
    }

    public func clear() {
        queue.async { [weak self] in
            self?.writeUnsafely([])
        }
    }

    // MARK: - Private. Callers must already be on `queue`.

    private func readUnsafely() -> [DictationRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DictationRecord].self, from: data)) ?? []
    }

    private func writeUnsafely(_ records: [DictationRecord]) {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
