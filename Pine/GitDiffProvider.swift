//
//  GitDiffProvider.swift
//  Pine
//
//  Parses `git diff` and `git diff --cached` to provide staged/unstaged
//  file-level diffs for the Git Changes panel.
//

import Foundation

// MARK: - Models

/// A single line in a unified diff.
enum DiffLineKind: Equatable {
    case context
    case added
    case removed
    case hunkHeader
}

struct DiffLine: Equatable, Identifiable {
    let id = UUID()
    let kind: DiffLineKind
    let text: String
}

/// A contiguous hunk of changes within a file diff.
struct DiffHunk: Equatable, Identifiable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]

    static func == (lhs: DiffHunk, rhs: DiffHunk) -> Bool {
        lhs.header == rhs.header && lhs.lines == rhs.lines
    }
}

/// A complete diff for a single file.
struct FileDiff: Equatable, Identifiable {
    let id = UUID()
    let filePath: String
    let hunks: [DiffHunk]
    /// Whether this diff represents staged (cached) changes.
    let isStaged: Bool

    static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
        lhs.filePath == rhs.filePath && lhs.hunks == rhs.hunks && lhs.isStaged == rhs.isStaged
    }
}

// MARK: - GitDiffProvider

@Observable
final class GitDiffProvider {
    var stagedFiles: [FileDiff] = []
    var unstagedFiles: [FileDiff] = []

    /// True when a refresh is in progress.
    var isRefreshing: Bool = false

    /// All changed file paths (both staged and unstaged).
    var allChangedPaths: [String] {
        let staged = Set(stagedFiles.map(\.filePath))
        let unstaged = Set(unstagedFiles.map(\.filePath))
        return Array(staged.union(unstaged)).sorted()
    }

    // MARK: - Refresh

    /// Refreshes both staged and unstaged diffs from the repository.
    func refresh(at repositoryURL: URL) async {
        guard GitStatusProvider.runGit(["rev-parse", "--git-dir"], at: repositoryURL).exitCode == 0 else {
            await MainActor.run {
                self.stagedFiles = []
                self.unstagedFiles = []
            }
            return
        }

        await MainActor.run { self.isRefreshing = true }

        let (staged, unstaged) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let stagedResult = GitStatusProvider.runGit(["diff", "--cached"], at: repositoryURL)
                let unstagedResult = GitStatusProvider.runGit(["diff"], at: repositoryURL)

                let stagedDiffs = Self.parseUnifiedDiff(stagedResult.output, isStaged: true)
                let unstagedDiffs = Self.parseUnifiedDiff(unstagedResult.output, isStaged: false)

                continuation.resume(returning: (stagedDiffs, unstagedDiffs))
            }
        }

        await MainActor.run {
            self.stagedFiles = staged
            self.unstagedFiles = unstaged
            self.isRefreshing = false
        }
    }

    // MARK: - Stage / Unstage

    /// Stages a single file.
    func stageFile(_ path: String, at repositoryURL: URL) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = GitStatusProvider.runGit(["add", "--", path], at: repositoryURL)
                continuation.resume(returning: gitResult.exitCode == 0)
            }
        }
        return result
    }

    /// Unstages a single file (moves from staged back to working tree).
    func unstageFile(_ path: String, at repositoryURL: URL) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = GitStatusProvider.runGit(["reset", "HEAD", "--", path], at: repositoryURL)
                continuation.resume(returning: gitResult.exitCode == 0)
            }
        }
        return result
    }

    /// Discards unstaged changes for a single file.
    func discardChanges(_ path: String, at repositoryURL: URL) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = GitStatusProvider.runGit(["checkout", "--", path], at: repositoryURL)
                continuation.resume(returning: gitResult.exitCode == 0)
            }
        }
        return result
    }

    /// Stages all changed files.
    func stageAll(at repositoryURL: URL) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = GitStatusProvider.runGit(["add", "-A"], at: repositoryURL)
                continuation.resume(returning: gitResult.exitCode == 0)
            }
        }
        return result
    }

    /// Unstages all staged files.
    func unstageAll(at repositoryURL: URL) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let gitResult = GitStatusProvider.runGit(["reset", "HEAD"], at: repositoryURL)
                continuation.resume(returning: gitResult.exitCode == 0)
            }
        }
        return result
    }

    // MARK: - Unified Diff Parser

    /// Parses unified diff output into per-file `FileDiff` structures.
    static func parseUnifiedDiff(_ output: String, isStaged: Bool) -> [FileDiff] {
        guard !output.isEmpty else { return [] }

        var fileDiffs: [FileDiff] = []
        let lines = output.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            // Find "diff --git a/... b/..."
            guard lines[i].hasPrefix("diff --git ") else {
                i += 1
                continue
            }

            let filePath = parseFilePath(from: lines[i])
            i += 1

            // Skip metadata lines (index, ---, +++)
            while i < lines.count
                && !lines[i].hasPrefix("diff --git ")
                && !lines[i].hasPrefix("@@") {
                i += 1
            }

            // Parse hunks
            var hunks: [DiffHunk] = []
            while i < lines.count && !lines[i].hasPrefix("diff --git ") {
                if lines[i].hasPrefix("@@") {
                    let header = lines[i]
                    i += 1

                    var hunkLines: [DiffLine] = []
                    while i < lines.count
                        && !lines[i].hasPrefix("@@")
                        && !lines[i].hasPrefix("diff --git ") {
                        let line = lines[i]
                        let kind: DiffLineKind
                        let text: String

                        if line.hasPrefix("+") {
                            kind = .added
                            text = String(line.dropFirst())
                        } else if line.hasPrefix("-") {
                            kind = .removed
                            text = String(line.dropFirst())
                        } else if line.hasPrefix("\\") {
                            // "\ No newline at end of file"
                            i += 1
                            continue
                        } else {
                            kind = .context
                            text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                        }

                        hunkLines.append(DiffLine(kind: kind, text: text))
                        i += 1
                    }

                    hunks.append(DiffHunk(header: header, lines: hunkLines))
                } else {
                    i += 1
                }
            }

            if !hunks.isEmpty {
                fileDiffs.append(FileDiff(filePath: filePath, hunks: hunks, isStaged: isStaged))
            }
        }

        return fileDiffs
    }

    /// Extracts the file path from a "diff --git a/path b/path" line.
    static func parseFilePath(from diffLine: String) -> String {
        // Format: "diff --git a/some/path b/some/path"
        let parts = diffLine.components(separatedBy: " b/")
        guard parts.count >= 2 else {
            // Fallback: try after "a/"
            let afterA = diffLine.components(separatedBy: " a/")
            if afterA.count >= 2 {
                return afterA[1].components(separatedBy: " b/").first ?? diffLine
            }
            return diffLine
        }
        return parts.last ?? diffLine
    }
}
