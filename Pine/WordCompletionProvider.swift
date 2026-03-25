//
//  WordCompletionProvider.swift
//  Pine
//
//  Word-based auto-completion provider that collects words from open editor tabs.
//

import Foundation

/// Provides word-based auto-completions by scanning text content from open editor tabs.
/// Words are extracted using a regex that matches identifiers (letters, digits, underscores)
/// with a minimum length of 3 characters.
enum WordCompletionProvider {

    /// Minimum word length to include in completions.
    static let minWordLength = 3

    /// Regex pattern for extracting words: sequences of word characters (letters, digits, underscores).
    private static let wordPattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "[a-zA-Z_][a-zA-Z0-9_]*",
        options: []
    )

    /// Extracts unique words (3+ chars) from all open tabs' text content.
    /// - Parameters:
    ///   - tabs: The currently open editor tabs.
    ///   - currentWord: The word being typed — excluded from results to avoid self-completion.
    /// - Returns: An array of unique words sorted by frequency (descending) then alphabetically.
    static func collectWords(from tabs: [EditorTab], excluding currentWord: String) -> [String] {
        var frequency: [String: Int] = [:]
        let excludeLower = currentWord.lowercased()

        for tab in tabs where tab.kind == .text {
            let text = tab.content as NSString
            let range = NSRange(location: 0, length: text.length)
            let matches = wordPattern.matches(in: tab.content, options: [], range: range)

            for match in matches {
                let word = text.substring(with: match.range)
                guard word.count >= minWordLength else { continue }
                guard word.lowercased() != excludeLower else { continue }
                frequency[word, default: 0] += 1
            }
        }

        // Sort by frequency (descending), then alphabetically for stable ordering
        return frequency.keys.sorted { lhs, rhs in
            let freqL = frequency[lhs] ?? 0
            let freqR = frequency[rhs] ?? 0
            if freqL != freqR { return freqL > freqR }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// Filters words by case-insensitive prefix match.
    /// - Parameters:
    ///   - prefix: The partial word to match against.
    ///   - words: The pool of candidate words (already sorted by frequency).
    /// - Returns: Words matching the prefix, preserving the input sort order.
    static func completions(for prefix: String, in words: [String]) -> [String] {
        let prefixLower = prefix.lowercased()
        return words.filter { $0.lowercased().hasPrefix(prefixLower) }
    }
}
