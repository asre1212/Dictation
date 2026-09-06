import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "clock",
                        description: Text("Dictations show up here, on this device only.")
                    )
                } else {
                    List {
                        ForEach(model.history) { record in
                            HistoryRow(record: record)
                        }
                        .onDelete { model.deleteHistory(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { showingClearConfirmation = true }
                    }
                }
            }
            .confirmationDialog(
                "Delete all history?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { model.clearHistory() }
            }
            .refreshable { await MainActor.run { model.refreshHistory() } }
        }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)

            HStack(spacing: 8) {
                Image(systemName: record.source == .keyboard ? "keyboard" : "mic")
                Text(record.date, format: .relative(presentation: .named))
                Text("·")
                Text("\(record.durationSeconds, format: .number.precision(.fractionLength(1)))s spoken")
                Text("·")
                // The number Phase 4 exists to move: end of speech to inserted text.
                Text("\(Int(record.latencySeconds * 1000))ms")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = record.text
            }
            if let raw = record.rawText, raw != record.text {
                Button("Copy before cleanup", systemImage: "doc.on.doc.fill") {
                    UIPasteboard.general.string = raw
                }
            }
        }
    }
}
