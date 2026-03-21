//
//  GitDiffHunk.swift
//  Pine
//
//  Data models for the git diff panel: individual diff lines, hunks, and per-file diffs.
//

import Foundation

// MARK: - GitDiffLine

/// A single line within a diff hunk, with its kind and content.
struct GitDiffLine: Equatable {
    enum Kind: Equatable { case context, added, deleted }

    let kind: Kind
    /// Line content without the leading `+`, `-`, or space prefix.
    let content: String
    /// 1-based line number in the old (pre-change) file. `nil` for added lines.
    let oldLineNumber: Int?
    /// 1-based line number in the new (post-change) file. `nil` for deleted lines.
    let newLineNumber: Int?

    /// The raw diff line including its leading prefix character.
    var rawLine: String {
        switch kind {
        case .context: return " " + content
        case .added:   return "+" + content
        case .deleted: return "-" + content
        }
    }
}

// MARK: - GitDiffHunk

/// A contiguous block of diff lines bounded by a `@@ … @@` header.
struct GitDiffHunk: Identifiable, Equatable {
    let id: UUID
    /// Full `@@ -old,count +new,count @@` header line (may include trailing context text).
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// Parsed content lines (context, added, deleted).
    let lines: [GitDiffLine]
    /// Repo-relative file path this hunk belongs to (e.g. `"Sources/Foo.swift"`).
    let filePath: String

    init(
        id: UUID = UUID(),
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [GitDiffLine],
        filePath: String
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.filePath = filePath
    }

    /// Builds a minimal unified patch string suitable for `git apply [--cached] [--reverse]`.
    func buildPatch() -> String {
        var result = ""
        result += "diff --git a/\(filePath) b/\(filePath)\n"
        result += "--- a/\(filePath)\n"
        result += "+++ b/\(filePath)\n"
        result += header + "\n"
        for line in lines {
            result += line.rawLine + "\n"
        }
        return result
    }
}

// MARK: - GitFileDiff

/// All hunks for a single file, together with staging state and git status.
struct GitFileDiff: Identifiable, Equatable {
    let id: UUID
    /// Repo-relative path (e.g. `"Sources/Foo.swift"`).
    let filePath: String
    /// `true` when these hunks come from the staged index diff (`git diff --cached`).
    let isStaged: Bool
    let status: GitFileStatus
    let hunks: [GitDiffHunk]

    init(
        id: UUID = UUID(),
        filePath: String,
        isStaged: Bool,
        status: GitFileStatus,
        hunks: [GitDiffHunk]
    ) {
        self.id = id
        self.filePath = filePath
        self.isStaged = isStaged
        self.status = status
        self.hunks = hunks
    }

    /// Display name (last path component).
    var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }
}
