//
//  QuickOpenProvider.swift
//  Pine
//

import Foundation

// MARK: - Models

struct QuickOpenResult: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let fileName: String
    let relativePath: String
    let score: Int
}

// MARK: - Provider

@Observable
final class QuickOpenProvider {
    static let recentFilesKey = "quickOpen.recentFiles"
    static let maxRecentFiles = 20
    static let maxResults = 50
    static let debounceInterval: Duration = .milliseconds(150)

    private(set) var results: [QuickOpenResult] = []

    var indexedFiles: [(url: URL, relativePath: String)] = []
    private var indexedRootURL: URL?
    private var currentQuery: String = ""
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    // MARK: - Recent files

    var recentURLs: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? []
        return paths.compactMap { URL(fileURLWithPath: $0) }
    }

    func recordOpened(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > Self.maxRecentFiles {
            paths = Array(paths.prefix(Self.maxRecentFiles))
        }
        UserDefaults.standard.set(paths, forKey: Self.recentFilesKey)
    }

    // MARK: - Indexing

    /// Indexes the file tree for `rootURL` unless already indexed for that root.
    /// After indexing completes, re-runs the current search query.
    func startIndexing(rootURL: URL) {
        guard indexedRootURL != rootURL else { return }
        indexTask?.cancel()
        indexTask = Task.detached { [weak self] in
            let ignoredDirs = await ProjectSearchProvider.gitIgnoredDirectories(rootURL: rootURL)
            let resolvedRoot = rootURL.resolvingSymlinksInPath()
            let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
            let files = Self.collectFiles(rootURL: rootURL, ignoredDirs: ignoredDirs, resolvedRootPath: rootPath)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.indexedFiles = files
                self?.indexedRootURL = rootURL
                // Refresh results now that files are indexed
                self?.search(query: self?.currentQuery ?? "")
            }
        }
    }

    func invalidateIndex() {
        indexTask?.cancel()
        indexedRootURL = nil
        indexedFiles = []
    }

    func reset() {
        searchTask?.cancel()
        results = []
        currentQuery = ""
    }

    // MARK: - Search

    func search(query: String) {
        searchTask?.cancel()
        currentQuery = query

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = indexedFiles
        let recent = recentURLs

        if q.isEmpty {
            let recentSet = Set(recent.map(\.path))
            var ordered: [QuickOpenResult] = []

            for url in recent.prefix(Self.maxRecentFiles) {
                if let match = files.first(where: { $0.url == url }) {
                    ordered.append(QuickOpenResult(
                        url: match.url,
                        fileName: match.url.lastPathComponent,
                        relativePath: match.relativePath,
                        score: Int.max
                    ))
                }
            }

            let remaining = files
                .filter { !recentSet.contains($0.url.path) }
                .prefix(Self.maxResults - ordered.count)
                .map {
                    QuickOpenResult(
                        url: $0.url,
                        fileName: $0.url.lastPathComponent,
                        relativePath: $0.relativePath,
                        score: 0
                    )
                }

            results = ordered + remaining
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }

            let recentSet = Set(recent.map(\.path))
            var scored: [(QuickOpenResult, Int)] = []

            for (url, relativePath) in files {
                let fileName = url.lastPathComponent
                guard let score = Self.fuzzyScore(query: q, fileName: fileName, relativePath: relativePath) else {
                    continue
                }
                let boost = recentSet.contains(url.path) ? 200 : 0
                let finalScore = score + boost
                scored.append((
                    QuickOpenResult(url: url, fileName: fileName, relativePath: relativePath, score: finalScore),
                    finalScore
                ))
            }

            guard !Task.isCancelled else { return }

            let sorted = scored
                .sorted { $0.1 > $1.1 }
                .prefix(Self.maxResults)
                .map(\.0)

            await MainActor.run {
                self.results = Array(sorted)
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        indexTask?.cancel()
    }

    // MARK: - File collection

    /// Collects all files under `rootURL`, skipping `.gitignore`d directories.
    static func collectFiles(
        rootURL: URL,
        ignoredDirs: Set<String>,
        resolvedRootPath: String
    ) -> [(url: URL, relativePath: String)] {
        let fm = FileManager.default
        let hiddenNames: Set<String> = [".git", ".DS_Store"]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, String)] = []

        for case let fileURL as URL in enumerator {
            if hiddenNames.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            let resolved = fileURL.resolvingSymlinksInPath().path
            if ignoredDirs.contains(resolved) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            let relativePath = resolved.hasPrefix(resolvedRootPath)
                ? String(resolved.dropFirst(resolvedRootPath.count))
                : fileURL.lastPathComponent

            files.append((fileURL, relativePath))
        }

        return files
    }

    // MARK: - Fuzzy matching

    /// Returns a score for how well `query` matches the file. Returns `nil` if no match.
    ///
    /// Scoring strategy:
    /// - Filename subsequence match: base 1000 + bonus for exact/prefix/substring
    /// - Path-only match: base 500 + bonus for substring
    /// - Shorter paths rank higher on ties (penalty = `relativePath.count / 10`)
    static func fuzzyScore(query: String, fileName: String, relativePath: String) -> Int? {
        let q = query.lowercased()
        let fn = fileName.lowercased()
        let path = relativePath.lowercased()

        if isSubsequence(query: q, target: fn) {
            var score = 1000
            if fn == q { score += 500 }
            else if fn.hasPrefix(q) { score += 300 }
            else if fn.contains(q) { score += 200 }
            score -= relativePath.count / 10
            return score
        }

        if isSubsequence(query: q, target: path) {
            var score = 500
            if path.contains(q) { score += 200 }
            score -= relativePath.count / 10
            return score
        }

        return nil
    }

    /// Returns `true` if every character in `query` appears in `target` in order.
    static func isSubsequence(query: String, target: String) -> Bool {
        guard !query.isEmpty else { return true }
        var qi = query.startIndex
        for ch in target {
            guard qi < query.endIndex else { break }
            if ch == query[qi] {
                qi = query.index(after: qi)
            }
        }
        return qi == query.endIndex
    }
}
