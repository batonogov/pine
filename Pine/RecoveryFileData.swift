//
//  RecoveryFileData.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import Foundation

/// Codable model written to disk for each dirty tab during crash recovery.
/// Stored as JSON in `~/Library/Application Support/Pine/Recovery/{tab-uuid}.recovery`.
struct RecoveryFileData: Codable {
    /// The tab UUID at the time of snapshotting. Used for file naming.
    let tabID: UUID
    /// Absolute path of the original file, or nil for untitled buffers.
    let originalURLPath: String?
    /// The unsaved content at the time of the snapshot.
    let content: String
    /// When the snapshot was taken.
    let timestamp: Date
    /// Raw value of `String.Encoding` (e.g. 4 for UTF-8).
    let encodingRawValue: UInt

    // MARK: - Derived

    var encoding: String.Encoding {
        String.Encoding(rawValue: encodingRawValue)
    }

    var originalURL: URL? {
        guard let path = originalURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Human-readable name shown in the recovery dialog.
    var displayName: String {
        guard let path = originalURLPath else { return "Untitled" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
