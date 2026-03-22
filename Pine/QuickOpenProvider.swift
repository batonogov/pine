//
//  QuickOpenProvider.swift
//  Pine
//
//  Fuzzy file search provider for Quick Open (Cmd+P).
//

import Foundation

/// Provides fuzzy file search over the project tree for Quick Open.
@Observable
final class QuickOpenProvider {

    /// A single search result with scoring information.
    struct Result: Identifiable {
        let id: URL
        let url: URL
        let fileName: String
        let relativePath: String
        let score: Int
    }

    /// Recent files storage key prefix.
    private static let recentFilesKey = "quickOpen.recentFiles"

    /// Cached flat list of all file URLs in the project.
    private(set) var fileIndex: [URL] = []

    /// The root URL the index was built from.
    private var indexedRoot: URL?

    // MARK: - Indexing

    /// Rebuilds the flat file index from the FileNode tree.
    func buildIndex(from roots: [FileNode], rootURL: URL) {
        let resolved = rootURL.resolvingSymlinksInPath()
        if resolved == indexedRoot, !fileIndex.isEmpty { return }
        indexedRoot = resolved
        var files: [URL] = []
        for root in roots {
            collectFiles(from: root, into: &files)
        }
        fileIndex = files
    }

    /// Invalidates the cached index (e.g., when project root changes).
    func invalidateIndex() {
        fileIndex = []
        indexedRoot = nil
    }

    private func collectFiles(from node: FileNode, into files: inout [URL]) {
        if node.isDirectory {
            guard let children = node.children else { return }
            for child in children {
                collectFiles(from: child, into: &files)
            }
        } else {
            files.append(node.url)
        }
    }

    // MARK: - Fuzzy Search

    /// Searches the file index with fuzzy matching.
    /// Returns results sorted by score (highest first).
    func search(query: String) -> [Result] {
        guard !query.isEmpty else {
            return recentFilesResults()
        }

        let rootPath = rootPathPrefix()
        let queryLower = query.lowercased()

        var results: [Result] = []
        for url in fileIndex {
            let fileName = url.lastPathComponent
            let relativePath = Self.relativePath(for: url, rootPrefix: rootPath)

            guard let score = fuzzyScore(query: queryLower, fileName: fileName, path: relativePath) else {
                continue
            }

            let boostedScore = score + recentBoost(for: url)
            results.append(Result(
                id: url,
                url: url,
                fileName: fileName,
                relativePath: relativePath,
                score: boostedScore
            ))
        }

        results.sort { $0.score > $1.score }
        return results
    }

    /// Checks if `query` is a subsequence of `target` (case-insensitive).
    static func isSubsequence(_ query: String, of target: String) -> Bool {
        var queryIndex = query.startIndex
        let queryLower = query.lowercased()
        let targetLower = target.lowercased()
        var targetIndex = targetLower.startIndex

        while queryIndex < queryLower.endIndex, targetIndex < targetLower.endIndex {
            if queryLower[queryIndex] == targetLower[targetIndex] {
                queryIndex = queryLower.index(after: queryIndex)
            }
            targetIndex = targetLower.index(after: targetIndex)
        }
        return queryIndex == queryLower.endIndex
    }

    /// Computes a fuzzy match score. Returns nil if no match.
    /// Higher scores = better match.
    func fuzzyScore(query: String, fileName: String, path: String) -> Int? {
        let queryLower = query.lowercased()
        let fileNameLower = fileName.lowercased()
        let pathLower = path.lowercased()

        // Try matching against filename first, then full path
        let matchesFileName = Self.isSubsequence(queryLower, of: fileNameLower)
        let matchesPath = matchesFileName || Self.isSubsequence(queryLower, of: pathLower)

        guard matchesPath else { return nil }

        var score = 0

        if matchesFileName {
            // Exact match bonus
            if fileNameLower == queryLower {
                score += 200
            }
            // Prefix bonus
            else if fileNameLower.hasPrefix(queryLower) {
                score += 150
            }
            // Substring bonus
            else if fileNameLower.contains(queryLower) {
                score += 100
            }
            // Subsequence in filename
            else {
                score += 50
            }
        } else {
            // Only matched path, not filename
            score += 10
        }

        // Shorter paths rank higher on ties
        score -= path.count

        return score
    }

    // MARK: - Recent Files

    /// Records a file as recently opened.
    func recordOpened(url: URL) {
        let resolvedPath = url.resolvingSymlinksInPath().path
        var recent = loadRecentFiles()
        recent.removeAll { $0 == resolvedPath }
        recent.insert(resolvedPath, at: 0)
        if recent.count > 20 {
            recent = Array(recent.prefix(20))
        }
        saveRecentFiles(recent)
    }

    private func recentBoost(for url: URL) -> Int {
        let recent = loadRecentFiles()
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard let index = recent.firstIndex(of: resolvedPath) else { return 0 }
        // More recently opened = higher boost
        return max(0, 200 - index * 10)
    }

    private func recentFilesResults() -> [Result] {
        let recent = loadRecentFiles()
        let rootPath = rootPathPrefix()
        let indexedSet = Set(fileIndex.map { $0.resolvingSymlinksInPath().path })

        return recent
            .filter { indexedSet.contains($0) }
            .map { path in
                let url = URL(fileURLWithPath: path)
                return Result(
                    id: url,
                    url: url,
                    fileName: url.lastPathComponent,
                    relativePath: Self.relativePath(for: url, rootPrefix: rootPath),
                    score: 0
                )
            }
    }

    private func loadRecentFiles() -> [String] {
        guard let root = indexedRoot else { return [] }
        let key = Self.recentFilesKey + "." + root.path
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func saveRecentFiles(_ files: [String]) {
        guard let root = indexedRoot else { return }
        let key = Self.recentFilesKey + "." + root.path
        UserDefaults.standard.set(files, forKey: key)
    }

    // MARK: - Helpers

    private func rootPathPrefix() -> String {
        guard let root = indexedRoot else { return "" }
        let path = root.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    static func relativePath(for url: URL, rootPrefix: String) -> String {
        let path = url.path
        if path.hasPrefix(rootPrefix) {
            return String(path.dropFirst(rootPrefix.count))
        }
        return path
    }
}
