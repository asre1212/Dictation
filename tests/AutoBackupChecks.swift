import Foundation

@main
struct AutoBackupChecks {
    static func main() throws {
        let terms = [VocabularyTerm(term: "z-line", soundsLike: "zee line")]
        var settings = AppSettings.default
        settings.serverURL = "https://should-not-export.example"
        settings.keepHistory = false
        func payload(_ settings: AppSettings) -> BackupPayload {
            BackupPayload(preferences: BackupPreferences(settings), vocabulary: terms)
        }
        var state = BackupStore.State()
        let a = payload(settings)
        try state.capture(a)
        precondition(state.copies.isEmpty, "Opt-in required")
        state.enabled = true
        try state.capture(a)
        try state.capture(a)
        precondition(state.copies.count == 1, "Unmodified saves must not rotate")
        settings.serverURL = "https://also-private.example"
        settings.keepHistory = true
        try state.capture(payload(settings))
        precondition(state.copies.count == 1, "Excluded preferences must not trigger a backup")
        settings.keyClicks = false
        let b = payload(settings)
        try state.capture(b)
        settings.haptics = false
        let c = payload(settings)
        try state.capture(c)
        precondition(state.copies.map(\.payload) == [c, b], "Only two most recent saves should remain")
        let snapshot = state.copies[0]
        let exported = try BackupStore.export(snapshot)
        let json = String(decoding: exported, as: UTF8.self)
        for excluded in ["serverURL", "keepHistory", "should-not-export", "also-private", "token", "history", "transcript", "audio"] {
            precondition(!json.contains(excluded), "Excluded field appeared in export: \(excluded)")
        }
        let decoded = try BackupStore.decode(exported)
        precondition(decoded == snapshot, "Export/import must round trip")
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
        print("Auto Backup passed opt-in, retention, privacy and import checks.")
    }
}
