//
//  Constants.swift
//  Pine
//
//  Named constants extracted from magic numbers across the codebase.
//

import Foundation

// MARK: - ASCII Character Codes

/// Common ASCII character codes used for text scanning.
enum ASCII {
    /// Line feed (`\n`) — 0x0A
    static let newline: unichar = 0x0A
    /// Carriage return (`\r`) — 0x0D
    static let carriageReturn: unichar = 0x0D
}

// MARK: - File Size Constants

/// Commonly used file size values in bytes.
enum FileSizeConstants {
    /// 1 KB = 1,024 bytes
    static let oneKB = 1_024
    /// 1 MB = 1,048,576 bytes
    static let oneMB = 1_048_576
    /// 10 MB = 10,485,760 bytes
    static let tenMB = 10_485_760
}

// MARK: - Editor Constants

/// Constants used by the code editor (CodeEditorView).
enum EditorConstants {
    /// Number of characters to search in each direction when looking for bracket matches.
    /// Large enough to find nearby brackets, small enough to avoid scanning the entire file.
    static let bracketSearchRadius = 5000
}

// MARK: - Search Constants

/// Constants used by project search (ProjectSearchProvider).
enum SearchConstants {
    /// Maximum number of characters to keep from a matched line for display.
    static let lineContentPrefixLimit = 200
}

// MARK: - Minimap Constants

/// Constants used by the minimap view (MinimapView).
enum MinimapConstants {
    /// Alpha component for syntax-colored segments in the minimap.
    static let syntaxSegmentAlpha: CGFloat = 0.55
    /// Width of git diff marker strips on the right edge.
    static let diffMarkerWidth: CGFloat = 4
    /// Height of each line representation in the minimap.
    static let lineHeight: CGFloat = 2
    /// Width of a single character in minimap coordinates.
    static let charWidth: CGFloat = 0.8
    /// Horizontal padding before the first character.
    static let leadingPadding: CGFloat = 4
}
