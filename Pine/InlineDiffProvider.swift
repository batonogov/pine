//
//  InlineDiffProvider.swift
//  Pine
//
//  Parses git diff hunks for individual files and provides
//  accept (stage) / revert (checkout) operations per hunk.
//

import Foundation

// MARK: - Models

/// A single diff hunk with enough context to stage or revert it.
struct DiffHunk: Equatable, Sendable, Identifiable {
    let id: UUID
    /// 1-based start line in the new file (what the editor shows).
    let newStart: Int
    /// Number of lines in the new side of the hunk.
    let newCount: Int
    /// 1-based start line in the old file.
    let oldStart: Int
    /// Number of lines in the old side of the hunk.
    let oldCount: Int
    /// Raw hunk text including the @@ header and all +/-/context lines.
    let rawText: String

    init(newStart: Int, newCount: Int, oldStart: Int, oldCount: Int, rawText: String) {
        self.id = UUID()
        self.newStart = newStart
        self.newCount = newCount
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.rawText = rawText
    }

    /// The last line in the new file that this hunk covers (1-based, inclusive).
    var newEndLine: Int {
        newCount > 0 ? newStart + newCount - 1 : newStart
    }
}

// MARK: - InlineDiffProvider

/// Provides diff hunk parsing and accept/revert operations for editor files.
enum InlineDiffProvider {

    // MARK: - Hunk parsing

    /// Parses `git diff` output into an array of DiffHunk structs.
    /// Expects standard unified diff format.
    static func parseHunks(_ diffOutput: String) -> [DiffHunk] {
        guard !diffOutput.isEmpty else { return [] }

        let lines = diffOutput.components(separatedBy: "\n")
        var hunks: [DiffHunk] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            guard line.hasPrefix("@@") else {
                i += 1
                continue
            }

            // Parse @@ -old[,count] +new[,count] @@
            guard let header = parseHunkHeader(line) else {
                i += 1
                continue
            }

            // Collect all lines belonging to this hunk
            var hunkLines = [line]
            i += 1

            while i < lines.count
                && !lines[i].hasPrefix("@@")
                && !lines[i].hasPrefix("diff ") {
                hunkLines.append(lines[i])
                i += 1
            }

            // Trim trailing empty lines
            while let last = hunkLines.last, last.isEmpty {
                hunkLines.removeLast()
            }

            let rawText = hunkLines.joined(separator: "\n")
            hunks.append(DiffHunk(
                newStart: header.newStart,
                newCount: header.newCount,
                oldStart: header.oldStart,
                oldCount: header.oldCount,
                rawText: rawText
            ))
        }

        return hunks
    }

    /// Parses the @@ header line into old/new start and count.
    static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // Format: @@ -old[,count] +new[,count] @@
        // Example: @@ -10,5 +12,7 @@ func foo()
        guard let atRange = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) else {
            return nil
        }
        let inner = String(header[header.index(header.startIndex, offsetBy: 3)..<atRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let parts = inner.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let oldPart = String(parts[0]) // e.g. "-10,5"
        let newPart = String(parts[1]) // e.g. "+12,7"

        guard oldPart.hasPrefix("-"), newPart.hasPrefix("+") else { return nil }

        let oldValues = parseSidePart(String(oldPart.dropFirst()))
        let newValues = parseSidePart(String(newPart.dropFirst()))

        guard let old = oldValues, let new = newValues else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    /// Parses "start,count" or "start" into (start, count).
    private static func parseSidePart(_ str: String) -> (start: Int, count: Int)? {
        let comps = str.split(separator: ",")
        guard let start = Int(comps[0]) else { return nil }
        let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
        return (start, count)
    }

    // MARK: - Hunk lookup

    /// Returns the hunk that covers the given editor line (1-based), or nil.
    static func hunk(atLine line: Int, in hunks: [DiffHunk]) -> DiffHunk? {
        hunks.first { hunk in
            if hunk.newCount == 0 {
                // Pure deletion — marker sits at the line after the deletion point
                return line == hunk.newStart
            }
            return line >= hunk.newStart && line <= hunk.newEndLine
        }
    }

    /// Returns the hunk closest to the given line for navigation.
    /// If the cursor is inside a hunk, returns that hunk.
    /// Otherwise returns the nearest hunk in the given direction.
    static func nearestHunk(atLine line: Int, direction: NavigationDirection, in hunks: [DiffHunk]) -> DiffHunk? {
        // Check if cursor is inside a hunk
        if let current = hunk(atLine: line, in: hunks) {
            return current
        }

        switch direction {
        case .next:
            return hunks.first { $0.newStart > line }
                ?? hunks.first // wrap
        case .previous:
            return hunks.last { $0.newStart < line }
                ?? hunks.last // wrap
        }
    }

    enum NavigationDirection {
        case next, previous
    }

    // MARK: - Fetch hunks for file

    /// Fetches diff hunks for a file asynchronously.
    /// Returns full `git diff HEAD` output parsed into hunks.
    static func fetchHunks(for fileURL: URL, repoURL: URL) async -> [DiffHunk] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let headCheck = GitStatusProvider.runGit(["rev-parse", "HEAD"], at: repoURL)
                guard headCheck.exitCode == 0 else {
                    continuation.resume(returning: [])
                    return
                }
                let result = GitStatusProvider.runGit(
                    ["diff", "HEAD", "--unified=0", "--", fileURL.path],
                    at: repoURL
                )
                guard result.exitCode == 0, !result.output.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: parseHunks(result.output))
            }
        }
    }

    // MARK: - Accept (stage) a hunk

    /// Stages a specific hunk by applying it with `git apply --cached`.
    /// The hunk patch is created from the raw diff text.
    @discardableResult
    static func acceptHunk(_ hunk: DiffHunk, fileURL: URL, repoURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Build a minimal patch from the hunk
                let patch = buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)
                guard !patch.isEmpty else {
                    continuation.resume(returning: false)
                    return
                }
                let result = applyPatch(patch, args: ["apply", "--cached", "-"], at: repoURL)
                continuation.resume(returning: result)
            }
        }
    }

    /// Stages all hunks for a file (equivalent to `git add <file>`).
    @discardableResult
    static func acceptAllHunks(fileURL: URL, repoURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.runGit(["add", "--", fileURL.path], at: repoURL)
                continuation.resume(returning: result.exitCode == 0)
            }
        }
    }

    // MARK: - Revert a hunk

    /// Reverts a specific hunk by applying the reverse with `git apply --reverse`.
    /// Returns the new file content after reverting, or nil on failure.
    static func revertHunk(_ hunk: DiffHunk, fileURL: URL, repoURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let patch = buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)
                guard !patch.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let success = applyPatch(patch, args: ["apply", "--reverse", "-"], at: repoURL)
                guard success else {
                    continuation.resume(returning: nil)
                    return
                }
                // Read updated file content
                let content = try? String(contentsOf: fileURL, encoding: .utf8)
                continuation.resume(returning: content)
            }
        }
    }

    /// Reverts all changes in a file (equivalent to `git checkout HEAD -- <file>`).
    static func revertAllHunks(fileURL: URL, repoURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.runGit(
                    ["checkout", "HEAD", "--", fileURL.path],
                    at: repoURL
                )
                guard result.exitCode == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let content = try? String(contentsOf: fileURL, encoding: .utf8)
                continuation.resume(returning: content)
            }
        }
    }

    // MARK: - Patch building

    /// Builds a minimal unified diff patch for a single hunk, suitable for `git apply`.
    static func buildPatch(hunk: DiffHunk, fileURL: URL, repoURL: URL) -> String {
        // Get the relative path for the diff header
        let repoPath = repoURL.path
        let filePath = fileURL.path
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        let relativePath: String
        if filePath.hasPrefix(prefix) {
            relativePath = String(filePath.dropFirst(prefix.count))
        } else {
            relativePath = fileURL.lastPathComponent
        }

        return """
        diff --git a/\(relativePath) b/\(relativePath)
        --- a/\(relativePath)
        +++ b/\(relativePath)
        \(hunk.rawText)
        """
    }

    /// Pipes a patch string into a git command via stdin.
    private static func applyPatch(_ patch: String, args: [String], at repoURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repoURL

        let inputPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = Pipe() // discard
        process.standardError = errPipe

        do {
            try process.run()
            if let data = patch.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
