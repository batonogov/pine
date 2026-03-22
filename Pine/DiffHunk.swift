//
//  DiffHunk.swift
//  Pine
//
//  Models for full git diff output with hunk-level granularity.
//

import Foundation

// MARK: - Diff Line

struct DiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
    }

    let id = UUID()
    let kind: Kind
    let content: String

    static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.content == rhs.content
    }
}

// MARK: - Diff Hunk

struct DiffHunk: Identifiable, Equatable, Sendable {
    let id = UUID()
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let header: String
    let lines: [DiffLine]

    static func == (lhs: DiffHunk, rhs: DiffHunk) -> Bool {
        lhs.oldStart == rhs.oldStart
            && lhs.oldCount == rhs.oldCount
            && lhs.newStart == rhs.newStart
            && lhs.newCount == rhs.newCount
            && lhs.header == rhs.header
            && lhs.lines == rhs.lines
    }
}

// MARK: - Diff File Entry

struct DiffFileEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let relativePath: String
    let status: GitFileStatus
    let hunks: [DiffHunk]
    let isStaged: Bool

    static func == (lhs: DiffFileEntry, rhs: DiffFileEntry) -> Bool {
        lhs.relativePath == rhs.relativePath
            && lhs.status == rhs.status
            && lhs.hunks == rhs.hunks
            && lhs.isStaged == rhs.isStaged
    }
}

// MARK: - Full Diff Parser

extension GitStatusProvider {

    nonisolated static func parseFullDiff(_ output: String) -> [String: [DiffHunk]] {
        guard !output.isEmpty else { return [:] }

        var result: [String: [DiffHunk]] = [:]
        let lines = output.components(separatedBy: "\n")
        var i = 0
        var currentFile: String?

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("diff --git ") {
                currentFile = parseFilePath(from: line)
                i += 1
                while i < lines.count
                    && !lines[i].hasPrefix("@@")
                    && !lines[i].hasPrefix("diff --git ") {
                    i += 1
                }
                continue
            }

            if line.hasPrefix("@@"), let currentFile {
                if let hunk = parseHunk(lines: lines, from: &i) {
                    result[currentFile, default: []].append(hunk)
                }
                continue
            }

            i += 1
        }

        return result
    }

    nonisolated static func parseFilePath(from diffHeader: String) -> String? {
        guard diffHeader.hasPrefix("diff --git ") else { return nil }
        let content = String(diffHeader.dropFirst("diff --git ".count))

        if content.contains("\"") {
            if let range = content.range(of: " b/", options: .backwards) {
                let bPath = String(content[range.upperBound...])
                return unquoteGitPath(bPath)
            }
            let parts = content.components(separatedBy: "\" \"")
            if parts.count == 2 {
                let bPart = parts[1].hasSuffix("\"") ? String(parts[1].dropLast()) : parts[1]
                return unquoteGitPath(bPart.hasPrefix("b/") ? String(bPart.dropFirst(2)) : bPart)
            }
        }

        guard let range = content.range(of: " b/", options: .backwards) else { return nil }
        return String(content[range.upperBound...])
    }

    nonisolated private static func parseHunk(lines: [String], from i: inout Int) -> DiffHunk? {
        let headerLine = lines[i]
        guard let parsed = parseHunkHeader(headerLine) else {
            i += 1
            return nil
        }

        let (oldStart, oldCount, newStart, newCount) = parsed
        i += 1

        var diffLines: [DiffLine] = []

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@") || line.hasPrefix("diff --git ") { break }

            if line.hasPrefix("+") {
                diffLines.append(DiffLine(kind: .added, content: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                diffLines.append(DiffLine(kind: .removed, content: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                diffLines.append(DiffLine(kind: .context, content: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — skip
            } else if line.isEmpty && i == lines.count - 1 {
                // Trailing empty line
            } else {
                break
            }
            i += 1
        }

        return DiffHunk(
            oldStart: oldStart, oldCount: oldCount,
            newStart: newStart, newCount: newCount,
            header: headerLine, lines: diffLines
        )
    }

    nonisolated static func parseHunkHeader(_ header: String) -> (Int, Int, Int, Int)? {
        guard header.hasPrefix("@@") else { return nil }

        let scanner = Scanner(string: header)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")

        guard let oldStart = scanner.scanInt() else { return nil }
        var oldCount = 1
        if scanner.scanString(",") != nil {
            if let count = scanner.scanInt() { oldCount = count }
        }

        _ = scanner.scanString("+")
        guard let newStart = scanner.scanInt() else { return nil }
        var newCount = 1
        if scanner.scanString(",") != nil {
            if let count = scanner.scanInt() { newCount = count }
        }

        return (oldStart, oldCount, newStart, newCount)
    }

    nonisolated static func patchForHunk(_ hunk: DiffHunk, filePath: String) -> String {
        var patch = "--- a/\(filePath)\n"
        patch += "+++ b/\(filePath)\n"
        patch += "\(hunk.header)\n"
        for line in hunk.lines {
            switch line.kind {
            case .context:  patch += " \(line.content)\n"
            case .added:    patch += "+\(line.content)\n"
            case .removed:  patch += "-\(line.content)\n"
            }
        }
        return patch
    }

    // MARK: - Staged/Unstaged Diff

    func stagedDiff() -> [String: [DiffHunk]] {
        guard isGitRepository, let url = repositoryURL else { return [:] }
        let headCheck = Self.runGit(["rev-parse", "HEAD"], at: url)
        let args: [String]
        if headCheck.exitCode == 0 {
            args = ["diff", "--cached"]
        } else {
            args = ["diff", "--cached", "--diff-filter=A"]
        }
        let result = Self.runGit(args, at: url)
        guard result.exitCode == 0 else { return [:] }
        return Self.parseFullDiff(result.output)
    }

    func unstagedDiff() -> [String: [DiffHunk]] {
        guard isGitRepository, let url = repositoryURL else { return [:] }
        let result = Self.runGit(["diff"], at: url)
        guard result.exitCode == 0 else { return [:] }
        return Self.parseFullDiff(result.output)
    }

    // MARK: - Staging Operations

    func stageHunk(_ hunk: DiffHunk, filePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let patch = Self.patchForHunk(hunk, filePath: filePath)
        return applyPatch(patch, arguments: ["apply", "--cached"], at: url)
    }

    func unstageHunk(_ hunk: DiffHunk, filePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let patch = Self.patchForHunk(hunk, filePath: filePath)
        return applyPatch(patch, arguments: ["apply", "--cached", "--reverse"], at: url)
    }

    func discardHunk(_ hunk: DiffHunk, filePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let patch = Self.patchForHunk(hunk, filePath: filePath)
        return applyPatch(patch, arguments: ["apply", "--reverse"], at: url)
    }

    func stageFile(_ relativePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let result = Self.runGit(["add", "--", relativePath], at: url)
        return result.exitCode == 0
    }

    func unstageFile(_ relativePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let result = Self.runGit(["reset", "HEAD", "--", relativePath], at: url)
        return result.exitCode == 0
    }

    func discardFile(_ relativePath: String) -> Bool {
        guard let url = repositoryURL else { return false }
        let result = Self.runGit(["checkout", "--", relativePath], at: url)
        return result.exitCode == 0
    }

    func splitStatuses() -> (staged: [String: GitFileStatus], unstaged: [String: GitFileStatus]) {
        guard isGitRepository, let url = repositoryURL else { return ([:], [:]) }
        let result = Self.runGit(["--no-optional-locks", "status", "--porcelain"], at: url)
        guard result.exitCode == 0 else { return ([:], [:]) }

        var staged: [String: GitFileStatus] = [:]
        var unstaged: [String: GitFileStatus] = [:]

        for line in result.output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            let indexChar = line[line.startIndex]
            let workTreeChar = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            path = Self.unquoteGitPath(path)

            if path.contains(" -> ") {
                let parts = path.components(separatedBy: " -> ")
                if parts.count == 2 { path = parts[1] }
            }

            switch indexChar {
            case "M": staged[path] = .modified
            case "A": staged[path] = .added
            case "D": staged[path] = .deleted
            case "R": staged[path] = .staged
            default: break
            }

            switch workTreeChar {
            case "M": unstaged[path] = .modified
            case "D": unstaged[path] = .deleted
            case "?":
                if indexChar == "?" { unstaged[path] = .untracked }
            default: break
            }
        }

        return (staged, unstaged)
    }

    // MARK: - Private Helpers

    private func applyPatch(_ patch: String, arguments: [String], at directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + Self.defaultGitTimeout)
            timer.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            timer.resume()

            if let data = patch.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            inPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            timer.cancel()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
