//
//  GitStatusProvider.swift
//  Pine
//
//  Created by Claude on 10.03.2026.
//

import Foundation
import SwiftUI

// MARK: - Models

enum GitFileStatus: Equatable {
    case untracked
    case modified
    case staged
    case added
    case deleted
    case conflict
    case mixed // staged + unstaged changes
}

extension GitFileStatus {
    var color: Color {
        switch self {
        case .modified, .mixed: return .orange
        case .staged:           return .green
        case .added:            return Color(.systemGreen)
        case .untracked:        return Color(.systemTeal)
        case .deleted:          return .red
        case .conflict:         return .red
        }
    }
}

struct GitLineDiff: Equatable {
    enum Kind { case added, modified, deleted }
    let line: Int
    let kind: Kind

    /// Returns the first line of each contiguous change region, sorted ascending.
    static func changeRegionStarts(_ diffs: [GitLineDiff]) -> [Int] {
        let sorted = diffs.sorted { $0.line < $1.line }
        var starts: [Int] = []
        var previousLine: Int?
        for diff in sorted {
            if let prev = previousLine, diff.line == prev + 1 {
                previousLine = diff.line
            } else {
                starts.append(diff.line)
                previousLine = diff.line
            }
        }
        return starts
    }

    /// Returns the line of the next change region after `currentLine`, wrapping to the first if needed.
    static func nextChangeLine(from currentLine: Int, in diffs: [GitLineDiff]) -> Int? {
        let starts = changeRegionStarts(diffs)
        return nextChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
    }

    /// Returns the line of the previous change region before `currentLine`, wrapping to the last if needed.
    static func previousChangeLine(from currentLine: Int, in diffs: [GitLineDiff]) -> Int? {
        let starts = changeRegionStarts(diffs)
        return previousChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
    }

    /// Next change using pre-computed region starts (avoids recomputation when caller needs both directions).
    static func nextChangeLine(from currentLine: Int, regionStarts starts: [Int], diffs: [GitLineDiff]) -> Int? {
        guard !starts.isEmpty else { return nil }
        let idx = regionIndex(forLine: currentLine, regionStarts: starts, diffs: diffs)
        if let idx {
            return starts[(idx + 1) % starts.count]
        }
        if let next = starts.first(where: { $0 > currentLine }) {
            return next
        }
        return starts[0]
    }

    /// Previous change using pre-computed region starts.
    static func previousChangeLine(from currentLine: Int, regionStarts starts: [Int], diffs: [GitLineDiff]) -> Int? {
        guard !starts.isEmpty else { return nil }
        let idx = regionIndex(forLine: currentLine, regionStarts: starts, diffs: diffs)
        if let idx {
            return starts[(idx - 1 + starts.count) % starts.count]
        }
        if let prev = starts.last(where: { $0 < currentLine }) {
            return prev
        }
        return starts[starts.count - 1]
    }

    /// Returns the index of the region that contains `line`, or nil if line is not in any region.
    private static func regionIndex(forLine line: Int, regionStarts: [Int], diffs: [GitLineDiff]) -> Int? {
        let diffLines = Set(diffs.map(\.line))
        guard diffLines.contains(line) else { return nil }
        // Walk backwards from line to find the region start
        var current = line
        while current > 0 && diffLines.contains(current - 1) {
            current -= 1
        }
        return regionStarts.firstIndex(of: current)
    }
}

// MARK: - GitStatusProvider

@Observable
final class GitStatusProvider {
    var currentBranch: String = ""
    var fileStatuses: [String: GitFileStatus] = [:]
    var ignoredPaths: Set<String> = []
    var isGitRepository: Bool = false
    var branches: [String] = []

    var repositoryURL: URL?
    var gitRootPath: String?

    /// True when the working tree has any uncommitted changes (modified, staged, untracked, etc.).
    var hasUncommittedChanges: Bool { !fileStatuses.isEmpty }

    // MARK: - Setup & Refresh

    func setup(repositoryURL: URL) {
        self.repositoryURL = repositoryURL
        let result = Self.runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
        isGitRepository = result.exitCode == 0
        if isGitRepository {
            gitRootPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            refresh()
        } else {
            currentBranch = ""
            fileStatuses = [:]
            ignoredPaths = []
            branches = []
        }
    }

    func refresh() {
        guard isGitRepository, let url = repositoryURL else { return }

        let group = DispatchGroup()
        var branch = ""
        var statuses: [String: GitFileStatus] = [:]
        var ignored: Set<String> = []
        var branchList: [String] = []

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            branch = Self.fetchBranch(at: url)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.fetchStatusAndIgnored(at: url)
            statuses = result.statuses
            ignored = result.ignored
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            branchList = Self.fetchBranches(at: url)
            group.leave()
        }

        group.wait()

        currentBranch = branch
        fileStatuses = statuses
        ignoredPaths = ignored
        branches = branchList
    }

    /// Async version of setup — runs git detection and initial refresh
    /// on a background thread, then updates properties on the main thread.
    func setupAsync(repositoryURL: URL) async {
        self.repositoryURL = repositoryURL
        let (isRepo, rootPath, branch, statuses, ignored, branchList) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
                let isRepo = result.exitCode == 0
                guard isRepo else {
                    continuation.resume(returning: (false, nil as String?, "", [:] as [String: GitFileStatus], Set<String>(), [String]()))
                    return
                }
                let rootPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = Self.fetchBranch(at: repositoryURL)
                let statusResult = Self.fetchStatusAndIgnored(at: repositoryURL)
                let branchList = Self.fetchBranches(at: repositoryURL)
                continuation.resume(returning: (true, rootPath, branch, statusResult.statuses, statusResult.ignored, branchList))
            }
        }

        await MainActor.run {
            self.isGitRepository = isRepo
            self.gitRootPath = rootPath
            if isRepo {
                self.currentBranch = branch
                self.fileStatuses = statuses
                self.ignoredPaths = ignored
                self.branches = branchList
            } else {
                self.currentBranch = ""
                self.fileStatuses = [:]
                self.ignoredPaths = []
                self.branches = []
            }
        }
    }

    // MARK: - Static Fetch Methods

    static func fetchBranch(at url: URL) -> String {
        let result = runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: url)
        return result.exitCode == 0
            ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    static func fetchStatusAndIgnored(
        at url: URL
    ) -> (statuses: [String: GitFileStatus], ignored: Set<String>) {
        let result = runGit(["--no-optional-locks", "status", "--ignored", "--porcelain"], at: url)
        guard result.exitCode == 0 else { return ([:], []) }
        return (parseStatusOutput(result.output), parseIgnoredOutput(result.output))
    }

    static func fetchBranches(at url: URL) -> [String] {
        let result = runGit(["branch", "--sort=-committerdate", "--format=%(refname:short)"], at: url)
        guard result.exitCode == 0 else { return [] }
        return result.output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// Runs git refresh on a background queue and updates properties on the main thread.
    /// Safe to call from the main thread — does not block.
    /// Uses `async let` for parallel git operations (branch, status, branches).
    /// Supports cooperative cancellation — if the Task is cancelled before
    /// the background work completes, stale results are discarded.
    func refreshAsync() async {
        guard isGitRepository, let url = repositoryURL else { return }

        let (branch, statuses, ignored, branchList) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Run all three git operations in parallel using DispatchGroup
                let group = DispatchGroup()
                var branch = ""
                var statuses: [String: GitFileStatus] = [:]
                var ignored: Set<String> = []
                var branchList: [String] = []

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    branch = Self.fetchBranch(at: url)
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Self.fetchStatusAndIgnored(at: url)
                    statuses = result.statuses
                    ignored = result.ignored
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    branchList = Self.fetchBranches(at: url)
                    group.leave()
                }

                group.wait()
                continuation.resume(returning: (branch, statuses, ignored, branchList))
            }
        }

        // If the Task was cancelled (e.g. a newer refresh started),
        // discard stale results to avoid overwriting newer data.
        guard !Task.isCancelled else { return }

        await MainActor.run {
            self.currentBranch = branch
            self.fileStatuses = statuses
            self.ignoredPaths = ignored
            self.branches = branchList
        }
    }

    // MARK: - Status Queries

    func statusForFile(at url: URL) -> GitFileStatus? {
        guard let path = relativePath(for: url) else { return nil }
        if let status = fileStatuses[path] { return status }
        // git status --porcelain reports untracked directories as a single
        // entry with a trailing slash (e.g. "?? newdir/") without listing
        // individual files inside. Check if this file lives inside such
        // a directory so it inherits the untracked status.
        if isInsideUntrackedDirectory(path) { return .untracked }
        return nil
    }

    func isIgnored(at url: URL) -> Bool {
        guard let path = relativePath(for: url) else { return false }
        return isPathIgnored(path)
    }

    private func isPathIgnored(_ path: String) -> Bool {
        if ignoredPaths.contains(path) { return true }
        // Walk up parent directories — O(depth) instead of O(ignoredPaths.count)
        var components = path.components(separatedBy: "/")
        while components.count > 1 {
            components.removeLast()
            if ignoredPaths.contains(components.joined(separator: "/")) { return true }
        }
        return false
    }

    func statusForDirectory(at url: URL) -> GitFileStatus? {
        guard let dirPath = relativePath(for: url) else { return nil }
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"

        var hasModified = false
        var hasStaged = false
        var hasUntracked = false
        var hasConflict = false

        for (path, status) in fileStatuses {
            guard path.hasPrefix(prefix) else { continue }
            switch status {
            case .conflict:           hasConflict = true
            case .modified, .mixed:   hasModified = true
            case .staged, .added:     hasStaged = true
            case .untracked:          hasUntracked = true
            case .deleted:            hasModified = true
            }
        }

        if hasConflict { return .conflict }
        if hasModified { return .modified }
        if hasStaged { return .staged }
        if hasUntracked { return .untracked }
        // This directory may itself be inside a wholly untracked parent
        // directory (git reports only the top-level entry "?? parent/").
        if isInsideUntrackedDirectory(prefix) { return .untracked }
        return nil
    }

    // MARK: - Diff for Gutter

    func diffForFile(at url: URL) -> [GitLineDiff] {
        guard isGitRepository, let repoURL = repositoryURL else { return [] }
        // Check if HEAD exists (new repo without commits)
        let headCheck = Self.runGit(["rev-parse", "HEAD"], at: repoURL)
        guard headCheck.exitCode == 0 else { return [] }

        let result = Self.runGit(["diff", "HEAD", "--unified=0", "--", url.path], at: repoURL)
        guard result.exitCode == 0, !result.output.isEmpty else { return [] }
        return Self.parseDiff(result.output)
    }

    /// Async version of diffForFile — runs git diff on a background thread.
    /// Safe to call from the main thread.
    func diffForFileAsync(at url: URL) async -> [GitLineDiff] {
        guard isGitRepository, let repoURL = repositoryURL else { return [] }
        let filePath = url.path

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let headCheck = Self.runGit(["rev-parse", "HEAD"], at: repoURL)
                guard headCheck.exitCode == 0 else {
                    continuation.resume(returning: [])
                    return
                }
                let result = Self.runGit(["diff", "HEAD", "--unified=0", "--", filePath], at: repoURL)
                guard result.exitCode == 0, !result.output.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.parseDiff(result.output))
            }
        }
    }

    // MARK: - Branch Operations

    func checkoutBranch(_ branch: String) -> (success: Bool, error: String) {
        guard let url = repositoryURL else { return (false, "No repository") }
        let result = Self.runGit(["switch", branch], at: url)
        if result.exitCode == 0 {
            refresh()
            return (true, "")
        }
        return (false, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Async version of checkoutBranch — runs git switch on a background thread,
    /// then refreshes status asynchronously. Safe to call from the main thread.
    func checkoutBranchAsync(_ branch: String) async -> (success: Bool, error: String) {
        guard let url = repositoryURL else { return (false, "No repository") }

        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = Self.runGit(["switch", branch], at: url)
                continuation.resume(returning: gitResult)
            }
        }

        guard result.exitCode == 0 else {
            return (false, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        await refreshAsync()
        return (true, "")
    }

    // MARK: - Private Helpers

    /// Strips C-style quoting that git applies to paths containing spaces,
    /// non-ASCII characters, or special characters.
    /// `"examples copy/"` → `examples copy/`
    /// `"\320\241\320\275\320\270\320\274\320\276\320\272.png"` → `Снимок.png`
    static func unquoteGitPath(_ path: String) -> String {
        guard path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 else {
            return path
        }
        // Strip surrounding quotes
        let inner = path.dropFirst().dropLast()
        var bytes: [UInt8] = []
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\" {
                let next = inner.index(after: i)
                guard next < inner.endIndex else {
                    bytes.append(UInt8(ascii: "\\"))
                    break
                }
                switch inner[next] {
                case "\\":
                    bytes.append(UInt8(ascii: "\\"))
                    i = inner.index(after: next)
                case "\"":
                    bytes.append(UInt8(ascii: "\""))
                    i = inner.index(after: next)
                case "n":
                    bytes.append(UInt8(ascii: "\n"))
                    i = inner.index(after: next)
                case "t":
                    bytes.append(UInt8(ascii: "\t"))
                    i = inner.index(after: next)
                case "a":
                    bytes.append(0x07)
                    i = inner.index(after: next)
                case "b":
                    bytes.append(0x08)
                    i = inner.index(after: next)
                case "f":
                    bytes.append(0x0C)
                    i = inner.index(after: next)
                case "r":
                    bytes.append(UInt8(ascii: "\r"))
                    i = inner.index(after: next)
                case "v":
                    bytes.append(0x0B)
                    i = inner.index(after: next)
                case "0"..."3":
                    // Octal escape: 1-3 digits
                    var octal = String(inner[next])
                    var end = inner.index(after: next)
                    for _ in 0..<2 {
                        guard end < inner.endIndex, inner[end] >= "0", inner[end] <= "7" else { break }
                        octal.append(inner[end])
                        end = inner.index(after: end)
                    }
                    if let value = UInt8(octal, radix: 8) {
                        bytes.append(value)
                    }
                    i = end
                default:
                    bytes.append(UInt8(ascii: "\\"))
                    i = next
                }
            } else {
                for byte in String(inner[i]).utf8 {
                    bytes.append(byte)
                }
                i = inner.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Returns true when `path` falls inside a directory that git reports as
    /// wholly untracked (i.e. there is a "?? dir/" entry in `fileStatuses`).
    private func isInsideUntrackedDirectory(_ path: String) -> Bool {
        for (key, status) in fileStatuses where status == .untracked && key.hasSuffix("/") {
            if path.hasPrefix(key) { return true }
        }
        return false
    }

    private func relativePath(for url: URL) -> String? {
        guard let rootPath = gitRootPath else { return nil }
        let filePath = url.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    static func parseStatusOutput(_ output: String) -> [String: GitFileStatus] {
        var statuses: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            // Skip ignored entries (!! prefix) from --ignored output
            guard !line.hasPrefix("!!") else { continue }
            let indexChar = line[line.startIndex]
            let workTreeChar = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))

            // git status --porcelain C-quotes paths containing spaces,
            // non-ASCII, or special characters (e.g. "examples copy/"
            // or "\320\241\320\275\320\270\320\274\320\276\320\272.png").
            path = Self.unquoteGitPath(path)

            // Handle renames: "R  old -> new"
            if path.contains(" -> ") {
                let parts = path.components(separatedBy: " -> ")
                if parts.count == 2 { path = parts[1] }
            }

            let status: GitFileStatus
            switch (indexChar, workTreeChar) {
            case ("?", "?"):
                status = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"):
                status = .conflict
            case ("A", " "):
                status = .added
            case ("D", " "), (" ", "D"):
                status = .deleted
            case ("M", " "), ("R", " "):
                status = .staged
            case (" ", "M"):
                status = .modified
            case ("M", "M"):
                status = .mixed
            default:
                if indexChar != " " && indexChar != "?" {
                    status = workTreeChar != " " && workTreeChar != "?" ? .mixed : .staged
                } else {
                    status = .modified
                }
            }

            statuses[path] = status
        }

        return statuses
    }

    static func parseIgnoredOutput(_ output: String) -> Set<String> {
        var paths: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("!! ") else { continue }
            var path = String(line.dropFirst(3))
            // Remove trailing slash for directories to normalize
            if path.hasSuffix("/") { path = String(path.dropLast()) }
            paths.insert(path)
        }
        return paths
    }

    // MARK: - Blame Parser

    /// Parses `git blame --porcelain` output into an array of `GitBlameLine`.
    ///
    /// Porcelain format:
    /// ```
    /// <hash> <orig-line> <final-line> [<num-lines>]   ← first occurrence of commit
    /// author <name>
    /// author-time <unix-timestamp>
    /// summary <text>
    /// \t<content>
    ///
    /// <hash> <orig-line> <final-line>                  ← subsequent lines from same commit
    /// \t<content>
    /// ```
    nonisolated static func parseBlame(_ output: String) -> [GitBlameLine] {
        guard !output.isEmpty else { return [] }

        var result: [GitBlameLine] = []
        let lines = output.components(separatedBy: "\n")

        // Cache: hash → (author, authorTime, summary)
        var commitCache: [String: (author: String, authorTime: Date, summary: String)] = [:]

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Skip empty lines
            guard !line.isEmpty else {
                i += 1
                continue
            }

            // Commit header line: <40-char-hash> <orig> <final> [<count>]
            let parts = line.split(separator: " ", maxSplits: 4)
            guard parts.count >= 3,
                  parts[0].count == 40,
                  parts[0].allSatisfy({ $0.isHexDigit }),
                  let finalLine = Int(parts[2]) else {
                i += 1
                continue
            }

            let hash = String(parts[0])
            i += 1

            // If this is the first occurrence, read header fields
            var author = ""
            var authorTime = Date(timeIntervalSince1970: 0)
            var summary = ""
            var hasHeaders = false

            while i < lines.count {
                let headerLine = lines[i]
                if headerLine.hasPrefix("\t") {
                    // Content line — end of headers
                    break
                } else if headerLine.hasPrefix("author ") {
                    author = String(headerLine.dropFirst(7))
                    hasHeaders = true
                } else if headerLine.hasPrefix("author-time ") {
                    if let ts = TimeInterval(headerLine.dropFirst(12)) {
                        authorTime = Date(timeIntervalSince1970: ts)
                    }
                } else if headerLine.hasPrefix("summary ") {
                    summary = String(headerLine.dropFirst(8))
                }
                i += 1
            }

            // Skip the content line (starts with \t)
            if i < lines.count && lines[i].hasPrefix("\t") {
                i += 1
            }

            if hasHeaders {
                commitCache[hash] = (author, authorTime, summary)
            } else if let cached = commitCache[hash] {
                author = cached.author
                authorTime = cached.authorTime
                summary = cached.summary
            }

            result.append(GitBlameLine(
                hash: hash,
                author: author,
                authorTime: authorTime,
                summary: summary,
                finalLine: finalLine
            ))
        }

        return result
    }

    // MARK: - Diff Parser

    nonisolated static func parseDiff(_ diffOutput: String) -> [GitLineDiff] {
        var diffs: [GitLineDiff] = []
        let lines = diffOutput.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]

            guard line.hasPrefix("@@") else {
                i += 1
                continue
            }

            // Parse @@ -old[,count] +new[,count] @@
            guard let newStart = parseHunkNewStart(line) else {
                i += 1
                continue
            }

            i += 1
            var newLine = newStart

            while i < lines.count && !lines[i].hasPrefix("@@") && !lines[i].hasPrefix("diff ") {
                let hl = lines[i]

                if hl.hasPrefix("-") || hl.hasPrefix("+") {
                    // Collect consecutive block of -/+ lines
                    var deletions = 0
                    var additions = 0
                    let blockNewLine = newLine

                    while i < lines.count && lines[i].hasPrefix("-") {
                        deletions += 1
                        i += 1
                    }
                    // Skip "\ No newline at end of file"
                    while i < lines.count && lines[i].hasPrefix("\\") { i += 1 }

                    while i < lines.count && lines[i].hasPrefix("+") {
                        additions += 1
                        i += 1
                    }
                    while i < lines.count && lines[i].hasPrefix("\\") { i += 1 }

                    let modifiedCount = min(deletions, additions)
                    let addedCount = additions - modifiedCount

                    for j in 0..<modifiedCount {
                        diffs.append(GitLineDiff(line: blockNewLine + j, kind: .modified))
                    }
                    for j in 0..<addedCount {
                        diffs.append(GitLineDiff(line: blockNewLine + modifiedCount + j, kind: .added))
                    }
                    if deletions > 0 && additions == 0 {
                        diffs.append(GitLineDiff(line: blockNewLine, kind: .deleted))
                    }

                    newLine = blockNewLine + additions
                } else if hl.hasPrefix("\\") {
                    i += 1
                } else {
                    // Context line
                    newLine += 1
                    i += 1
                }
            }
        }

        return diffs
    }

    nonisolated static func parseHunkNewStart(_ header: String) -> Int? {
        // Format: @@ -old[,count] +new[,count] @@
        guard let plusIndex = header.firstIndex(of: "+") else { return nil }
        let afterPlus = header[header.index(after: plusIndex)...]
        guard let endIndex = afterPlus.firstIndex(where: { $0 == "," || $0 == " " }) else { return nil }
        return Int(afterPlus[..<endIndex])
    }

    // MARK: - Git Command Runner

    /// Default timeout for git commands (30 seconds).
    static let defaultGitTimeout: TimeInterval = 30.0

    nonisolated static func runGit(
        _ arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultGitTimeout
    ) -> (output: String, errorOutput: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            // Schedule a timeout to terminate hung processes
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return (
                String(bytes: outData, encoding: .utf8) ?? "",
                String(bytes: errData, encoding: .utf8) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
