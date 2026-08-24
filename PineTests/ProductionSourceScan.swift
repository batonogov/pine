//
//  ProductionSourceScan.swift
//  PineTests
//
//  One correct way to enumerate production sources from a test (#1508).
//

import Foundation

/// Finds the production Swift files a repository-scanning guard reads.
///
/// Guards that scan the tree — "no application-modal calls", "every key is in
/// the catalog", "no destructive shortcut" — are only as good as the file list
/// they start from. Two ways of getting that list wrong make such a guard pass
/// while checking nothing, and both are silent:
///
/// - `FileManager.DirectoryEnumerationOptions.skipsHiddenFiles` drops every
///   item carrying the `UF_HIDDEN` filesystem flag, and in an agent worktree
///   under `.claude/worktrees/…` that flag is set on the files themselves —
///   measured in one such checkout: 183 of 184 entries in `Pine/` are flagged
///   hidden, and the enumeration returns **zero** `.swift` files while the
///   same scan of the primary checkout returns 324. That is #1508: the
///   localization completeness test was green everywhere it was looked at and
///   vacuous everywhere it actually ran.
///
///   (The flag is what matters, not the dotted ancestor name: a directory
///   literally named `.claude/worktrees/wt/Sources` created without the flag
///   enumerates normally.)
/// - a moved or renamed directory produces an empty enumeration rather than an
///   error.
///
/// So this type never passes `.skipsHiddenFiles` — it excludes hidden files by
/// name instead, which is a property of the repository rather than of where the
/// repository happens to be checked out — and it refuses to return an empty
/// list. A completeness guard that finds no inputs must fail, not pass,
/// whatever the reason.
enum ProductionSourceScan {
    struct EmptyScanError: Error, CustomStringConvertible {
        let root: URL

        var description: String {
            """
            No Swift sources found under \(root.path). A guard that scans the \
            repository cannot pass on an empty scan — check the path, and do \
            not use .skipsHiddenFiles (every file in an agent worktree under \
            .claude/worktrees/… carries the UF_HIDDEN flag, so that option \
            reduces the whole scan to nothing).
            """
        }
    }

    struct RepositoryRootNotFoundError: Error, CustomStringConvertible {
        let startingFrom: String

        var description: String {
            "No Pine.xcodeproj in any ancestor of \(startingFrom)."
        }
    }

    /// The repository root, found by walking up from a test source file until
    /// `Pine.xcodeproj` appears.
    ///
    /// Located by content rather than by a fixed number of
    /// `deletingLastPathComponent()` calls, so a suite that moves into a
    /// subdirectory does not silently start scanning the wrong tree.
    static func repositoryRoot(
        from file: String = #filePath
    ) throws -> URL {
        var candidate = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .standardizedFileURL
        while candidate.path != "/" {
            let project = candidate.appendingPathComponent("Pine.xcodeproj")
            if FileManager.default.fileExists(atPath: project.path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw RepositoryRootNotFoundError(startingFrom: file)
    }

    /// Every `.swift` file under `Pine/`, sorted, never empty.
    static func productionSwiftFileURLs(
        from file: String = #filePath
    ) throws -> [URL] {
        try swiftFileURLs(
            under: repositoryRoot(from: file)
                .appendingPathComponent("Pine")
        )
    }

    /// Every `.swift` file under `root`, sorted by path.
    ///
    /// Hidden files and directories below `root` are excluded **by name**
    /// (`.build/`, `.DS_Store`), never by the `UF_HIDDEN` flag: the name says
    /// something about the repository, the flag only says something about the
    /// checkout it was copied into.
    ///
    /// - Throws: ``EmptyScanError`` when the scan finds nothing.
    static func swiftFileURLs(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw EmptyScanError(root: root)
        }
        let rootComponentCount = root.standardizedFileURL.pathComponents.count
        let urls = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { url in
                !url.standardizedFileURL.pathComponents
                    .dropFirst(rootComponentCount)
                    .contains { $0.hasPrefix(".") }
            }
            .sorted { $0.path < $1.path }
        guard !urls.isEmpty else {
            throw EmptyScanError(root: root)
        }
        return urls
    }
}
