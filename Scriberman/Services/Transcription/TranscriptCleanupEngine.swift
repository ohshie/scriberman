import Foundation

/// Applies user-configured `TranscriptCleanupRule`s to live segment text
/// (design D2–D3). Pure and stateless so rule semantics are unit-testable
/// without the service actor, matching the `LiveSegmentSanitizer` precedent.
enum TranscriptCleanupEngine {
    /// Applies `rules` in order, each operating on the previous rule's
    /// output. Returns the cleaned text, or nil when no letters or digits
    /// remain and the segment must be dropped. An empty (or all-empty-pattern)
    /// rule list returns the input unchanged.
    static func apply(_ rules: [TranscriptCleanupRule], to text: String) -> String? {
        let effectiveRules = rules.filter {
            !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !effectiveRules.isEmpty else { return text }

        var current = text
        for rule in effectiveRules {
            current = applyRule(rule, to: current)
        }

        guard current.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return current
    }

    private static func applyRule(_ rule: TranscriptCleanupRule, to text: String) -> String {
        if rule.wholeWord {
            return removeWholeWordMatches(of: rule, in: text)
        }
        return removeSubstringMatches(of: rule, in: text)
    }

    // MARK: - Whole-word matching

    /// A whitespace-delimited token decomposed into leading punctuation,
    /// alphanumeric-bounded core, and trailing punctuation. Interior
    /// punctuation (apostrophes, hyphens) stays part of the core.
    private struct Token {
        let core: String
        let trailing: String
        let original: String

        init(_ raw: Substring) {
            original = String(raw)
            let coreStart = raw.firstIndex { $0.isLetter || $0.isNumber }
            guard let coreStart else {
                core = ""
                trailing = ""
                return
            }
            let coreEnd = raw.lastIndex { $0.isLetter || $0.isNumber }!
            core = String(raw[coreStart...coreEnd])
            trailing = String(raw[raw.index(after: coreEnd)...])
        }
    }

    private static func removeWholeWordMatches(of rule: TranscriptCleanupRule, in text: String) -> String {
        let patternWords = rule.pattern.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !patternWords.isEmpty else { return text }

        let tokens = text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(Token.init)
        guard !tokens.isEmpty else { return text }

        func matches(at index: Int) -> Bool {
            guard index + patternWords.count <= tokens.count else { return false }
            for (offset, word) in patternWords.enumerated() {
                let core = tokens[index + offset].core
                guard !core.isEmpty, core.lowercased() == word else { return false }
            }
            return true
        }

        // Indices of matched tokens, plus each match's last token index so
        // removal can hand its trailing punctuation to the preceding kept
        // token ("That's it, huh." → "That's it.", design D3).
        var matchedIndices: Set<Int> = []
        var matchEndIndices: Set<Int> = []

        switch rule.position {
        case .anywhere:
            var index = 0
            while index < tokens.count {
                if matches(at: index) {
                    for offset in 0..<patternWords.count {
                        matchedIndices.insert(index + offset)
                    }
                    matchEndIndices.insert(index + patternWords.count - 1)
                    index += patternWords.count
                } else {
                    index += 1
                }
            }
        case .start:
            // Anchor at the first word, ignoring leading punctuation-only tokens.
            if let first = tokens.firstIndex(where: { !$0.core.isEmpty }), matches(at: first) {
                for offset in 0..<patternWords.count {
                    matchedIndices.insert(first + offset)
                }
                matchEndIndices.insert(first + patternWords.count - 1)
            }
        case .end:
            // Anchor at the last word, ignoring trailing punctuation-only tokens.
            if let last = tokens.lastIndex(where: { !$0.core.isEmpty }) {
                let startIndex = last - patternWords.count + 1
                if startIndex >= 0, matches(at: startIndex) {
                    for offset in 0..<patternWords.count {
                        matchedIndices.insert(startIndex + offset)
                    }
                    matchEndIndices.insert(last)
                }
            }
        }

        guard !matchedIndices.isEmpty else { return text }

        var kept: [String] = []
        for (index, token) in tokens.enumerated() {
            guard matchedIndices.contains(index) else {
                kept.append(token.original)
                continue
            }
            // The removed word's trailing punctuation replaces the previous
            // word's, so "it," + removed "huh." yields "it." rather than
            // an orphaned "it, ." (design D3).
            if matchEndIndices.contains(index), !token.trailing.isEmpty, !kept.isEmpty {
                kept[kept.count - 1] = replacingTrailingPunctuation(of: kept[kept.count - 1], with: token.trailing)
            }
        }
        return kept.joined(separator: " ")
    }

    private static func replacingTrailingPunctuation(of word: String, with trailing: String) -> String {
        guard let lastAlphanumeric = word.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
            return trailing
        }
        return String(word[...lastAlphanumeric]) + trailing
    }

    // MARK: - Substring matching

    private static func removeSubstringMatches(of rule: TranscriptCleanupRule, in text: String) -> String {
        var result = text
        var removedAnything = false

        switch rule.position {
        case .anywhere:
            while let range = result.range(of: rule.pattern, options: .caseInsensitive) {
                result.removeSubrange(range)
                removedAnything = true
            }
        case .start:
            if let range = result.range(of: rule.pattern, options: [.caseInsensitive, .anchored]) {
                result.removeSubrange(range)
                removedAnything = true
            }
        case .end:
            if let range = result.range(of: rule.pattern, options: [.caseInsensitive, .anchored, .backwards]) {
                result.removeSubrange(range)
                removedAnything = true
            }
        }

        guard removedAnything else { return text }
        return collapseWhitespace(result)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
