//
//  GitFileRevert.swift
//  Pine
//
//  Reverts individual files to their last-committed (HEAD) state via
//  `git checkout -- <file>`. Agent History no longer calls this helper because
//  path-only whole-file restore is not a safe inverse operation (#1183).
//
//  This is a standalone helper (not an extension on `GitStatusProvider`) so the
//  history store can revert using only a project-root URL, without owning a
//  full status provider. It mirrors `GitCommand`'s low-level style: no state,
//  no business logic beyond the revert, returns structured results.
//

import Foundation

/// Result of reverting a single file: either restored to HEAD or failed.
nonisolated struct GitFileRevertResult: Sendable, Equatable {
    let relativePath: String
    let success: Bool
    let errorOutput: String
}

/// Reverts tracked files to their committed state via `git checkout --`.
nonisolated enum GitFileRevert {

    /// Reverts each path to HEAD inside `repositoryRoot`.
    ///
    /// - Parameters:
    ///   - relativePaths: Paths relative to `repositoryRoot`. Each is validated
    ///     by the caller (`AgentHistoryStore`) to reject path traversal (`..`)
    ///     and absolute paths before reaching here.
    ///   - repositoryRoot: The git working tree to operate in.
    /// - Returns: One `GitFileRevertResult` per path, in input order. A path
    ///   reverts successfully when git exits 0.
    static func revert(relativePaths: [String], in repositoryRoot: URL) -> [GitFileRevertResult] {
        relativePaths.map { path in
            let result = GitCommand.run(["checkout", "--", path], at: repositoryRoot)
            return GitFileRevertResult(
                relativePath: path,
                success: result.exitCode == 0,
                errorOutput: result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
