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
    /// Split off the instance property so the stale-entry sweep can answer the
    /// question without a full `init(from:)`. A snapshot written by a newer
    /// build may have renamed a field or added a required one, in which case
    /// decoding a whole ``RecoveryEntry`` throws before the version is ever
    /// read — and the longer retention horizon that exists precisely for that
    /// file would never be applied to it (#1503).
    static func isSupportedSchema(_ schemaVersion: Int?) -> Bool {
        guard let schemaVersion else { return true }
        return (0...currentSchemaVersion).contains(schemaVersion)
    }

    /// Just the schema stamp, decoded from any JSON object that carries one.
    ///
    /// Every other field is ignored, so this keeps working across a rename, a
    /// type change, or a newly required field — the schema changes this
    /// version stamp exists to survive.
    struct SchemaProbe: Decodable {
        let schemaVersion: Int?
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
