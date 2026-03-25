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
///
/// Threading model: all regex scanning runs on a dedicated serial background queue (`scanQueue`).
/// The `completions(forPartialWordRange:)` call on main thread reads only from the ready cache.
/// If the cache is stale, a background rescan is triggered and current (possibly outdated) results are returned.
enum WordCompletionProvider {

    /// Minimum word length to include in completions.
    /// Set to 3 to filter out noise (operators, single-char vars). Two-letter identifiers like `id`, `ok`
    /// are excluded because they generate too many false positives from partial matches in longer words.
    static let minWordLength = 3

    /// Maximum number of completions returned by `completions(for:in:)`.
    static let maxCompletions = 50

    /// Maximum number of characters to scan per tab. Files beyond this limit are partially scanned
    /// to keep indexing time bounded (avoids blocking on multi-MB files).
    static let maxScanSize = 500_000  // ~500 KB

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

    /// Serial queue protecting the cache dictionary and performing background scans.
    private static let cacheQueue = DispatchQueue(label: "com.pine.word-completion-cache")

    /// Background serial queue for regex scanning — never blocks main thread.
    private static let scanQueue = DispatchQueue(label: "com.pine.word-completion-scan")

    /// Cache keyed by composite key "projectID:tabID". Values store contentVersion for invalidation.
    private static var tabCaches: [String: TabWordCache] = [:]

    /// Last aggregated word list — returned immediately while background rescan runs.
    private static var lastAggregatedWords: [String] = []

    /// Project ID for the last aggregation — ensures we don't mix results across projects.
    private static var lastProjectID: String?

    // MARK: - Cache key helpers

    /// Builds a cache key that includes the project ID to avoid cross-project word mixing.
    private static func cacheKey(projectID: String, tabID: UUID) -> String {
        "\(projectID):\(tabID.uuidString)"
    }

    /// Extracts words from a single tab's content, returning word→frequency map.
    /// Uses cache when contentVersion matches; rescans only on change.
    /// **Must be called from `scanQueue` or `cacheQueue`** — NOT from main thread.
    private static func wordsForTab(_ tab: EditorTab, projectID: String) -> [String: Int] {
        let key = cacheKey(projectID: projectID, tabID: tab.id)

        // Check cache
        let cached: TabWordCache? = cacheQueue.sync { tabCaches[key] }
        if let cached, cached.contentVersion == tab.contentVersion {
            return cached.words
        }

        // Scan the tab content, respecting maxScanSize
        let text = tab.content as NSString
        let scanLength = min(text.length, maxScanSize)
        let range = NSRange(location: 0, length: scanLength)
        let matches = wordPattern.matches(in: tab.content, options: [], range: range)

        var frequency: [String: Int] = [:]
        for match in matches {
            let word = text.substring(with: match.range)
            guard word.count >= minWordLength else { continue }
            frequency[word, default: 0] += 1
        }

        // Store in cache
        let entry = TabWordCache(tabID: tab.id, contentVersion: tab.contentVersion, words: frequency)
        cacheQueue.sync { tabCaches[key] = entry }

        return frequency
    }

    /// Removes cached entries for tabs that are no longer open.
    /// Called lazily during `collectWords` to avoid unbounded cache growth.
    private static func pruneCache(projectID: String, activeTabs: Set<UUID>) {
        let prefix = "\(projectID):"
        cacheQueue.sync {
            tabCaches = tabCaches.filter { key, value in
                guard key.hasPrefix(prefix) else { return true }  // keep other projects' caches
                return activeTabs.contains(value.tabID)
            }
        }
    }

    /// Extracts unique words (3+ chars) from all open tabs' text content.
    /// Uses per-tab caching — only rescans tabs whose content has changed.
    /// - Parameters:
    ///   - tabs: The currently open editor tabs.
    ///   - currentWord: The word being typed — excluded from results to avoid self-completion.
    ///   - projectID: Identifier for the current project (e.g. project directory path).
    ///                Isolates caches between different open projects.
    /// - Returns: An array of unique words sorted by frequency (descending) then alphabetically.
    static func collectWords(
        from tabs: [EditorTab],
        excluding currentWord: String,
        projectID: String = ""
    ) -> [String] {
        let textTabs = tabs.filter { $0.kind == .text }
        let activeIDs = Set(textTabs.map(\.id))
        pruneCache(projectID: projectID, activeTabs: activeIDs)

        var frequency: [String: Int] = [:]
        let excludeLower = currentWord.lowercased()

        for tab in textTabs {
            let tabWords = wordsForTab(tab, projectID: projectID)
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

    // MARK: - Async background indexing (K1)

    /// Snapshot of tab data needed for background scanning — avoids capturing EditorTab from main thread.
    struct TabSnapshot: Sendable {
        let id: UUID
        let content: String
        let contentVersion: UInt64
        let kind: EditorTab.TabKind
    }

    /// Triggers a background rescan of all tabs and returns the best available results immediately.
    /// If the cache is fully up-to-date, returns fresh results. Otherwise returns the last aggregated
    /// word list and schedules a background rescan. The next call will have updated data.
    ///
    /// This method is safe to call from the main thread — regex work happens on `scanQueue`.
    static func completionsFromCache(
        tabSnapshots: [TabSnapshot],
        excluding currentWord: String,
        projectID: String
    ) -> [String] {
        let textTabs = tabSnapshots.filter { $0.kind == .text }

        // Check if all caches are valid (fast path — no scanning needed)
        let allCachesFresh = cacheQueue.sync { () -> Bool in
            for tab in textTabs {
                let key = cacheKey(projectID: projectID, tabID: tab.id)
                guard let cached = tabCaches[key],
                      cached.contentVersion == tab.contentVersion else {
                    return false
                }
            }
            return true
        }

        if allCachesFresh {
            // All caches valid — aggregate directly (reading from cache is fast)
            let result = aggregateFromCache(
                textTabs: textTabs,
                excluding: currentWord,
                projectID: projectID
            )
            cacheQueue.sync {
                lastAggregatedWords = result
                lastProjectID = projectID
            }
            return result
        }

        // Some caches are stale — return last known results + schedule background rescan
        scheduleBackgroundScan(textTabs: textTabs, projectID: projectID)

        return cacheQueue.sync {
            guard lastProjectID == projectID else { return [] }
            // Filter by current prefix from last aggregated results
            return lastAggregatedWords
        }
    }

    /// Aggregates words from cache (assumes all caches are valid).
    private static func aggregateFromCache(
        textTabs: [TabSnapshot],
        excluding currentWord: String,
        projectID: String
    ) -> [String] {
        let excludeLower = currentWord.lowercased()
        var frequency: [String: Int] = [:]

        cacheQueue.sync {
            for tab in textTabs {
                let key = cacheKey(projectID: projectID, tabID: tab.id)
                guard let cached = tabCaches[key] else { continue }
                for (word, count) in cached.words {
                    guard word.lowercased() != excludeLower else { continue }
                    frequency[word, default: 0] += count
                }
            }
        }

        return frequency.keys.sorted { lhs, rhs in
            let freqL = frequency[lhs] ?? 0
            let freqR = frequency[rhs] ?? 0
            if freqL != freqR { return freqL > freqR }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// Schedules a background scan for tabs with stale caches.
    private static func scheduleBackgroundScan(
        textTabs: [TabSnapshot],
        projectID: String
    ) {
        scanQueue.async {
            for tab in textTabs {
                let key = cacheKey(projectID: projectID, tabID: tab.id)
                let isCached = cacheQueue.sync { () -> Bool in
                    guard let cached = tabCaches[key] else { return false }
                    return cached.contentVersion == tab.contentVersion
                }
                guard !isCached else { continue }

                // Scan tab content, respecting maxScanSize
                let text = tab.content as NSString
                let scanLength = min(text.length, maxScanSize)
                let range = NSRange(location: 0, length: scanLength)
                let matches = wordPattern.matches(in: tab.content, options: [], range: range)

                var freq: [String: Int] = [:]
                for match in matches {
                    let word = text.substring(with: match.range)
                    guard word.count >= minWordLength else { continue }
                    freq[word, default: 0] += 1
                }

                let entry = TabWordCache(
                    tabID: tab.id,
                    contentVersion: tab.contentVersion,
                    words: freq
                )
                cacheQueue.sync { tabCaches[key] = entry }
            }
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
        cacheQueue.sync {
            tabCaches.removeAll()
            lastAggregatedWords.removeAll()
            lastProjectID = nil
        }
    }
}
