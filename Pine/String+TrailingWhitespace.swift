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
}
