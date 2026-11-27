import Foundation

@main
struct AutoBackupChecks {
    static func main() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("dictation-check-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let owner = UUID()
        let otherFile = folder.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: otherFile)
        let terms = [VocabularyTerm(term: "z-line", soundsLike: "zee line")]
        var settings = AppSettings.default
        settings.serverURL = "https://should-not-export.example"
        settings.keepHistory = false
        func payload(_ settings: AppSettings) -> BackupPayload {
            BackupPayload(preferences: BackupPreferences(settings), vocabulary: terms)
        }
        func capture(_ value: BackupPayload) throws -> BackupSnapshot {
            try ExternalFolderBackup.capture(in: folder, owner: owner, payload: value)
        }
        let a = try capture(payload(settings))
        settings.serverURL = "https://also-private.example"
        settings.keepHistory = true
        let unchanged = try capture(payload(settings))
        precondition(unchanged == a, "Excluded preferences must not trigger rotation")
        settings.keyClicks = false
        let b = try capture(payload(settings))
        settings.haptics = false
        let c = try capture(payload(settings))
        let owned = folder.appendingPathComponent("Dictation Auto Backup " + owner.uuidString)
        let files = try fm.contentsOfDirectory(at: owned, includingPropertiesForKeys: nil)
        precondition(files.count == 2, "Only two Files copies should remain")
        let snapshots = try files.map { try BackupStore.decode(BackupStore.readBounded($0), requiredOwner: owner) }
        precondition(Set(snapshots.map(\.id)) == Set([b.id, c.id]), "Latest two distinct saves should remain")
        let unrelatedBytes = try Data(contentsOf: otherFile)
        precondition(unrelatedBytes == Data("keep me".utf8))
        let exported = try BackupStore.export(c)
        let json = String(decoding: exported, as: UTF8.self)
        for excluded in ["serverURL", "keepHistory", "should-not-export", "also-private", "token", "history", "transcript", "audio"] {
            precondition(!json.contains(excluded), "Excluded field appeared in export: \(excluded)")
        }
        let decoded = try BackupStore.decode(exported)
        precondition(decoded == c, "Export/import must round trip")
        var current = AppSettings.default
        current.serverURL = "https://safe.example"
        current.keepHistory = false
        let restored = decoded.payload.preferences.applying(to: current)
        precondition(!restored.keepHistory && restored.serverURL == current.serverURL, "Restore must preserve privacy and endpoint settings")
        precondition(!restored.haptics && !restored.keyClicks)
        precondition(decoded.payload.vocabulary == terms)
        for invalid in [Data("{}".utf8), Data(repeating: 0, count: BackupStore.maxFileSize + 1)] {
            do {
                _ = try BackupStore.decode(invalid)
                preconditionFailure("Invalid backup imported")
            } catch {}
        }
        // An unknown file occupying a slot is preserved; rotation fails closed.
        let occupied = files[0]
        let unrelated = Data("not a backup".utf8)
        try unrelated.write(to: occupied, options: .atomic)
        do {
            _ = try capture(a.payload)
            preconditionFailure("An occupied slot was overwritten")
        } catch {}
        let bytesAfterRejectedWrite = try Data(contentsOf: occupied)
        precondition(bytesAfterRejectedWrite == unrelated)
        print("Auto Backup passed Files rotation, privacy, collision safety, and import checks.")
    }
}
