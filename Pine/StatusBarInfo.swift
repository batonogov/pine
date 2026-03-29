//
//  StatusBarInfo.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import Foundation

/// Cursor position expressed as line and column (both 1-based).
struct CursorLocation: Equatable, Sendable {
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
            if char == ASCII.newline {
                currentLine += 1
                lineStart = i + 1
            } else if char == ASCII.carriageReturn {
                currentLine += 1
                // Skip \n in \r\n pair
                if i + 1 < nsContent.length && nsContent.character(at: i + 1) == ASCII.newline {
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
enum LineEnding: Equatable, Sendable {
    case lf
    case crlf

    var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        }
    }

    /// The other line ending style.
    var opposite: LineEnding {
        switch self {
        case .lf: .crlf
        case .crlf: .lf
        }
    }

    /// Converts content to use this line ending style.
    /// First normalizes all line endings to LF, then converts to the target.
    func convert(_ content: String) -> String {
        // Normalize: CRLF → LF first, then convert LF → target
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        switch self {
        case .lf:
            return normalized
        case .crlf:
            return normalized.replacingOccurrences(of: "\n", with: "\r\n")
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
            if char == ASCII.carriageReturn && i + 1 < nsContent.length
                && nsContent.character(at: i + 1) == ASCII.newline {
                crlfCount += 1
                i += 2
            } else if char == ASCII.newline {
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
enum IndentationStyle: Equatable, Sendable {
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
        if bytes < FileSizeConstants.oneKB {
            return "\(bytes) B"
        } else if bytes < FileSizeConstants.oneMB {
            return String(format: "%.1f KB", Double(bytes) / Double(FileSizeConstants.oneKB))
        } else {
            return String(format: "%.1f MB", Double(bytes) / Double(FileSizeConstants.oneMB))
        }
    }
}
