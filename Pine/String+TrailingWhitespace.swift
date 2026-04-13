//
//  String+TrailingWhitespace.swift
//  Pine
//

import Foundation

extension String {
    /// Returns a copy with trailing whitespace (spaces and tabs) removed from every line.
    /// Preserves line endings (LF, CRLF) and empty lines.
    func trailingWhitespaceStripped() -> String {
        replacingOccurrences(
            of: "[ \\t]+(?=\\r?\\n|$)",
            with: "",
            options: .regularExpression
        )
    }

    /// Returns a copy guaranteed to end with exactly one trailing newline, preserving the
    /// file's existing line-ending style (LF or CRLF). Empty strings are returned unchanged
    /// to avoid turning an empty file into a 1-byte newline. Multiple trailing blank lines
    /// are collapsed into a single terminating newline.
    ///
    /// POSIX defines a text file as a sequence of lines, each terminated by a newline.
    /// Most Unix tools (`cat`, `wc -l`, `git diff`) expect this and emit warnings ("No
    /// newline at end of file") when it is missing. This helper enforces the convention.
    func ensuringTrailingNewline() -> String {
        guard !isEmpty else { return self }

        // Detect CRLF vs LF from the first line ending found. Default to LF when none exists.
        let useCRLF = range(of: "\r\n") != nil
        let newline = useCRLF ? "\r\n" : "\n"

        // Strip any trailing run of blank lines (\n, \r\n, or bare \r) so we end with exactly
        // one newline. Walk UTF-8 bytes rather than Characters because Swift groups "\r\n"
        // into a single extended grapheme cluster, which breaks naive Character comparison.
        let bytes = self.utf8
        var end = bytes.endIndex
        while end > bytes.startIndex {
            let prev = bytes.index(before: end)
            let byte = bytes[prev]
            if byte == 0x0A /* \n */ || byte == 0x0D /* \r */ {
                end = prev
            } else {
                break
            }
        }

        // If everything was newlines, the file is "just blank lines" — preserve original.
        if end == bytes.startIndex {
            return self
        }

        // Convert the UTF-8 index back to a String.Index. Because we only stop on ASCII
        // bytes (\n, \r), the boundary is guaranteed to lie on a valid scalar edge.
        let cutoff = String.Index(end, within: self) ?? self.endIndex
        return self[..<cutoff] + newline
    }
}
