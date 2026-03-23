//
//  GoToLineParser.swift
//  Pine
//

import Foundation

/// Parses user input for Go to Line navigation.
/// Accepts formats: "42" (line only) or "42:10" (line:column), both 1-based.
struct GoToLineParser {
    struct Result {
        let line: Int
        let column: Int?
    }

    static func parse(_ input: String) -> Result? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let first = parts.first,
              let line = Int(first),
              line >= 1 else { return nil }
        if parts.count == 2 {
            guard let col = Int(parts[1]), col >= 1 else { return nil }
            return Result(line: line, column: col)
        }
        return Result(line: line, column: nil)
    }
}
