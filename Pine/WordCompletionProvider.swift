//
//  WordCompletionProvider.swift
//  Pine
//
//  Word-based auto-completion provider that collects words from open editor tabs.
//

import Foundation

/// Provides word-based auto-completions by scanning text content from open editor tabs.
/// Words are extracted using a Unicode-aware regex that matches identifiers (letters, digits, underscores)
/// with a minimum length of 3 characters. Results are cached per-tab and invalidated by `contentVersion`.
enum WordCompletionProvider {

    /// Minimum word length to include in completions.
    static let minWordLength = 3

    /// Maximum number of completions returned by `completions(for:in:)`.
    static let maxCompletions = 50

    /// Unicode-aware regex: matches identifiers starting with a letter or underscore,
    /// followed by letters, digits, or underscores. Supports Cyrillic, CJK, umlauts, etc.
    private static let wordPattern = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: "[\\p{L}_][\\p{L}\\p{N}_]*",
        options: []
    )

    // MARK: - Per-tab word cache

    /// Cached word extraction result for a single tab.
    private struct TabWordCache {
        let tabID: UUID
        let contentVersion: UInt64
        let words: [String: Int]  // word → frequency
    }

    /// Serial queue protecting the cache dictionary.
    private static let cacheQueue = DispatchQueue(label: "com.pine.word-completion-cache")

    /// Cache keyed by tab ID. Values store contentVersion for invalidation.
    private static var tabCaches: [UUID: TabWordCache] = [:]

    /// Extracts words from a single tab's content, returning word→frequency map.
    /// Uses cache when contentVersion matches; rescans only on change.
    private static func wordsForTab(_ tab: EditorTab) -> [String: Int] {
        // Check cache (lock-free read is fine — worst case we rescan once)
        let cached: TabWordCache? = cacheQueue.sync { tabCaches[tab.id] }
        if let cached, cached.contentVersion == tab.contentVersion {
            return cached.words
        }

        // Scan the tab content
        let text = tab.content as NSString
        let range = NSRange(location: 0, length: text.length)
        let matches = wordPattern.matches(in: tab.content, options: [], range: range)

        var frequency: [String: Int] = [:]
        for match in matches {
            let word = text.substring(with: match.range)
            guard word.count >= minWordLength else { continue }
            frequency[word, default: 0] += 1
        }

        // Store in cache
        let entry = TabWordCache(tabID: tab.id, contentVersion: tab.contentVersion, words: frequency)
        cacheQueue.sync { tabCaches[tab.id] = entry }

        return frequency
    }

    /// Removes cached entries for tabs that are no longer open.
    /// Called lazily during `collectWords` to avoid unbounded cache growth.
    private static func pruneCache(activeTabs: Set<UUID>) {
        cacheQueue.sync {
            tabCaches = tabCaches.filter { activeTabs.contains($0.key) }
        }
    }

    /// Extracts unique words (3+ chars) from all open tabs' text content.
    /// Uses per-tab caching — only rescans tabs whose content has changed.
    /// - Parameters:
    ///   - tabs: The currently open editor tabs.
    ///   - currentWord: The word being typed — excluded from results to avoid self-completion.
    /// - Returns: An array of unique words sorted by frequency (descending) then alphabetically.
    static func collectWords(from tabs: [EditorTab], excluding currentWord: String) -> [String] {
        let textTabs = tabs.filter { $0.kind == .text }
        let activeIDs = Set(textTabs.map(\.id))
        pruneCache(activeTabs: activeIDs)

        var frequency: [String: Int] = [:]
        let excludeLower = currentWord.lowercased()

        for tab in textTabs {
            let tabWords = wordsForTab(tab)
            for (word, count) in tabWords {
                guard word.lowercased() != excludeLower else { continue }
                frequency[word, default: 0] += count
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

    /// Filters words by case-insensitive prefix match, limited to `maxCompletions`.
    /// - Parameters:
    ///   - prefix: The partial word to match against.
    ///   - words: The pool of candidate words (already sorted by frequency).
    /// - Returns: Words matching the prefix, preserving the input sort order, capped at `maxCompletions`.
    static func completions(for prefix: String, in words: [String]) -> [String] {
        let prefixLower = prefix.lowercased()
        var result: [String] = []
        for word in words where word.lowercased().hasPrefix(prefixLower) {
            result.append(word)
            if result.count >= maxCompletions { break }
        }
        return result
    }

    // MARK: - Testing support

    /// Clears the internal word cache. Intended for testing only.
    static func clearCache() {
        cacheQueue.sync { tabCaches.removeAll() }
    }
}
