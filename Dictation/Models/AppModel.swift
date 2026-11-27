import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Everything the container app's screens read and write.
///
/// Deliberately one object: settings, permissions and history are all shared state
/// that the keyboard extension also touches, and keeping the reads in one place
/// makes it obvious where the refresh-on-foreground has to happen.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            if BackupPreferences(oldValue) != BackupPreferences(settings) { captureBackupIfEnabled() }
        }
    }

    @Published private(set) var vocabulary: [VocabularyTerm]
    @Published private(set) var history: [DictationRecord] = []
    @Published private(set) var microphonePermission: AVAudioApplication.recordPermission
    @Published var token: String
    @Published private(set) var legacyBackups: [BackupSnapshot] = []
    @Published private(set) var backupDestination: ExternalFolderBackup.Destination?
    @Published private(set) var backupMessage: String?
    private var backupTask: Task<Void, Never>?
    private static let backupDestinationKey = "external-backup-destination-v1"
    private static let backupOwnerKey = "external-backup-owner-v1"
    private var restoringBackup = false

    /// Set once the user has been through onboarding. Backed by the App Group
    /// rather than `@AppStorage`, which only republishes from inside a `View` —
    /// here it would write the value and never tell anyone it had changed.
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppGroup.defaults.set(hasCompletedOnboarding, forKey: Self.onboardingKey)
        }
    }

    private static let onboardingKey = "onboarding.completed.v1"

    init() {
        settings = SettingsStore.load()
        vocabulary = VocabularyStore.load()
        microphonePermission = AVAudioApplication.shared.recordPermission
        token = KeychainStore.loadToken() ?? ""
        hasCompletedOnboarding = AppGroup.defaults.bool(forKey: Self.onboardingKey)
        refreshHistory()
        do {
            let store = try BackupStore.applicationStore()
            legacyBackups = try store.load().copies
        } catch {
            backupMessage = "Couldn't read older copies. Existing files weren't replaced."
        }
        if let saved = UserDefaults.standard.data(forKey: Self.backupDestinationKey) {
            backupDestination = try? JSONDecoder().decode(ExternalFolderBackup.Destination.self, from: saved)
            if backupDestination == nil { backupMessage = "Select your backup folder again." }
        }
    }

    // MARK: - Auto Backup

    private var backupPayload: BackupPayload {
        BackupPayload(preferences: BackupPreferences(settings), vocabulary: vocabulary)
    }

    func selectBackupFolder(_ url: URL) {
        do {
            let defaults = UserDefaults.standard
            let owner = defaults.string(forKey: Self.backupOwnerKey).flatMap { UUID(uuidString: $0) } ?? UUID()
            let chosen = try ExternalFolderBackup.Destination(selecting: url, owner: owner)
            defaults.set(try JSONEncoder().encode(chosen), forKey: Self.backupDestinationKey)
            defaults.set(owner.uuidString, forKey: Self.backupOwnerKey)
            backupDestination = chosen
            backupMessage = "Checking the selected Files folder…"
            captureBackupIfEnabled()
        } catch {
            backupMessage = "Could not use this Files folder. Choose a different location outside Dictation."
        }
    }

    func disconnectBackupFolder() {
        UserDefaults.standard.removeObject(forKey: Self.backupDestinationKey)
        backupDestination = nil
        backupMessage = "Automatic backups are off. Existing Files copies were kept."
    }

    func currentBackup() -> BackupSnapshot {
        BackupSnapshot(id: UUID(), savedAt: Date(), payload: backupPayload)
    }

    func restoreBackup(_ snapshot: BackupSnapshot) {
        do {
            try snapshot.payload.validate()
            restoringBackup = true
            settings = snapshot.payload.preferences.applying(to: settings)
            vocabulary = snapshot.payload.vocabulary
            VocabularyStore.save(vocabulary)
            restoringBackup = false
            backupMessage = "Settings and vocabulary restored."
            captureBackupIfEnabled()
        } catch {
            backupMessage = "Couldn't restore this backup. Current preferences weren't changed."
        }
    }

    private func captureBackupIfEnabled() {
        guard let destination = backupDestination, !restoringBackup else { return }
        let payload = backupPayload
        let previous = backupTask
        backupTask = Task { [weak self] in
            await previous?.value
            guard let self, backupDestination == destination else { return }
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try destination.capture(payload)
                }.value
                if backupDestination == destination {
                    backupMessage = "Files backup verified: " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
                }
            } catch {
                if backupDestination == destination {
                    backupMessage = "Files backup could not be saved. Check folder access or select it again. No in-app fallback copy was made."
                }
            }
        }
    }

    // MARK: - Readiness

    /// The three things that must be true before the keyboard can dictate. The
    /// keyboard cannot fix any of them itself, which is the whole reason the
    /// container app exists.
    var isMicrophoneGranted: Bool { microphonePermission == .granted }
    var isServerConfigured: Bool { settings.isConfigured }

    /// Whether the keyboard has ever been added in Settings. There is no API to ask
    /// directly, so this checks the active input modes — which only lists keyboards
    /// the user has installed.
    var isKeyboardInstalled: Bool {
        UITextInputMode.activeInputModes.contains { mode in
            mode.value(forKey: "identifier") as? String == Self.keyboardIdentifier
        }
    }

    private static let keyboardIdentifier = "com.asre1212.dictation.keyboard"

    var isReady: Bool {
        isMicrophoneGranted && isServerConfigured && isKeyboardInstalled
    }

    // MARK: - Permissions

    /// Prompts for the microphone. This can only happen here — a keyboard extension
    /// can read the permission but never ask for it, so if this is skipped the
    /// keyboard's microphone key simply never works.
    func requestMicrophonePermission() async {
        guard microphonePermission == .undetermined else { return }
        _ = await AVAudioApplication.requestRecordPermission()
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    func refreshPermissions() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    /// Deep-links into this app's page in Settings. Permitted from the container
    /// app; the keyboard extension itself must not launch anything.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Token

    func saveToken() {
        KeychainStore.saveToken(token)
    }

    // MARK: - Vocabulary

    func addTerm(_ term: String, soundsLike: String = "") {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              vocabulary.count < VocabularyStore.maximumTerms,
              !vocabulary.contains(where: { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }

        vocabulary.append(VocabularyTerm(term: trimmed, soundsLike: soundsLike))
        VocabularyStore.save(vocabulary)
        captureBackupIfEnabled()
    }

    func deleteTerms(at offsets: IndexSet) {
        vocabulary.remove(atOffsets: offsets)
        VocabularyStore.save(vocabulary)
        captureBackupIfEnabled()
    }

    // MARK: - History

    func refreshHistory() {
        history = HistoryStore.shared.load()
    }

    func deleteHistory(at offsets: IndexSet) {
        let ids = Set(offsets.map { history[$0].id })
        history.remove(atOffsets: offsets)
        HistoryStore.shared.delete(ids: ids)
    }

    func clearHistory() {
        history = []
        HistoryStore.shared.clear()
    }
}
