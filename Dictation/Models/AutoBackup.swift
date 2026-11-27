import Foundation

/// Only explicit, user-editable preferences are encoded. Never encode AppSettings
/// directly: it contains the endpoint and the history retention preference.
struct BackupPreferences: Codable, Equatable {
    var cleanupStyle: CleanupStyle
    var micBehaviour: MicBehaviour
    var streamingEnabled: Bool
    var insertTrailingSpace: Bool
    var autoCapitalise: Bool
    var keyClicks: Bool
    var haptics: Bool

    init(_ settings: AppSettings) {
        cleanupStyle = settings.cleanupStyle
        micBehaviour = settings.micBehaviour
        streamingEnabled = settings.streamingEnabled
        insertTrailingSpace = settings.insertTrailingSpace
        autoCapitalise = settings.autoCapitalise
        keyClicks = settings.keyClicks
        haptics = settings.haptics
    }

    func applying(to settings: AppSettings) -> AppSettings {
        var result = settings
        result.cleanupStyle = cleanupStyle
        result.micBehaviour = micBehaviour
        result.streamingEnabled = streamingEnabled
        result.insertTrailingSpace = insertTrailingSpace
        result.autoCapitalise = autoCapitalise
        result.keyClicks = keyClicks
        result.haptics = haptics
        return result
    }
}

struct BackupPayload: Codable, Equatable {
    var preferences: BackupPreferences
    var vocabulary: [VocabularyTerm]

    func validate() throws {
        guard vocabulary.count <= VocabularyStore.maximumTerms,
              Set(vocabulary.map(\.id)).count == vocabulary.count,
              vocabulary.allSatisfy({ !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw BackupStore.Issue.invalid }
    }
}

struct BackupSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let savedAt: Date
    let payload: BackupPayload
}

struct BackupStore {
    enum Issue: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "This isn't a valid Dictation settings backup."
            case .tooLarge: return "The backup is too large."
            }
        }
    }

    struct State: Codable {
        var version = 1
        var enabled = false
        var copies: [BackupSnapshot] = []

        mutating func capture(_ payload: BackupPayload, now: Date = Date()) throws {
            guard enabled, copies.first?.payload != payload else { return }
            try payload.validate()
            copies.insert(BackupSnapshot(id: UUID(), savedAt: now, payload: payload), at: 0)
            copies = Array(copies.prefix(2))
        }
    }

    private struct File: Codable {
        let app: String
        let version: Int
        let snapshot: BackupSnapshot
    }

    static let maxFileSize = 2_000_000
    var directory: URL

    static func applicationStore() throws -> BackupStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("DictationLocalBackups", isDirectory: true)
        return BackupStore(directory: directory)
    }

    func load() throws -> State {
        let url = directory.appendingPathComponent("rotating-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        let state = try JSONDecoder().decode(State.self, from: Self.readBounded(url, maxSize: 2 * Self.maxFileSize))
        guard state.version == 1, state.copies.count <= 2 else { throw Issue.invalid }
        for copy in state.copies { try copy.payload.validate() }
        return state
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep automatic copies on this device. Only the explicit Files exporter
        // lets the owner choose another destination, such as iCloud Drive.
        var localDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try localDirectory.setResourceValues(resourceValues)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 2 * Self.maxFileSize else { throw Issue.tooLarge }
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent("rotating-v1.json"), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: directory.appendingPathComponent("rotating-v1.json"), options: .atomic)
        #endif
    }

    static func export(_ snapshot: BackupSnapshot) throws -> Data {
        try snapshot.payload.validate()
        let data = try JSONEncoder().encode(File(app: "com.asre1212.dictation.backup", version: 1, snapshot: snapshot))
        guard data.count <= maxFileSize else { throw Issue.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> BackupSnapshot {
        guard data.count <= maxFileSize else { throw Issue.tooLarge }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.app == "com.asre1212.dictation.backup", file.version == 1 else { throw Issue.invalid }
        try file.snapshot.payload.validate()
        return file.snapshot
    }

    static func readBounded(_ url: URL, maxSize: Int = maxFileSize) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxSize + 1) ?? Data()
        guard data.count <= maxSize else { throw Issue.tooLarge }
        return data
    }
}
