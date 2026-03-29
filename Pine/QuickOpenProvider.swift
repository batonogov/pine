//
//  QuickOpenProvider.swift
//  Pine
//
//  Fuzzy file search provider for Quick Open (Cmd+P).
//

import Foundation

/// Provides fuzzy file search over the project tree for Quick Open.
@MainActor
@Observable
final class QuickOpenProvider {

    /// A single search result with scoring information.
    struct Result: Identifiable {
        let id: URL
        let fileName: String
        let relativePath: String
        let score: Int

        var url: URL { id }
    }

    /// Recent files storage key prefix.
    private static let recentFilesKey = "quickOpen.recentFiles"

    /// Cached flat list of all file URLs in the project.
    private(set) var fileIndex: [URL] = []

    /// Cached resolved paths for symlink-safe comparison (built once at index time).
    private var resolvedPaths: [URL: String] = [:]

    /// The root URL the index was built from (resolved for cache deduplication).
    private var indexedRoot: URL?

    /// The original (unresolved) root path prefix for computing relative paths.
    private var originalRootPrefix: String = ""

    // MARK: - Indexing

    /// Maximum recursion depth when traversing the file tree for indexing.
    static let maxIndexDepth = 100

    /// Rebuilds the flat file index from the FileNode tree.
    func buildIndex(from roots: [FileNode], rootURL: URL) {
        let resolved = rootURL.resolvingSymlinksInPath()
        if resolved == indexedRoot, !fileIndex.isEmpty { return }
        indexedRoot = resolved
        let rootPath = rootURL.path
        originalRootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let rootRealPath = resolved.path
        var files: [URL] = []
        for root in roots {
            collectFiles(from: root, into: &files, rootRealPath: rootRealPath, depth: 0)
        }
        fileIndex = files

        // Pre-resolve symlinks once for all indexed files
        var paths: [URL: String] = [:]
        paths.reserveCapacity(files.count)
        for url in files {
            paths[url] = url.resolvingSymlinksInPath().path
        }
        resolvedPaths = paths
    }

    /// Rebuilds the flat file index unconditionally, ignoring cache.
    /// Called when the file tree changes (files added/removed/renamed).
    func rebuildIndex(from roots: [FileNode], rootURL: URL) {
        indexedRoot = nil
        buildIndex(from: roots, rootURL: rootURL)
    }

    /// Invalidates the cached index (e.g., when project root changes).
    func invalidateIndex() {
        fileIndex = []
        resolvedPaths = [:]
        indexedRoot = nil
        originalRootPrefix = ""
    }

    private func collectFiles(from node: FileNode, into files: inout [URL], rootRealPath: String, depth: Int) {
        guard depth <= Self.maxIndexDepth else { return }

        if node.isSymlink {
            // Resolve symlink target and check boundary for both files and directories
            let resolvedPath = node.url.resolvingSymlinksInPath().path
            let isInsideProject = resolvedPath == rootRealPath || resolvedPath.hasPrefix(rootRealPath + "/")
            guard isInsideProject else { return }

            if node.isDirectory {
                guard let children = node.children else { return }
                for child in children {
                    collectFiles(from: child, into: &files, rootRealPath: rootRealPath, depth: depth + 1)
                }
            } else {
                files.append(node.url)
            }
        } else if node.isDirectory {
            guard let children = node.children else { return }
            for child in children {
                collectFiles(from: child, into: &files, rootRealPath: rootRealPath, depth: depth + 1)
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

        // Load recent files once per search, build a lookup by resolved path
        let recentList = loadRecentFiles()
        let recentLookup = buildRecentLookup(recentList)

        var results: [Result] = []
        for url in fileIndex {
            let fileName = url.lastPathComponent
            let relativePath = Self.relativePath(for: url, rootPrefix: rootPath, originalRootPrefix: originalRootPrefix)

            guard let score = fuzzyScore(
                queryLower: queryLower,
                fileNameLower: fileName.lowercased(),
                pathLower: relativePath.lowercased(),
                pathLength: relativePath.count
            ) else {
                continue
            }

            let resolved = resolvedPaths[url] ?? url.path
            let boost = recentLookup[resolved] ?? 0
            results.append(Result(
                id: url,
                fileName: fileName,
                relativePath: relativePath,
                score: score + boost
            ))
        }

        results.sort { $0.score > $1.score }
        return results
    }

    /// Checks if `query` is a subsequence of `target` (case-insensitive).
    static func isSubsequence(_ query: String, of target: String) -> Bool {
        isSubsequenceLowercased(query.lowercased(), of: target.lowercased())
    }

    /// Subsequence check on pre-lowercased strings (avoids redundant lowercasing).
    private static func isSubsequenceLowercased(_ query: String, of target: String) -> Bool {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex

        while queryIndex < query.endIndex, targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = target.index(after: targetIndex)
        }
        return queryIndex == query.endIndex
    }

    /// Computes a fuzzy match score from pre-lowercased inputs. Returns nil if no match.
    /// Higher scores = better match.
    func fuzzyScore(
        queryLower: String, fileNameLower: String,
        pathLower: String, pathLength: Int
    ) -> Int? {
        let matchesFileName = Self.isSubsequenceLowercased(queryLower, of: fileNameLower)
        let matchesPath = matchesFileName || Self.isSubsequenceLowercased(queryLower, of: pathLower)

        guard matchesPath else { return nil }

        var score = 0

        if matchesFileName {
            if fileNameLower == queryLower {
                score += 200
            } else if fileNameLower.hasPrefix(queryLower) {
                score += 150
            } else if fileNameLower.contains(queryLower) {
                score += 100
            } else {
                score += 50
            }
        } else {
            score += 10
        }

        // Shorter paths rank higher on ties
        score -= pathLength

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

    /// Builds a lookup dictionary from recent file list: resolved path -> boost score.
    private func buildRecentLookup(_ recentList: [String]) -> [String: Int] {
        var lookup: [String: Int] = [:]
        for (index, path) in recentList.enumerated() {
            let boost = max(0, 200 - index * 10)
            if boost > 0 {
                lookup[path] = boost
            }
        }
        return lookup
    }

    private func recentFilesResults() -> [Result] {
        let recent = loadRecentFiles()
        let rootPath = rootPathPrefix()
        let indexedSet = Set(resolvedPaths.values)

        return recent
            .filter { indexedSet.contains($0) }
            .map { path in
                let url = URL(fileURLWithPath: path)
                return Result(
                    id: url,
                    fileName: url.lastPathComponent,
                    relativePath: Self.relativePath(for: url, rootPrefix: rootPath, originalRootPrefix: originalRootPrefix),
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

    static func relativePath(for url: URL, rootPrefix: String, originalRootPrefix: String = "") -> String {
        let path = url.path
        if path.hasPrefix(rootPrefix) {
            return String(path.dropFirst(rootPrefix.count))
        }
        // Fallback: try original (unresolved) root prefix to handle
        // cases where resolvingSymlinksInPath() differs from realpath()
        // (e.g. /var vs /private/var on macOS).
        if !originalRootPrefix.isEmpty, path.hasPrefix(originalRootPrefix) {
            return String(path.dropFirst(originalRootPrefix.count))
        }
        return path
    }
}
