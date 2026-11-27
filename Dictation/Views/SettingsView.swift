import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $model.settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Access token", text: $model.token)
                        .onSubmit { model.saveToken() }
                } header: {
                    Text("Server")
                } footer: {
                    Text("""
                        Audio goes to a proxy you run, which holds the provider API \
                        keys. Shipping those keys in the app would put them one \
                        binary inspection away from anyone. https is required.
                        """)
                }

                Section {
                    Picker("Cleanup", selection: $model.settings.cleanupStyle) {
                        ForEach(CleanupStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Text(model.settings.cleanupStyle.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Stream while speaking", isOn: $model.settings.streamingEnabled)
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("""
                        Streaming starts uploading on the first word instead of \
                        waiting until you stop, which is most of the difference \
                        between fast and sluggish. Turn it off to fall back to a \
                        single upload if your server doesn't support it.
                        """)
                }

                Section {
                    Picker("Microphone key", selection: $model.settings.micBehaviour) {
                        ForEach(MicBehaviour.allCases, id: \.self) { behaviour in
                            Text(behaviour.title).tag(behaviour)
                        }
                    }
                    Toggle("Space after dictation", isOn: $model.settings.insertTrailingSpace)
                    Toggle("Auto-capitalise", isOn: $model.settings.autoCapitalise)
                    Toggle("Key clicks", isOn: $model.settings.keyClicks)
                    Toggle("Haptics", isOn: $model.settings.haptics)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Haptic feedback needs Full Access. Sliding off the microphone key before letting go cancels a dictation.")
                }

                Section {
                    Toggle("Keep history", isOn: $model.settings.keepHistory)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("History is stored only on this device, in the container shared with the keyboard. Audio is never written to disk.")
                }

                AutoBackupSection()

                Section("Setup") {
                    LabeledContent("Microphone") {
                        StatusText(isGood: model.isMicrophoneGranted, good: "Allowed", bad: "Not allowed")
                    }
                    LabeledContent("Keyboard added") {
                        StatusText(isGood: model.isKeyboardInstalled, good: "Yes", bad: "No")
                    }
                    LabeledContent("App Group") {
                        StatusText(isGood: AppGroup.isConfigured, good: "Working", bad: "Misconfigured")
                    }
                    Button("Open iOS Settings") { model.openSettings() }
                    Button("Show setup again") { model.hasCompletedOnboarding = false }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text("Full Access can't be checked from here — only the keyboard itself can see it. If dictation fails in the keyboard but works in this app, that's the first thing to check.")
                }
            }
            .navigationTitle("Settings")
            .onDisappear { model.saveToken() }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

private struct StatusText: View {
    let isGood: Bool
    let good: String
    let bad: String

    var body: some View {
        Text(isGood ? good : bad)
            .foregroundStyle(isGood ? .green : .orange)
    }
}


private struct AutoBackupSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingRestore: BackupSnapshot?
    @State private var askingToRestore = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var exportFilename = "Dictation-settings-backup"
    @State private var exporting = false
    @State private var importing = false
    @State private var status: String?

    var body: some View {
        Section {
            Toggle("Auto Backup", isOn: Binding(
                get: { model.backupState.enabled },
                set: { model.setBackupEnabled($0) }
            ))
            ForEach(model.backupState.copies) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Button("Restore") { confirmRestore(snapshot) }
                        Spacer()
                        Button("Export to Files") { export(snapshot) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Import from Files") { importing = true }
            if let message = status ?? model.backupMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup and recovery")
        } footer: {
            Text("Keeps the last two different saved copies of keyboard settings and custom vocabulary on this device. It never copies recordings, transcripts, history settings, or server details. Export to Files to keep a separate copy if you remove the app or move to a new phone.")
        }
        .confirmationDialog("Replace current settings and vocabulary?", isPresented: $askingToRestore, titleVisibility: .visible) {
            Button("Restore backup", role: .destructive) {
                if let pendingRestore { model.restoreBackup(pendingRestore) }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Only the settings covered by Auto Backup and your custom vocabulary will be replaced. Dictation history and server details will not change.")
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { result in
            switch result {
            case .success: status = "Backup exported."
            case .failure: status = "Couldn't export the backup."
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try BackupStore.readBounded(url)
                confirmRestore(try BackupStore.decode(data))
            } catch {
                status = "Couldn't read a valid Dictation settings backup."
            }
        }
    }

    private func confirmRestore(_ snapshot: BackupSnapshot) {
        status = nil
        pendingRestore = snapshot
        askingToRestore = true
    }

    private func export(_ snapshot: BackupSnapshot) {
        do {
            exportDocument = SettingsBackupDocument(data: try BackupStore.export(snapshot))
            exportFilename = "Dictation-settings-\(Int(snapshot.savedAt.timeIntervalSince1970))"
            exporting = true
        } catch {
            status = "Couldn't prepare this backup for export."
        }
    }
}

private struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupStore.Issue.invalid }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
