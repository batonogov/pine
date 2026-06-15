//
//  TerminalLink.swift
//  Pine
//
//  Represents a clickable file:line reference detected in terminal output.
//

import Foundation

/// A clickable file-path reference found in terminal output text.
///
/// Stores the `NSRange` (NSString-based, multibyte-safe) of the full
/// `path:line[:column]` token within the source text, the resolved
/// absolute file URL, and the parsed line/column numbers.
///
/// Clicking a link opens the file in Pine's editor at the corresponding
/// line and column (issue #949).
struct TerminalLink: Equatable {
    /// Range of the full ``path:line[:column]`` token in the original text.
    /// Computed against `NSString` length so it is safe for multibyte content.
    let range: NSRange

    /// Resolved, absolute URL of the file on disk.
    /// Only created after verifying the file exists via `FileManager`.
    let fileURL: URL

    /// 1-based line number to navigate to.
    let line: Int

    /// 1-based column number, if the reference included one (e.g. `file:42:10`).
    let column: Int?
}
