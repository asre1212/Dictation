import AVFoundation
import SwiftUI
import VisionKit

struct DesktopView: View {
    @ObservedObject var desktop: DesktopSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("LOCAL MEDICAL DICTATION", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    Text("Your iPhone is the microphone.")
                        .font(.largeTitle.bold())
                    Text("Whisper runs on your Mac or Windows computer. Audio goes directly to the paired computer over an encrypted connection.")
                        .foregroundStyle(.secondary)
                    if !desktop.connected {
                        Button {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                                scanning = true
                            }
                        } label: {
                            Label("Scan pairing QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(desktop.busy)
                        DisclosureGroup("Enter pairing link manually") {
                            SecureField("dictation://desktop?…", text: $desktop.pairingLink)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).padding(.vertical, 10)
                            Button("Connect to computer") { desktop.pair(desktop.pairingLink) }
                                .disabled(desktop.pairingLink.isEmpty || desktop.busy)
                        }
                        Text("Open Dictation Desktop → download/load a model → Start pairing. Use shared Wi-Fi or a reachable private VPN. No Bluetooth is required.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Label(desktop.status, systemImage: desktop.connected ? "desktopcomputer" : "info.circle")
                        .font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    if desktop.busy { ProgressView().frame(maxWidth: .infinity) }
                    if desktop.connected {
                        Button(action: desktop.toggleRecording) {
                            VStack(spacing: 12) {
                                Image(systemName: desktop.recording ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.system(size: 86)).foregroundStyle(desktop.recording ? .red : .teal)
                                Text(desktop.recording ? "Stop & transcribe" : "Start dictation").font(.headline)
                            }.frame(maxWidth: .infinity).padding(.vertical, 18)
                        }.buttonStyle(.plain).disabled(desktop.busy || desktop.canRetry)
                        if desktop.recording { ProgressView(value: Double(desktop.level)).tint(.red) }
                        if desktop.canRetry {
                            HStack {
                                Button("Retry transfer", action: desktop.sendPending).buttonStyle(.borderedProminent)
                                Button("Discard recording", role: .destructive, action: desktop.discardRecording)
                            }
                        }
                        if !desktop.transcript.isEmpty {
                            Text("LAST TRANSCRIPT · REVIEW ON DESKTOP").font(.caption).foregroundStyle(.secondary)
                            Text(desktop.transcript).textSelection(.enabled)
                        }
                        Button("Disconnect & clear", role: .destructive) { confirmDisconnect = true }
                    }
                    Text("Keep this screen open. Leaving the app clears the iPhone session and requires fresh pairing. The desktop draft remains until cleared there or its session expires. Review medical terms, doses and negation before charting. Use synthetic examples until your institution approves the workflow.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.navigationTitle("Desktop").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $scanning) {
                    NavigationStack {
                        Group {
                            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                PairingScanner { link in scanning = false; desktop.pair(link) }
                            } else {
                                ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text("Allow camera access in Settings or use the manual pairing link."))
                            }
                        }.navigationTitle("Scan computer code")
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                    }
                }
                .confirmationDialog("End the iPhone session and clear its recording and transcript?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect & clear", role: .destructive, action: desktop.disconnect)
                }
                .onChange(of: scenePhase) { _, phase in if phase == .background { desktop.disconnect() } }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in desktop.interrupted() }
                .onDisappear { desktop.disconnect() }
        }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        var found = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !found else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, value.hasPrefix("dictation://desktop?") {
                    found = true; dataScanner.stopScanning(); onFound(value); return
                }
            }
        }
    }
}
