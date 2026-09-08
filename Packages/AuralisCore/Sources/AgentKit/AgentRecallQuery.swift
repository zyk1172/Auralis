// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Shared lexical recall for durable memories and reusable skills. Chinese
/// requests do not have word spaces; use adjacent Han pairs alongside whole
/// Latin words, without forming pairs across punctuation. This ranks evidence
/// for the model and never infers commands or changes execution permissions.
struct AgentRecallQuery {
    private let normalized: String
    private let terms: Set<String>

    init(_ query: String) {
        normalized = Self.normalize(query)
        terms = Self.tokenize(normalized)
    }

    func score(_ text: String) -> Int {
        let candidate = Self.normalize(text)
        if normalized.unicodeScalars.count == 1,
           let scalar = normalized.unicodeScalars.first, Self.isHan(scalar) {
            return candidate.contains(normalized) ? 4 : 0
        }
        guard !terms.isEmpty else { return 0 }
        let overlap = terms.intersection(Self.tokenize(candidate)).count
        let phrase = overlap > 0 && normalized.count >= 2 && candidate.contains(normalized) ? 20 : 0
        return overlap * 4 + phrase
    }

    func score(_ memory: AgentMemoryEntry) -> Int {
        score(memory.key) * 2 + score(memory.value)
    }

    func score(_ skill: AgentSkillEntry) -> Int {
        score(skill.name) * 2 + score(skill.instructions)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0x20000...0x323AF).contains(scalar.value)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "帮我", "給我", "给我", "我想", "一下", "一些", "什么", "什麼", "怎么", "如何",
            "please", "the", "and", "for", "with", "that", "this", "about",
        ]
        var result = Set<String>()
        var word = ""
        var previousHan: Unicode.Scalar?
        func flushWord() {
            if !word.isEmpty { result.insert(word) }
            word = ""
        }
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                flushWord()
                if let previousHan { result.insert(String(previousHan) + String(scalar)) }
                previousHan = scalar
            } else {
                previousHan = nil
                if CharacterSet.alphanumerics.contains(scalar) {
                    word.unicodeScalars.append(scalar)
                } else {
                    flushWord()
                }
            }
        }
        flushWord()
        return result.subtracting(stopWords)
    }
}
