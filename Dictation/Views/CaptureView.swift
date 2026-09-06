import SwiftUI
import UIKit

/// Dictate into the app itself.
///
/// Useful in its own right for quick notes, and useful for debugging: it exercises
/// the same engine as the keyboard without the extension sandbox in the way.
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var capture = CaptureModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.isReady {
                    ReadinessBanner()
                }

                TextEditor(text: $capture.text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .topLeading) {
                        if capture.text.isEmpty {
                            Text("Tap the microphone and speak.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                if !capture.partial.isEmpty {
                    Text(capture.partial)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }

                if let message = capture.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }

                MicButton(
                    isListening: capture.isListening,
                    isTranscribing: capture.state == .transcribing,
                    level: capture.level,
                    action: capture.toggle
                )
                .padding(.vertical, 20)
                .disabled(!model.isMicrophoneGranted || !model.isServerConfigured)
            }
            .navigationTitle("Dictate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = capture.text
                        }
                        .disabled(capture.text.isEmpty)

                        Button("Clear", systemImage: "trash", role: .destructive) {
                            capture.clear()
                        }
                        .disabled(capture.text.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onChange(of: capture.state) { _, state in
                if state == .idle { model.refreshHistory() }
            }
            .onAppear(perform: startIfRequested)
            // Also on foreground: the Action Button can fire at an app that is
            // already running, where `onAppear` has long since happened.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification
                )
            ) { _ in startIfRequested() }
        }
    }

    /// Starts listening if the Action Button or a Shortcut asked for it.
    private func startIfRequested() {
        guard QuickCapture.consume(), !capture.isBusy else { return }
        capture.toggle()
    }
}

/// The record button, with the input level as a ring around it.
private struct MicButton: View {
    let isListening: Bool
    let isTranscribing: Bool
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)

                if isListening {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 3)
                        .frame(width: 96 + CGFloat(level) * 40, height: 96 + CGFloat(level) * 40)
                        .animation(.easeOut(duration: 0.08), value: level)
                }

                if isTranscribing {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(isListening ? Color.red : Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop dictating" : "Start dictating")
    }
}

/// Shown until setup is complete, naming the specific thing that is missing rather
/// than a generic "not configured".
private struct ReadinessBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(message).font(.footnote)
                Spacer()
                Button("Fix") { model.hasCompletedOnboarding = false }
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(Color.orange.opacity(0.15))
        }
    }

    private var message: String? {
        if !model.isMicrophoneGranted { return "The microphone isn't allowed yet." }
        if !model.isServerConfigured { return "No server address set." }
        if !model.isKeyboardInstalled { return "The keyboard isn't added in Settings yet." }
        return nil
    }
}
