//
//  TerminalOutputParser.swift
//  Pine
//
//  Pure functions for detecting file:line references in terminal output.
//

import Foundation

/// Detects `file:line[:column]` references in terminal output text and
/// resolves them to verified on-disk files.
///
/// AI agents and compiler tools constantly emit references like
/// `Server.swift:42` or `/abs/path/config.yml:15:3`. This parser scans
/// text for such patterns, validates that the referenced file actually
/// exists on disk, and returns ``TerminalLink`` values for rendering
/// clickable regions.
///
/// The parser is a pure function — no side effects beyond a
/// `FileManager.fileExists` check — making it trivially unit-testable.
enum TerminalOutputParser {

    // MARK: - Configuration

    /// Characters that are valid in a file-path token.
    ///
    /// Word characters (`\w` = letters, digits, underscore) plus the path
    /// separators and special characters commonly found in real paths:
    /// dot, slash, hyphen, plus, tilde.
    ///
    /// Wrapping punctuation — `(`, `[`, `{`, `"`, `'` — is intentionally
    /// excluded so that `(file.swift:42)` only matches `file.swift:42`.
    private static let pathCharacters = #"[\w.~+/\-]"#

    /// Compiled regex for `path:line[:column]`.
    ///
    /// Captures:
    /// 1. The file path (characters from ``pathCharacters``).
    /// 2. The 1-based line number (digits).
    /// 3. The optional 1-based column number (digits).
    private static let pattern = #"(\#(pathCharacters)+):(\d+)(?::(\d+))?"#

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern)
    }()

    // MARK: - Public API

    /// Scans `text` for `file:line[:column]` references and returns verified links.
    ///
    /// - Parameters:
    ///   - text: Terminal output to scan.
    ///   - workingDirectory: The directory used to resolve relative paths.
    ///   - fileManager: Injected `FileManager` (defaults to `.default` for tests).
    /// - Returns: Links for every reference whose file exists on disk.
    ///   Relative paths are resolved against `workingDirectory`; absolute paths
    ///   (starting with `/`) and home-relative paths (starting with `~`) are
    ///   resolved independently.
    static func parseFilePaths(
        in text: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> [TerminalLink] {
        guard let regex else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        var links: [TerminalLink] = []
        links.reserveCapacity(matches.count)

        for match in matches {
            guard let link = makeLink(from: match, in: nsText,
                                      workingDirectory: workingDirectory,
                                      fileManager: fileManager) else {
                continue
            }
            links.append(link)
        }
        return links
    }

    /// Convenience: returns the first link whose `NSRange` contains the given
    /// column index (0-based, counting `NSString` characters).
    ///
    /// Used by the Cmd+click handler to find the link under the cursor without
    /// iterating all matches manually.
    static func link(atColumn column: Int, in links: [TerminalLink]) -> TerminalLink? {
        links.first { NSLocationInRange(column, $0.range) }
    }

    // MARK: - Internal helpers

    /// Builds a ``TerminalLink`` from a single regex match, validating file
    /// existence on disk. Returns `nil` if the file does not exist.
    private static func makeLink(
        from match: NSTextCheckingResult,
        in nsText: NSString,
        workingDirectory: URL,
        fileManager: FileManager
    ) -> TerminalLink? {
        let pathMatch = match.range(at: 1)
        let lineMatch = match.range(at: 2)
        let columnMatch = match.range(at: 3)

        guard pathMatch.location != NSNotFound,
              lineMatch.location != NSNotFound else {
            return nil
        }

        let pathString = nsText.substring(with: pathMatch)
        let lineString = nsText.substring(with: lineMatch)

        guard let line = Int(lineString), line > 0 else { return nil }

        let column: Int? = columnMatch.location != NSNotFound
            ? Int(nsText.substring(with: columnMatch))
            : nil

        // Resolve and validate file existence before creating a link.
        let resolvedURL = resolvePath(pathString, workingDirectory: workingDirectory)
        guard fileManager.fileExists(atPath: resolvedURL.path) else { return nil }

        return TerminalLink(
            range: match.range,
            fileURL: resolvedURL,
            line: line,
            column: column
        )
    }

    /// Resolves a path string (absolute, home-relative, or relative) to a
    /// concrete file URL.
    static func resolvePath(_ path: String, workingDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            // Absolute path — use as-is.
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("~") {
            // Home-relative path — expand `~`.
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            let expanded: String
            if path == "~" {
                expanded = home
            } else if path.hasPrefix("~/") {
                expanded = home + String(path.dropFirst(1))
            } else {
                // `~user` syntax — rare; treat as-is (validation will reject
                // if the file doesn't exist).
                expanded = path
            }
            return URL(fileURLWithPath: expanded)
        }
        // Relative path — resolve against the working directory.
        return workingDirectory.appendingPathComponent(path)
    }
}
