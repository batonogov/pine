//
//  StatusBarInfo.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import Foundation

/// Cursor position expressed as line and column (both 1-based).
struct CursorLocation: Equatable {
    let line: Int
    let column: Int

    /// Computes line and column from a UTF-16 cursor offset within content.
    init(position: Int, in content: String) {
        let nsContent = content as NSString
        let clampedPosition = min(position, nsContent.length)

        var currentLine = 1
        var lineStart = 0
        var i = 0
        while i < clampedPosition {
            let char = nsContent.character(at: i)
            if char == 0x0A { // \n
                currentLine += 1
                lineStart = i + 1
            } else if char == 0x0D { // \r
                currentLine += 1
                // Skip \n in \r\n pair
                if i + 1 < nsContent.length && nsContent.character(at: i + 1) == 0x0A {
                    i += 1
                }
                lineStart = i + 1
            }
            i += 1
        }

        self.line = currentLine
        self.column = clampedPosition - lineStart + 1
    }
}

/// Line ending style detected in file content.
enum LineEnding: Equatable {
    case lf
    case crlf

    var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        }
    }

    /// Detects the predominant line ending style in content.
    /// If the majority of line endings are CRLF, returns `.crlf`; otherwise `.lf`.
    static func detect(in content: String) -> LineEnding {
        var lfCount = 0
        var crlfCount = 0
        let nsContent = content as NSString
        var i = 0
        while i < nsContent.length {
            let char = nsContent.character(at: i)
            if char == 0x0D && i + 1 < nsContent.length && nsContent.character(at: i + 1) == 0x0A {
                crlfCount += 1
                i += 2
            } else if char == 0x0A {
                lfCount += 1
                i += 1
            } else {
                i += 1
            }
        }
        return crlfCount > lfCount ? .crlf : .lf
    }
}

/// Indentation style detected in file content.
enum IndentationStyle: Equatable {
    case spaces(Int)
    case tabs

    var displayName: String {
        switch self {
        case .spaces(let count): "Spaces: \(count)"
        case .tabs: "Tabs"
        }
    }

    /// Detects the indentation style by analyzing leading whitespace of lines.
    static func detect(in content: String) -> IndentationStyle {
        var tabLines = 0
        var spaceLines = 0
        var spaceCounts: [Int: Int] = [:]

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first == " " || first == "\t" else { continue }
            if first == "\t" {
                tabLines += 1
            } else {
                let spaceCount = line.prefix(while: { $0 == " " }).count
                if spaceCount > 0 {
                    spaceLines += 1
                    spaceCounts[spaceCount, default: 0] += 1
                }
            }
        }

        if tabLines > spaceLines {
            return .tabs
        }

        guard !spaceCounts.isEmpty else {
            return .spaces(4) // default
        }

        // Find the GCD of all space counts to determine indent size
        let commonDivisor = spaceCounts.keys.reduce(0) { computeGCD($0, $1) }
        let indentSize = max(commonDivisor, 2)
        return .spaces(min(indentSize, 8))
    }

    private static func computeGCD(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : computeGCD(b, a % b)
    }
}

/// Formats file sizes for display.
enum FileSizeFormatter {
    static func format(_ bytes: Int) -> String {
        if bytes < 1_024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bytes) / 1_024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
    }
}
