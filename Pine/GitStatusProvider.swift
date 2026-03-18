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

    /// Runs refresh on a background queue with parallel fetches, then assigns results on main.
    func refreshAsync() {
        guard isGitRepository, let url = repositoryURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
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

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentBranch = branch
                self.fileStatuses = statuses
                self.ignoredPaths = ignored
                self.branches = branchList
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
        return parseDiff(result.output)
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

    // MARK: - Diff Parser

    func parseDiff(_ diffOutput: String) -> [GitLineDiff] {
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

    func parseHunkNewStart(_ header: String) -> Int? {
        // Format: @@ -old[,count] +new[,count] @@
        guard let plusIndex = header.firstIndex(of: "+") else { return nil }
        let afterPlus = header[header.index(after: plusIndex)...]
        guard let endIndex = afterPlus.firstIndex(where: { $0 == "," || $0 == " " }) else { return nil }
        return Int(afterPlus[..<endIndex])
    }

    // MARK: - Git Command Runner

    static func runGit(_ arguments: [String], at directory: URL) -> (output: String, errorOutput: String, exitCode: Int32) {
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
            process.waitUntilExit()
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
