import Foundation

struct TranscriptLine: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
}

struct TranscriptTimeline {
    private(set) var lines: [TranscriptLine] = []

    mutating func update(session: UUID, offset: Double, start: Double, end: Double, text: String, isFinal: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, start.isFinite, end.isFinite, end > start else { return }
        let absoluteStart = offset + start
        let absoluteEnd = offset + end
        let id = "\(session.uuidString):\(start)"
        // A recognizer can revise both text and segmentation. Replace overlapping
        // hypotheses instead of appending partial results as duplicate speech.
        lines.removeAll {
            $0.id == id || ($0.id.hasPrefix(session.uuidString) && !$0.isFinal &&
                $0.start < absoluteEnd && $0.end > absoluteStart)
        }
        lines.append(TranscriptLine(id: id, start: absoluteStart, end: absoluteEnd, text: clean, isFinal: isFinal))
        lines.sort { $0.start < $1.start }
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var end: Double { lines.last?.end ?? 0 }
}

// Apple accepts a small list of phrases that should receive extra recognition
// weight. Prefer names, acronyms and product terms over ordinary brief words,
// and keep the order deterministic so the same call setup behaves the same way.
func speechContextTerms(projectName: String, callBrief: String, limit: Int = 60) -> [String] {
    guard limit > 0 else { return [] }

    let ignored = Set([
        "about", "and", "are", "call", "discuss", "for", "from", "how", "into",
        "our", "that", "the", "this", "understand", "want", "what", "when", "where",
        "which", "who", "why", "with", "you", "your"
    ])
    let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasProject = !project.isEmpty && project.caseInsensitiveCompare("General call") != .orderedSame

    func rawTerms(in text: String) -> [String] {
        let separators = Set<Character>(",.;:!?()[]{}\"“”")
        return text.split { $0.isWhitespace || separators.contains($0) }
            .map(String.init)
            .filter { term in
                let alphanumericCount = term.filter { $0.isLetter || $0.isNumber }.count
                let hasCodePunctuation = term.contains { "-+/#".contains($0) }
                let letters = term.filter(\.isLetter)
                let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
                return !ignored.contains(term.lowercased()) &&
                    (alphanumericCount >= 3 || term.contains(where: \.isNumber) || hasCodePunctuation || isAcronym)
            }
    }

    func isDistinctive(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return word.contains(where: \.isNumber)
            || (letters.count >= 2 && letters.allSatisfy(\.isUppercase))
            || word.first?.isUppercase == true
    }

    func codePhrases(in terms: [String]) -> [String] {
        guard terms.count > 1 else { return [] }
        return terms.indices.dropLast().compactMap { index in
            let first = terms[index]
            let second = terms[index + 1]
            let letters = first.filter(\.isLetter)
            let firstIsAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            let secondIsNumber = !second.isEmpty && second.allSatisfy(\.isNumber)
            return firstIsAcronym && secondIsNumber ? "\(first) \(second)" : nil
        }
    }

    let projectWords = hasProject ? rawTerms(in: project) : []
    let briefWords = rawTerms(in: callBrief)
    var candidates = hasProject ? [project] : []
    candidates += projectWords
    candidates += codePhrases(in: briefWords)
    candidates += briefWords.filter(isDistinctive)
    candidates += briefWords

    var seen = Set<String>()
    var result: [String] = []
    for candidate in candidates {
        let key = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX")).lowercased()
        if seen.insert(key).inserted {
            result.append(candidate)
            if result.count == limit { break }
        }
    }
    return result
}

struct Suggestion: Decodable, Identifiable {
    var id = UUID()
    var receivedAt = Date()
    let should_answer: Bool
    let question: String
    let answer: String
    let caveat: String
    let follow_up: String
    let source: String

    enum CodingKeys: String, CodingKey { case should_answer, question, answer, caveat, follow_up, source }

    var copyText: String {
        [answer, caveat.isEmpty ? "" : "Keep in mind: \(caveat)",
         follow_up.isEmpty ? "" : "Ask next: \(follow_up)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct CompanionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func conversationExcerpt(_ text: String, limit: Int = 14000) -> String {
    guard text.count > limit else { return text }
    // Preserve the beginning for introductions plus the most recent discussion.
    return String(text.prefix(2000)) + "\n[Earlier conversation omitted]\n" + String(text.suffix(limit - 2100))
}
