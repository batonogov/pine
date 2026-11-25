//
//  Constants.swift
//  Pine
//
//  Named constants extracted from magic numbers across the codebase.
//

import Foundation

// MARK: - ASCII Character Codes

/// Common ASCII character codes used for text scanning.
nonisolated enum ASCII {
    /// Line feed (`\n`) — 0x0A
    static let newline: unichar = 0x0A
    /// Carriage return (`\r`) — 0x0D
    static let carriageReturn: unichar = 0x0D
}

// MARK: - File Size Constants

/// Commonly used file size values in bytes.
nonisolated enum FileSizeConstants {
    /// 1 MB = 1,048,576 bytes
    static let oneMB = 1_048_576
    /// 10 MB = 10,485,760 bytes
    static let tenMB = 10_485_760
}

// MARK: - Editor Constants

/// Constants used by the code editor (CodeEditorView).
nonisolated enum EditorConstants {
    /// Number of characters to search in each direction when looking for bracket matches.
    /// Large enough to find nearby brackets, small enough to avoid scanning the entire file.
    static let bracketSearchRadius = 5000
}
