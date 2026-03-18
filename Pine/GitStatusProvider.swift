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
        let result = runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
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
        refreshBranch(at: url)
        refreshFileStatusesAndIgnored(at: url)
        refreshBranches(at: url)
    }

    // MARK: - Status Queries

    func statusForFile(at url: URL) -> GitFileStatus? {
        let relativePath = relativePath(for: url)
        return relativePath.flatMap { fileStatuses[$0] }
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
        return nil
    }

    // MARK: - Diff for Gutter

    func diffForFile(at url: URL) -> [GitLineDiff] {
        guard isGitRepository, let repoURL = repositoryURL else { return [] }
        // Check if HEAD exists (new repo without commits)
        let headCheck = runGit(["rev-parse", "HEAD"], at: repoURL)
        guard headCheck.exitCode == 0 else { return [] }

        let result = runGit(["diff", "HEAD", "--unified=0", "--", url.path], at: repoURL)
        guard result.exitCode == 0, !result.output.isEmpty else { return [] }
        return parseDiff(result.output)
    }

    // MARK: - Branch Operations

    func checkoutBranch(_ branch: String) -> (success: Bool, error: String) {
        guard let url = repositoryURL else { return (false, "No repository") }
        let result = runGit(["switch", branch], at: url)
        if result.exitCode == 0 {
            refresh()
            return (true, "")
        }
        return (false, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Private Helpers

    private func relativePath(for url: URL) -> String? {
        guard let rootPath = gitRootPath else { return nil }
        let filePath = url.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private func refreshBranch(at url: URL) {
        let result = runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: url)
        if result.exitCode == 0 {
            currentBranch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func refreshFileStatusesAndIgnored(at url: URL) {
        let result = runGit(["status", "--ignored", "--porcelain"], at: url)
        guard result.exitCode == 0 else { return }
        fileStatuses = Self.parseStatusOutput(result.output)
        ignoredPaths = Self.parseIgnoredOutput(result.output)
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

    private func refreshBranches(at url: URL) {
        let result = runGit(["branch", "--sort=-committerdate", "--format=%(refname:short)"], at: url)
        guard result.exitCode == 0 else { return }
        branches = result.output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
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

    private func runGit(_ arguments: [String], at directory: URL) -> (output: String, errorOutput: String, exitCode: Int32) {
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
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
