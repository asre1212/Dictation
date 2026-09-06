import SwiftUI

/// Names, jargon and acronyms the recogniser gets wrong unless told about them.
/// Sent with every request, which is why the list is capped — it is prompt weight
/// on every single dictation.
struct VocabularyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTerm = ""
    @State private var newSoundsLike = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Word or phrase", text: $newTerm)
                        .autocorrectionDisabled()
                    TextField("Usually heard as (optional)", text: $newSoundsLike)
                        .autocorrectionDisabled()
                    Button("Add") {
                        model.addTerm(newTerm, soundsLike: newSoundsLike)
                        newTerm = ""
                        newSoundsLike = ""
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Add a word")
                } footer: {
                    Text("\(model.vocabulary.count) of \(VocabularyStore.maximumTerms). Every word here is sent with every dictation, so keep it to the ones that actually get misheard.")
                }

                if !model.vocabulary.isEmpty {
                    Section("Your words") {
                        ForEach(model.vocabulary) { term in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(term.term)
                                if !term.soundsLike.isEmpty {
                                    Text("heard as “\(term.soundsLike)”")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { model.deleteTerms(at: $0) }
                    }
                }
            }
            .navigationTitle("Words")
        }
    }
}
