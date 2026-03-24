//
//  ProjectSearchProvider.swift
//  Pine
//
//  Created by Claude on 18.03.2026.
//

import Foundation
import os
import UniformTypeIdentifiers

// MARK: - Models

struct SearchMatch: Identifiable, Hashable, Sendable {
    let lineNumber: Int
    let lineContent: String
    let matchRangeStart: Int
    let matchRangeLength: Int

    var id: Int { lineNumber &* 100_003 &+ matchRangeStart }
}

struct SearchFileGroup: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let relativePath: String
    let matches: [SearchMatch]
}

// MARK: - Search Provider

@Observable
final class ProjectSearchProvider {
    private static let logger = Logger.search
    var query: String = ""
    var isCaseSensitive: Bool = false
    private(set) var isSearching: Bool = false
    private(set) var results: [SearchFileGroup] = []
    private(set) var totalMatchCount: Int = 0

    /// Maximum file size to search (1 MB).
    nonisolated static let maxFileSize = 1_048_576
    /// Maximum total matches before stopping.
    nonisolated static let maxResults = 1_000
    /// Maximum matches per file in parallel search to avoid unbounded memory use.
    nonisolated private static let maxResultsPerFile = 100
    /// Debounce interval for search.
    nonisolated static let debounceInterval: Duration = .milliseconds(300)

    private var searchTask: Task<Void, Never>?

    func search(in rootURL: URL) {
        searchTask?.cancel()
        let currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !currentQuery.isEmpty else {
            results = []
            totalMatchCount = 0
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task { [isCaseSensitive] in
            // Debounce
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }

            let fileGroups = await Self.performSearch(
                query: currentQuery,
                isCaseSensitive: isCaseSensitive,
                rootURL: rootURL
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.results = fileGroups
                self.totalMatchCount = fileGroups.reduce(0) { $0 + $1.matches.count }
                self.isSearching = false
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        isSearching = false
    }

    // MARK: - Search logic

    nonisolated static func performSearch(
        query: String,
        isCaseSensitive: Bool,
        rootURL: URL
    ) async -> [SearchFileGroup] {
        guard !query.isEmpty else { return [] }

        let ignoredDirs = await gitIgnoredDirectories(rootURL: rootURL)
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        let files = collectSearchableFiles(rootURL: rootURL, ignoredDirs: ignoredDirs, resolvedRootPath: rootPath)

        var groups: [SearchFileGroup] = []
        var totalMatches = 0

        await withTaskGroup(of: SearchFileGroup?.self) { group in
            let maxConcurrency = max(ProcessInfo.processInfo.activeProcessorCount, 1)
            var submitted = 0

            // Seed initial batch up to maxConcurrency
            var fileIterator = files.makeIterator()
            while submitted < maxConcurrency, let (fileURL, relativePath) = fileIterator.next() {
                guard !Task.isCancelled else { break }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let matches = Self.searchFile(
                        at: fileURL,
                        query: query,
                        isCaseSensitive: isCaseSensitive,
                        remainingCapacity: Self.maxResultsPerFile
                    )
                    guard !matches.isEmpty else { return nil }
                    return SearchFileGroup(
                        url: fileURL,
                        relativePath: relativePath,
                        matches: matches
                    )
                }
                submitted += 1
            }

            // Process results and feed new tasks one-for-one to maintain concurrency limit
            for await result in group {
                guard !Task.isCancelled else { break }

                if let fileGroup = result {
                    groups.append(fileGroup)
                    totalMatches += fileGroup.matches.count
                    if totalMatches >= maxResults { break }
                }

                // Submit next file
                if let (fileURL, relativePath) = fileIterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let matches = Self.searchFile(
                            at: fileURL,
                            query: query,
                            isCaseSensitive: isCaseSensitive,
                            remainingCapacity: Self.maxResultsPerFile
                        )
                        guard !matches.isEmpty else { return nil }
                        return SearchFileGroup(
                            url: fileURL,
                            relativePath: relativePath,
                            matches: matches
                        )
                    }
                }
            }
        }

        // Sort by relative path so results are deterministic regardless of completion order
        groups.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        return groups
    }

    /// Searches a single file for the query string.
    nonisolated static func searchFile(
        at url: URL,
        query: String,
        isCaseSensitive: Bool,
        remainingCapacity: Int = maxResults
    ) -> [SearchMatch] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning("Cannot read file for search \(url.lastPathComponent): \(error)")
            return []
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n")
        var matches: [SearchMatch] = []

        let compareOptions: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]

        for (index, line) in lines.enumerated() {
            guard matches.count < remainingCapacity else { break }

            var searchStart = line.startIndex
            while searchStart < line.endIndex,
                  let range = line.range(of: query, options: compareOptions, range: searchStart..<line.endIndex) {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                let utf16Start = line.utf16.distance(from: line.startIndex, to: range.lowerBound)
                let utf16Length = line.utf16.distance(from: range.lowerBound, to: range.upperBound)

                matches.append(SearchMatch(
                    lineNumber: index + 1,
                    lineContent: String(trimmedLine.prefix(200)),
                    matchRangeStart: utf16Start,
                    matchRangeLength: utf16Length
                ))

                searchStart = range.upperBound
                guard matches.count < remainingCapacity else { break }
            }
        }

        return matches
    }

    // MARK: - File collection

    /// Collects all searchable text files under rootURL in a single pass.
    /// Returns tuples of (fileURL, relativePath) to avoid resolving symlinks per-file later.
    nonisolated static func collectSearchableFiles(
        rootURL: URL,
        ignoredDirs: Set<String>,
        resolvedRootPath: String
    ) -> [(URL, String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, String)] = []

        for case let fileURL as URL in enumerator {
            // Skip .git directory
            if fileURL.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }

            // Skip ignored directories (O(1) lookup per path component)
            let resolved = fileURL.resolvingSymlinksInPath().path
            if ignoredDirs.contains(resolved) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            // Skip large files
            if let size = values.fileSize, size > maxFileSize { continue }

            // Skip binary files
            if isBinaryFile(url: fileURL) { continue }

            let relativePath = resolved.hasPrefix(resolvedRootPath)
                ? String(resolved.dropFirst(resolvedRootPath.count))
                : fileURL.lastPathComponent

            files.append((fileURL, relativePath))
        }

        return files
    }

    /// Extensions that UTType misclassifies as binary (e.g. .js → executable, .ts → MPEG-2 transport stream).
    nonisolated private static let textExtensionOverrides: Set<String> = [
        "js", "jsx", "mjs", "cjs",
        "ts", "tsx", "mts", "cts",
        "vue", "svelte", "astro"
    ]

    /// Returns true for known binary file types.
    nonisolated static func isBinaryFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if textExtensionOverrides.contains(ext) { return false }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf)
            || type.conforms(to: .font)
            || type.conforms(to: .archive)
            || type.conforms(to: .executable)
    }

    // MARK: - .gitignore support

    /// Uses `git ls-files` to find ignored directories in a single git call
    /// (no need to enumerate the filesystem first).
    nonisolated static func gitIgnoredDirectories(rootURL: URL) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = gitIgnoredDirectoriesSync(rootURL: rootURL)
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous implementation — returns absolute paths of ignored directories.
    nonisolated static func gitIgnoredDirectoriesSync(rootURL: URL) -> Set<String> {
        let gitDir = rootURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return [] }

        // Use git ls-files to get ignored files, then extract their parent directories.
        // This avoids a full filesystem enumeration just to feed git check-ignore.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"]
        process.currentDirectoryURL = rootURL

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else { return [] }

        let rootPath = rootURL.resolvingSymlinksInPath().path
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        var dirs = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // --directory flag outputs directory names with trailing /
            let cleaned = line.hasSuffix("/") ? String(line.dropLast()) : line
            let fullPath = base + cleaned
            dirs.insert(fullPath)
        }

        return dirs
    }
}
