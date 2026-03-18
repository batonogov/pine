//
//  ProjectSearchProvider.swift
//  Pine
//
//  Created by Claude on 18.03.2026.
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Models

struct SearchMatch: Identifiable, Hashable {
    let id = UUID()
    let lineNumber: Int
    let lineContent: String
    let matchRangeStart: Int
    let matchRangeLength: Int
}

struct SearchFileGroup: Identifiable {
    var id: URL { url }
    let url: URL
    let relativePath: String
    let matches: [SearchMatch]
}

// MARK: - Search Provider

@Observable
final class ProjectSearchProvider {
    var query: String = ""
    var isCaseSensitive: Bool = false
    private(set) var isSearching: Bool = false
    private(set) var results: [SearchFileGroup] = []
    private(set) var totalMatchCount: Int = 0

    /// Maximum file size to search (1 MB).
    static let maxFileSize = 1_048_576
    /// Maximum total matches before stopping.
    static let maxResults = 1_000
    /// Debounce interval for search.
    static let debounceInterval: Duration = .milliseconds(300)

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

    static func performSearch(
        query: String,
        isCaseSensitive: Bool,
        rootURL: URL
    ) async -> [SearchFileGroup] {
        let ignoredPaths = await gitIgnoredPaths(rootURL: rootURL)
        let files = collectSearchableFiles(rootURL: rootURL, ignoredPaths: ignoredPaths)

        var groups: [SearchFileGroup] = []
        var totalMatches = 0
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        for fileURL in files {
            guard !Task.isCancelled else { break }
            guard totalMatches < maxResults else { break }

            let matches = searchFile(
                at: fileURL,
                query: query,
                isCaseSensitive: isCaseSensitive,
                remainingCapacity: maxResults - totalMatches
            )

            if !matches.isEmpty {
                let resolvedFile = fileURL.resolvingSymlinksInPath().path
                let relativePath = resolvedFile.hasPrefix(rootPath)
                    ? String(resolvedFile.dropFirst(rootPath.count))
                    : fileURL.lastPathComponent

                groups.append(SearchFileGroup(
                    url: fileURL,
                    relativePath: relativePath,
                    matches: matches
                ))
                totalMatches += matches.count
            }
        }

        return groups
    }

    /// Searches a single file for the query string.
    static func searchFile(
        at url: URL,
        query: String,
        isCaseSensitive: Bool,
        remainingCapacity: Int = maxResults
    ) -> [SearchMatch] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
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

    /// Collects all searchable text files under rootURL.
    static func collectSearchableFiles(rootURL: URL, ignoredPaths: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .typeIdentifierKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []

        for case let fileURL as URL in enumerator {
            // Skip .git directory
            if fileURL.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }

            // Skip ignored paths (check both exact match and parent directory match)
            let filePath = fileURL.resolvingSymlinksInPath().path
            if ignoredPaths.contains(filePath) {
                enumerator.skipDescendants()
                continue
            }
            let isInsideIgnored = ignoredPaths.contains { ignoredPath in
                filePath.hasPrefix(ignoredPath + "/")
            }
            if isInsideIgnored {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            // Skip large files
            if let size = values.fileSize, size > maxFileSize { continue }

            // Skip binary files
            if isBinaryFile(url: fileURL) { continue }

            files.append(fileURL)
        }

        return files
    }

    /// Returns true for known binary file types.
    static func isBinaryFile(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf)
            || type.conforms(to: .font)
            || type.conforms(to: .archive)
            || type.conforms(to: .executable)
    }

    // MARK: - .gitignore support

    /// Uses `git check-ignore` to find ignored paths.
    /// Runs FileManager enumeration and Process on a background thread
    /// to avoid Swift 6 sendability warnings on the main actor.
    static func gitIgnoredPaths(rootURL: URL) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = gitIgnoredPathsSync(rootURL: rootURL)
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous implementation of .gitignore path collection.
    static func gitIgnoredPathsSync(rootURL: URL) -> Set<String> {
        // Check if this is a git repo
        let gitDir = rootURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return [] }

        // Collect all paths relative to root
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var relativePaths: [String] = []
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let path = fileURL.path
            if path.hasPrefix(rootPath) {
                relativePaths.append(String(path.dropFirst(rootPath.count)))
            }
        }

        guard !relativePaths.isEmpty else { return [] }

        // Run git check-ignore --stdin
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ignore", "--stdin"]
        process.currentDirectoryURL = rootURL

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let inputData = relativePaths.joined(separator: "\n").data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else { return [] }

        var ignored = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let fullPath = rootPath + line
            ignored.insert(fullPath)
        }

        return ignored
    }
}
