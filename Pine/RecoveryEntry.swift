//
//  RecoveryEntry.swift
//  Pine
//

import Foundation

/// Represents a snapshot of unsaved editor content for crash recovery.
///
/// `nonisolated` because the module compiles with `-default-isolation=MainActor`
/// and `InferIsolatedConformances`: without it the `Decodable` conformance is
/// main-actor-isolated and cannot be used from
/// ``RecoveryManager/readEntries(in:)``, which decodes the snapshot directory
/// off the main actor so a launch does not block on it (#1503). This is a pure
/// value type with no mutable state, so there is nothing for the isolation to
/// protect.
nonisolated struct RecoveryEntry: Codable, Sendable {
    static let currentSchemaVersion = 1
    /// Missing for snapshots written before persistence versioning.
    let schemaVersion: Int?
    /// Path to the original file on disk (empty string for untitled tabs).
    let originalPath: String
    /// Display name retained for an untitled buffer. Optional keeps snapshots
    /// written by earlier Pine builds source-compatible.
    let untitledName: String?
    /// The unsaved content at the time of the snapshot.
    let content: String
    /// When this snapshot was taken.
    let timestamp: Date
    /// Raw value of `String.Encoding` used by the tab.
    let encodingRawValue: UInt

    var encoding: String.Encoding {
        String.Encoding(rawValue: encodingRawValue)
    }

    var hasSupportedSchema: Bool {
        Self.isSupportedSchema(schemaVersion)
    }

    /// Whether a bare schema stamp names a shape this build can read.
    ///
    /// Only a signal now. A stamp from a newer build does not hide or delete
    /// anything: ``RecoveryManager/readEntries(in:)`` logs against it and
    /// still offers every snapshot that decodes (#1503), and nothing removes
    /// a snapshot by age any more (#1760).
    static func isSupportedSchema(_ schemaVersion: Int?) -> Bool {
        guard let schemaVersion else { return true }
        return (0...currentSchemaVersion).contains(schemaVersion)
    }

    /// How large the buffer is, in bytes under its own encoding. Shown in the
    /// recovery list.
    ///
    /// UTF-8 — nearly every buffer — takes the O(1) count of the native
    /// string. Anything else is re-encoded, which is linear in the buffer,
    /// and returns the size the file would have on disk.
    var byteCount: Int {
        guard encoding != .utf8 else { return content.utf8.count }
        return content.data(using: encoding, allowLossyConversion: true)?
            .count ?? content.utf8.count
    }

    init(
        schemaVersion: Int? = Self.currentSchemaVersion,
        originalPath: String,
        untitledName: String? = nil,
        content: String,
        timestamp: Date = Date(),
        encoding: String.Encoding = .utf8
    ) {
        self.schemaVersion = schemaVersion
        self.originalPath = originalPath
        self.untitledName = untitledName
        self.content = content
        self.timestamp = timestamp
        self.encodingRawValue = encoding.rawValue
    }
}
