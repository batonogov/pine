//
//  AgentHistoryContentHash.swift
//  Pine
//
//  Pure hashing helpers for the checked Agent History undo engine (#1183).
//  Uses CryptoKit (system framework, no added dependency). All functions are
//  `nonisolated` so they cross the `@MainActor` store boundary freely.
//

import CryptoKit
import Darwin
import Foundation

/// Lowercase-hex SHA-256 helpers shared by the capture path, the private
/// store integrity checks, and the runtime divergence check.
nonisolated enum AgentHistoryContentHash {
    /// SHA-256 of raw bytes as a 64-character lowercase-hex string.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file's exact bytes without text decoding or newline
    /// normalization. Returns `nil` when the path is not a readable file (the
    /// caller treats that as divergence).
    static func sha256OfFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }

    /// SHA-256 of the `.git/index` file inside `repositoryRoot`, or the empty
    /// string when no index exists. Used to detect any staging change since a
    /// verified change set was captured.
    static func indexSHA256(in repositoryRoot: URL) -> String {
        // `git rev-parse --git-path index` is the canonical index location,
        // including for linked worktrees. Git may return either a relative path
        // (`.git/index`) or an absolute path into the common repository's
        // `worktrees/<name>/index` directory.
        let indexResult = GitCommand.run(
            ["rev-parse", "--git-path", "index"],
            at: repositoryRoot
        )
        let raw = indexResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var indexURL: URL
        if indexResult.exitCode == 0, !raw.isEmpty {
            indexURL = URL(
                fileURLWithPath: raw,
                relativeTo: repositoryRoot
            ).standardizedFileURL
        } else {
            indexURL = repositoryRoot
                .appendingPathComponent(".git", isDirectory: true)
                .appendingPathComponent("index", isDirectory: false)
        }
        if let data = try? Data(contentsOf: indexURL) {
            return sha256Hex(data)
        }
        // Fallback to the common main-worktree index location.
        let fallback = repositoryRoot
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("index", isDirectory: false)
        if let data = try? Data(contentsOf: fallback) {
            return sha256Hex(data)
        }
        return ""
    }

    /// Current HEAD object ID (`git rev-parse HEAD`), or the empty string when
    /// the repository has no commits yet.
    static func headOID(in repositoryRoot: URL) -> String {
        let result = GitCommand.run(["rev-parse", "HEAD"], at: repositoryRoot)
        guard result.exitCode == 0 else { return "" }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Canonical (symlink-resolved) absolute path string for a root URL.
    static func canonicalRootPath(_ root: URL) -> String {
        // Foundation preserves the synthetic `/var` spelling on macOS even
        // though it is a symlink to `/private/var`. Persist the physical path
        // so later descriptor-relative recovery can reject every symlink
        // component without rejecting otherwise valid temporary roots.
        guard let resolved = realpath(root.path, nil) else {
            return root.resolvingSymlinksInPath().path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Device/inode identity of the canonical root directory, opened without
    /// following a link at the final component.
    static func rootIdentity(_ root: URL) -> (device: UInt64, inode: UInt64)? {
        let canonicalPath = canonicalRootPath(root)
        let descriptor = open(
            canonicalPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }
}
