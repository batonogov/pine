//
//  InlineDiffProvider.swift
//  Pine
//
//  Parses git diff hunks for individual files and provides
//  accept (stage) / revert (checkout) operations per hunk.
//

import Foundation

// MARK: - InlineDiffAction

/// Type-safe actions for inline diff operations.
enum InlineDiffAction: String, Sendable {
    case accept
    case revert
    case acceptAll
    case revertAll
}

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

    /// Extracts deleted lines (prefixed with `-`) from rawText, stripping the prefix.
    var deletedLines: [String] {
        rawText.components(separatedBy: "\n")
            .filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
            .map { String($0.dropFirst()) }
    }

    /// Extracts added lines (prefixed with `+`) from rawText, stripping the prefix.
    var addedLines: [String] {
        rawText.components(separatedBy: "\n")
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .map { String($0.dropFirst()) }
    }
}

// MARK: - Inline diff highlight models

/// Describes the kind of highlight for a line in the inline diff view.
enum DiffLineKind: Equatable, Sendable {
    /// A line that was added (exists in the editor) — shown with green background.
    case added
    /// A line that was deleted (phantom, not in the editor) — shown with red background.
    case deleted
}

/// A single line to highlight in the inline diff view.
struct DiffHighlightLine: Equatable, Sendable {
    /// The kind of diff highlight.
    let kind: DiffLineKind
    /// For `.added`: the 1-based editor line number.
    /// For `.deleted`: not used directly (deleted lines are grouped by hunk).
    let editorLine: Int
}

/// A group of deleted lines that should be rendered as phantom text above a given editor line.
struct DeletedLinesBlock: Equatable, Sendable {
    /// The 1-based editor line above which (or at which) these deleted lines should be drawn.
    let anchorLine: Int
    /// The deleted line contents (without the `-` prefix).
    let lines: [String]
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
        guard header.count > 4 else { return nil }
        let searchStart = header.index(header.startIndex, offsetBy: 2)
        guard let atRange = header.range(of: "@@", range: searchStart..<header.endIndex) else {
            return nil
        }
        let innerStart = header.index(header.startIndex, offsetBy: 3)
        guard innerStart < atRange.lowerBound else { return nil }
        let inner = String(header[innerStart..<atRange.lowerBound]).trimmingCharacters(in: .whitespaces)
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
    /// Returns nil if either component is not a valid integer.
    private static func parseSidePart(_ str: String) -> (start: Int, count: Int)? {
        let comps = str.split(separator: ",")
        guard let start = Int(comps[0]) else { return nil }
        if comps.count > 1 {
            guard let count = Int(comps[1]) else { return nil }
            return (start, count)
        }
        return (start, 1)
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

    // MARK: - Hunk navigation (toolbar)

    /// Returns the next hunk after the given one, wrapping around to the first.
    /// Returns nil if the hunks array is empty.
    /// If the current hunk is not found (stale), returns the first hunk.
    static func nextHunk(after current: DiffHunk, in hunks: [DiffHunk]) -> DiffHunk? {
        guard !hunks.isEmpty else { return nil }
        guard let index = hunks.firstIndex(where: { $0.id == current.id }) else {
            return hunks.first
        }
        return hunks[(index + 1) % hunks.count]
    }

    /// Returns the previous hunk before the given one, wrapping around to the last.
    /// Returns nil if the hunks array is empty.
    /// If the current hunk is not found (stale), returns the last hunk.
    static func previousHunk(before current: DiffHunk, in hunks: [DiffHunk]) -> DiffHunk? {
        guard !hunks.isEmpty else { return nil }
        guard let index = hunks.firstIndex(where: { $0.id == current.id }) else {
            return hunks.last
        }
        return hunks[(index - 1 + hunks.count) % hunks.count]
    }

    /// Returns the 1-based position and total count for a hunk in the list.
    /// Returns nil if the hunk is not found.
    static func hunkPositionInfo(for hunk: DiffHunk, in hunks: [DiffHunk]) -> (index: Int, total: Int)? {
        guard let idx = hunks.firstIndex(where: { $0.id == hunk.id }) else { return nil }
        return (idx + 1, hunks.count)
    }

    /// Returns a short summary string for a hunk (e.g. "+3 -2" or "+1").
    static func hunkSummary(_ hunk: DiffHunk) -> String {
        let added = hunk.addedLines.count
        let deleted = hunk.deletedLines.count
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if deleted > 0 { parts.append("-\(deleted)") }
        return parts.joined(separator: " ")
    }

    /// Returns the line range covered by a hunk in the editor (1-based, inclusive).
    /// For pure deletion hunks (newCount == 0), returns just the anchor line.
    static func expandedLineRange(for hunk: DiffHunk) -> ClosedRange<Int> {
        if hunk.newCount == 0 {
            return hunk.newStart...hunk.newStart
        }
        return hunk.newStart...hunk.newEndLine
    }

    // MARK: - Hunk classification

    /// Returns `true` when the hunk represents a modification (has both deleted and added lines).
    /// Modified hunks should NOT render phantom overlay — only green background on added lines
    /// and a yellow gutter marker. The old content is not shown as overlay text (#681).
    static func isModifiedHunk(_ hunk: DiffHunk) -> Bool {
        !hunk.deletedLines.isEmpty && !hunk.addedLines.isEmpty
    }

    // MARK: - Highlight computation

    /// Computes which editor lines should have added (green) backgrounds based on diff hunks.
    /// Returns a set of 1-based line numbers that are added lines.
    static func addedLineNumbers(from hunks: [DiffHunk]) -> Set<Int> {
        var result = Set<Int>()
        for hunk in hunks {
            let lines = hunk.rawText.components(separatedBy: "\n")
            // Track the current new-side line number
            var newLine = hunk.newStart
            for line in lines where !line.hasPrefix("@@") {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    result.insert(newLine)
                    newLine += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    // Deleted lines don't increment the new-side counter
                    continue
                } else {
                    // Context line
                    newLine += 1
                }
            }
        }
        return result
    }

    /// Computes blocks of deleted lines from hunks, each anchored to an editor line.
    /// The anchor line is the first added/context line after the deletion, or the hunk's newStart
    /// for pure deletion hunks.
    /// Modified hunks (with both deleted and added lines) are skipped — they use only
    /// yellow gutter markers and green added-line backgrounds, no phantom overlay (#681).
    static func deletedLineBlocks(from hunks: [DiffHunk]) -> [DeletedLinesBlock] {
        var blocks: [DeletedLinesBlock] = []
        for hunk in hunks {
            // Skip modified hunks — no phantom overlay for modifications (#681)
            guard !isModifiedHunk(hunk) else { continue }
            let deleted = hunk.deletedLines
            guard !deleted.isEmpty else { continue }
            // Anchor: the hunk's newStart line in the editor
            blocks.append(DeletedLinesBlock(anchorLine: hunk.newStart, lines: deleted))
        }
        return blocks
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
                    ["diff", "HEAD", "--unified=1", "--", fileURL.path],
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

        var patch = """
        diff --git a/\(relativePath) b/\(relativePath)
        --- a/\(relativePath)
        +++ b/\(relativePath)
        \(hunk.rawText)
        """
        // git apply requires a trailing newline
        if !patch.hasSuffix("\n") {
            patch.append("\n")
        }
        return patch
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
