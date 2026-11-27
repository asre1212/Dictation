import Foundation

/// Only explicit, user-editable preferences are encoded. Never encode AppSettings
/// directly: it contains the endpoint and the history retention preference.
struct BackupPreferences: Codable, Equatable, Sendable {
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

struct BackupPayload: Codable, Equatable, Sendable {
    var preferences: BackupPreferences
    var vocabulary: [VocabularyTerm]

    func validate() throws {
        guard vocabulary.count <= VocabularyStore.maximumTerms,
              Set(vocabulary.map(\.id)).count == vocabulary.count,
              vocabulary.allSatisfy({ !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw BackupStore.Issue.invalid }
    }
}

struct BackupSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let savedAt: Date
    let payload: BackupPayload
}

struct BackupStore {
    enum Issue: LocalizedError {
        case invalid, tooLarge, folderAccess, occupiedSlot, verification
        var errorDescription: String? {
            switch self {
            case .invalid: return "This isn't a valid Dictation settings backup."
            case .tooLarge: return "The backup is too large."
            case .folderAccess: return "Can't access the backup folder. Select it again in Files."
            case .occupiedSlot: return "A backup slot contains an unknown file. No existing file was overwritten."
            case .verification: return "Couldn't verify the new Files backup. Check the folder and try again."
            }
        }
    }

    struct State: Codable {
        var version = 1
        var enabled = false
        var copies: [BackupSnapshot] = []

    }

    private struct File: Codable {
        let app: String
        let version: Int
        let snapshot: BackupSnapshot
        let owner: UUID?
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

    static func export(_ snapshot: BackupSnapshot, owner: UUID? = nil) throws -> Data {
        try snapshot.payload.validate()
        let data = try JSONEncoder().encode(File(app: "com.asre1212.dictation.backup", version: 1, snapshot: snapshot, owner: owner))
        guard data.count <= maxFileSize else { throw Issue.tooLarge }
        return data
    }

    static func decode(_ data: Data, requiredOwner: UUID? = nil) throws -> BackupSnapshot {
        guard data.count <= maxFileSize else { throw Issue.tooLarge }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.app == "com.asre1212.dictation.backup", file.version == 1 else { throw Issue.invalid }
        if let requiredOwner, file.owner != requiredOwner { throw Issue.occupiedSlot }
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


/// Owns exactly two predetermined files per selected folder and installation.
/// Writes replace the oldest only after its ownership is verified; no pruning
/// or writes to unrelated paths take place.
enum ExternalFolderBackup {
    static func capture(in folder: URL, owner: UUID, payload: BackupPayload, now: Date = Date()) throws -> BackupSnapshot {
        try payload.validate()
        let fm = FileManager.default
        let directory = folder.appendingPathComponent("Dictation Auto Backup " + owner.uuidString, isDirectory: true)
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupStore.Issue.occupiedSlot }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let slots = ["Backup A.json", "Backup B.json"].map { directory.appendingPathComponent($0) }
        let existing: [BackupSnapshot?] = try slots.map { url in
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BackupStore.Issue.occupiedSlot }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return nil
            }
            return try BackupStore.decode(BackupStore.readBounded(url), requiredOwner: owner)
        }
        let newest = existing.compactMap { $0 }.max { $0.savedAt < $1.savedAt }
        if let newest, newest.payload == payload { return newest }
        let savedAt = max(now, newest?.savedAt.addingTimeInterval(0.001) ?? now)
        let snapshot = BackupSnapshot(id: UUID(), savedAt: savedAt, payload: payload)
        let target: Int
        if existing[0] == nil { target = 0 }
        else if existing[1] == nil { target = 1 }
        else { target = existing[0]!.savedAt < existing[1]!.savedAt ? 0 : 1 }
        let bytes = try BackupStore.export(snapshot, owner: owner)
        try bytes.write(to: slots[target], options: .atomic)
        guard try BackupStore.decode(BackupStore.readBounded(slots[target]), requiredOwner: owner) == snapshot else {
            throw BackupStore.Issue.verification
        }
        return snapshot
    }

    #if os(iOS)
    struct Destination: Codable, Equatable, Sendable {
        let bookmark: Data
        let name: String
        let owner: UUID

        init(selecting url: URL, owner: UUID) throws {
            guard url.startAccessingSecurityScopedResource() else { throw BackupStore.Issue.folderAccess }
            defer { url.stopAccessingSecurityScopedResource() }
            let chosen = url.resolvingSymlinksInPath().path
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
            guard chosen != home && !chosen.hasPrefix(home + "/") else { throw BackupStore.Issue.folderAccess }
            bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            name = url.lastPathComponent
            self.owner = owner
        }

        func capture(_ payload: BackupPayload) throws -> BackupSnapshot {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            guard !stale, folder.startAccessingSecurityScopedResource() else { throw BackupStore.Issue.folderAccess }
            defer { folder.stopAccessingSecurityScopedResource() }
            var coordinationError: NSError?
            var result: Result<BackupSnapshot, Error>?
            NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { coordinated in
                result = Result { try ExternalFolderBackup.capture(in: coordinated, owner: owner, payload: payload) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw BackupStore.Issue.folderAccess }
            return try result.get()
        }
    }
    #endif
}
