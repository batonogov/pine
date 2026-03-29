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
enum GitDiffLineKind: Equatable {
    case context
    case added
    case removed
    case hunkHeader
}

struct GitDiffLine: Equatable, Identifiable {
    let id = UUID()
    let kind: GitDiffLineKind
    let text: String

    static func == (lhs: GitDiffLine, rhs: GitDiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}

/// A contiguous hunk of changes within a file diff.
struct GitDiffHunk: Equatable, Identifiable {
    let id = UUID()
    let header: String
    let lines: [GitDiffLine]

    static func == (lhs: GitDiffHunk, rhs: GitDiffHunk) -> Bool {
        lhs.header == rhs.header && lhs.lines == rhs.lines
    }
}

/// A complete diff for a single file.
struct GitFileDiff: Equatable, Identifiable {
    let id = UUID()
    let filePath: String
    let hunks: [GitDiffHunk]
    /// Whether this diff represents staged (cached) changes.
    let isStaged: Bool

    static func == (lhs: GitFileDiff, rhs: GitFileDiff) -> Bool {
        lhs.filePath == rhs.filePath && lhs.hunks == rhs.hunks && lhs.isStaged == rhs.isStaged
    }
}

// MARK: - GitDiffProvider

@Observable
final class GitDiffProvider {
    var stagedFiles: [GitFileDiff] = []
    var unstagedFiles: [GitFileDiff] = []

    /// True when a refresh is in progress.
    var isRefreshing: Bool = false

    /// Generation token to prevent stale async results from overwriting newer ones.
    private var refreshGeneration: Int = 0

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

        refreshGeneration += 1
        let currentGeneration = refreshGeneration

        await MainActor.run { self.isRefreshing = true }

        let (staged, unstaged) = await runGitAsync {
            let stagedResult = GitStatusProvider.runGit(["diff", "--cached"], at: repositoryURL)
            let unstagedResult = GitStatusProvider.runGit(["diff"], at: repositoryURL)

            let stagedDiffs = Self.parseUnifiedDiff(stagedResult.output, isStaged: true)
            let unstagedDiffs = Self.parseUnifiedDiff(unstagedResult.output, isStaged: false)

            return (stagedDiffs, unstagedDiffs)
        }

        await MainActor.run {
            // Only apply if this is still the latest refresh
            guard self.refreshGeneration == currentGeneration else { return }
            self.stagedFiles = staged
            self.unstagedFiles = unstaged
            self.isRefreshing = false
        }
    }

    // MARK: - Async Git Helper

    /// Runs a closure on a background queue and returns the result via `withCheckedContinuation`.
    /// Internal for testability — used by unit tests to verify background dispatch behavior.
    func runGitAsync<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Stage / Unstage

    /// Stages a single file.
    func stageFile(_ path: String, at repositoryURL: URL) async -> Bool {
        await runGitAsync {
            GitStatusProvider.runGit(["add", "--", path], at: repositoryURL).exitCode == 0
        }
    }

    /// Unstages a single file (moves from staged back to working tree).
    func unstageFile(_ path: String, at repositoryURL: URL) async -> Bool {
        await runGitAsync {
            GitStatusProvider.runGit(["reset", "HEAD", "--", path], at: repositoryURL).exitCode == 0
        }
    }

    /// Discards unstaged changes for a single file.
    func discardChanges(_ path: String, at repositoryURL: URL) async -> Bool {
        await runGitAsync {
            GitStatusProvider.runGit(["checkout", "--", path], at: repositoryURL).exitCode == 0
        }
    }

    /// Stages all changed files.
    func stageAll(at repositoryURL: URL) async -> Bool {
        await runGitAsync {
            GitStatusProvider.runGit(["add", "-A"], at: repositoryURL).exitCode == 0
        }
    }

    /// Unstages all staged files.
    func unstageAll(at repositoryURL: URL) async -> Bool {
        await runGitAsync {
            GitStatusProvider.runGit(["reset", "HEAD"], at: repositoryURL).exitCode == 0
        }
    }

    // MARK: - Unified Diff Parser

    /// Parses unified diff output into per-file `GitFileDiff` structures.
    static func parseUnifiedDiff(_ output: String, isStaged: Bool) -> [GitFileDiff] {
        guard !output.isEmpty else { return [] }

        var fileDiffs: [GitFileDiff] = []
        let lines = output.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            // Find "diff --git a/... b/..."
            guard lines[i].hasPrefix("diff --git ") else {
                i += 1
                continue
            }

            let fallbackPath = parseFilePath(from: lines[i])
            i += 1

            // Scan metadata lines (index, ---, +++) and extract path from +++ b/
            var filePath = fallbackPath
            while i < lines.count
                && !lines[i].hasPrefix("diff --git ")
                && !lines[i].hasPrefix("@@") {
                if lines[i].hasPrefix("+++ b/") {
                    filePath = String(lines[i].dropFirst("+++ b/".count))
                } else if lines[i].hasPrefix("+++ /dev/null") {
                    // Deleted file — use --- a/ path
                } else if lines[i].hasPrefix("--- a/") && filePath == fallbackPath {
                    filePath = String(lines[i].dropFirst("--- a/".count))
                }
                i += 1
            }

            // Parse hunks
            var hunks: [GitDiffHunk] = []
            while i < lines.count && !lines[i].hasPrefix("diff --git ") {
                if lines[i].hasPrefix("@@") {
                    let header = lines[i]
                    i += 1

                    var hunkLines: [GitDiffLine] = []
                    while i < lines.count
                        && !lines[i].hasPrefix("@@")
                        && !lines[i].hasPrefix("diff --git ") {
                        let line = lines[i]
                        let kind: GitDiffLineKind
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

                        hunkLines.append(GitDiffLine(kind: kind, text: text))
                        i += 1
                    }

                    hunks.append(GitDiffHunk(header: header, lines: hunkLines))
                } else {
                    i += 1
                }
            }

            if !hunks.isEmpty {
                fileDiffs.append(GitFileDiff(filePath: filePath, hunks: hunks, isStaged: isStaged))
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
