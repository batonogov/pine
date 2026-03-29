//
//  RecoveryEntry.swift
//  Pine
//

import Foundation

/// Represents a snapshot of unsaved editor content for crash recovery.
struct RecoveryEntry: Codable, Sendable {
    /// Path to the original file on disk (empty string for untitled tabs).
    let originalPath: String
    /// The unsaved content at the time of the snapshot.
    let content: String
    /// When this snapshot was taken.
    let timestamp: Date
    /// Raw value of `String.Encoding` used by the tab.
    let encodingRawValue: UInt

    var encoding: String.Encoding {
        String.Encoding(rawValue: encodingRawValue)
    }

    init(originalPath: String, content: String, timestamp: Date = Date(), encoding: String.Encoding = .utf8) {
        self.originalPath = originalPath
        self.content = content
        self.timestamp = timestamp
        self.encodingRawValue = encoding.rawValue
    }
}
