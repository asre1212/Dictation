import Foundation

/// Words the transcriber gets wrong unless told about them: names, jargon, product
/// names, acronyms. Sent with every request as a hint to both the ASR and the
/// cleanup pass.
public struct VocabularyTerm: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The spelling you want out.
    public var term: String
    /// Optionally, what it tends to be misheard as. Empty is fine — the term alone
    /// still biases the model.
    public var soundsLike: String

    public init(id: UUID = UUID(), term: String, soundsLike: String = "") {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
    }
}

/// Reads and writes the custom vocabulary in the shared App Group container.
///
/// Capped because the whole list is sent on every request; an unbounded list would
/// quietly grow the prompt and the latency with it.
public enum VocabularyStore {
    public static let maximumTerms = 200
    private static let key = "vocabulary.v1"

    public static func load() -> [VocabularyTerm] {
        guard let data = AppGroup.defaults.data(forKey: key),
              let terms = try? JSONDecoder().decode([VocabularyTerm].self, from: data)
        else { return [] }
        return terms
    }

    public static func save(_ terms: [VocabularyTerm]) {
        let trimmed = Array(terms.prefix(maximumTerms))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }

    /// The form sent to the server: just the spellings, deduplicated.
    public static func hints() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in load() {
            let value = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            result.append(value)
        }
        return result
    }
}
