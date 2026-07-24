//
//  AgentHistoryChangeSet.swift
//  Pine
//
//  Versioned, content-free contract for a future verified Agent History undo
//  pipeline (#1183). The project log stores identities and an opaque payload
//  reference only; inverse patches/content must live in owner-only
//  Application Support storage, never in `.pine/agent-log.json`.
//

import Foundation

/// Binds a verified change set to an owner-private workspace record and exact
/// Git state without persisting machine-specific paths in the project log.
///
/// The Application Support authority record owns the canonical root, worktree
/// git-dir/common-dir, and filesystem resource identity. The opaque ID here is
/// only a lookup/binding key and is never sufficient to authorize mutation.
nonisolated struct AgentHistoryWorkspaceIdentity: Codable, Equatable, Sendable {
    let privateWorkspaceID: UUID
    /// Exact HEAD object ID (SHA-1 or SHA-256 repository format).
    let headOID: String
    /// SHA-256 of the exact Git index bytes captured with the change set.
    let indexSHA256: String
}

/// Explicit writer provenance supplied by a future trusted agent integration.
///
/// File-system observation cannot manufacture this value: it must come from a
/// writer-specific event stream whose monotonically increasing sequence range
/// is bound to one process generation and one Agent History session.
nonisolated struct AgentHistoryWriterProvenance: Codable, Equatable, Sendable {
    let sessionID: UUID
    let writerInstanceID: UUID
    let processIdentifier: Int32
    let processGeneration: UInt64
    let firstEventSequence: UInt64
    let lastEventSequence: UInt64
}

/// File kind recorded without following links. Only regular files are eligible
/// for the first checked-undo implementation; all other values fail closed.
nonisolated enum AgentHistoryRecordedFileKind: Equatable, Sendable {
    case regularFile
    case symbolicLink
    case directory
    case unsupported(String)

    private var persistedValue: String {
        switch self {
        case .regularFile: "regularFile"
        case .symbolicLink: "symbolicLink"
        case .directory: "directory"
        case .unsupported(let value): value
        }
    }
}

nonisolated extension AgentHistoryRecordedFileKind: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "regularFile": self = .regularFile
        case "symbolicLink": self = .symbolicLink
        case "directory": self = .directory
        default: self = .unsupported(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        if case .unsupported(let value) = self,
           ["regularFile", "symbolicLink", "directory"].contains(value) {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported file kind aliases a trusted value"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}

/// Exact identity of one side of a recorded file change.
nonisolated struct AgentHistoryRecordedFileState: Codable, Equatable, Sendable {
    let kind: AgentHistoryRecordedFileKind
    /// SHA-256 of the exact file bytes, without text decoding or newline
    /// normalization.
    let contentSHA256: String
    let byteCount: UInt64
    /// POSIX permission bits only, without file-type bits.
    let permissions: UInt16
}

/// Operation represented by a recorded change.
///
/// Rename and symlink values are persisted explicitly so they produce a typed
/// refusal instead of being misinterpreted as regular-file edits. Unknown
/// future values also decode without granting mutation permission.
nonisolated enum AgentHistoryFileOperation: Equatable, Sendable {
    case modify
    case create
    case delete
    case rename
    case symlink
    case unsupported(String)

    var persistedValue: String {
        switch self {
        case .modify: "modify"
        case .create: "create"
        case .delete: "delete"
        case .rename: "rename"
        case .symlink: "symlink"
        case .unsupported(let value): value
        }
    }
}

nonisolated extension AgentHistoryFileOperation: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "modify": self = .modify
        case "create": self = .create
        case "delete": self = .delete
        case "rename": self = .rename
        case "symlink": self = .symlink
        default: self = .unsupported(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        if case .unsupported(let value) = self,
           ["modify", "create", "delete", "rename", "symlink"].contains(value) {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported operation aliases a trusted value"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}

/// One exact before/after identity pair in a verified change set.
nonisolated struct AgentHistoryRecordedFileChange: Codable, Equatable, Sendable {
    let relativePath: String
    let operation: AgentHistoryFileOperation
    let before: AgentHistoryRecordedFileState?
    let after: AgentHistoryRecordedFileState?
}

/// Storage class for private Agent History authority and inverse-payload data.
///
/// The persisted contract intentionally has no arbitrary path case. A future
/// resolver derives locations from opaque IDs underneath Pine's owner-only
/// Application Support directory.
nonisolated enum AgentHistoryPrivateStorage: Equatable, Sendable {
    case applicationSupport
    case unsupported(String)

    private var persistedValue: String {
        switch self {
        case .applicationSupport: "applicationSupport"
        case .unsupported(let value): value
        }
    }
}

nonisolated extension AgentHistoryPrivateStorage: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "applicationSupport": self = .applicationSupport
        default: self = .unsupported(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        if case .unsupported("applicationSupport") = self {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported storage aliases a trusted value"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}

/// Lookup key for the owner-private record that is the actual authorization
/// source. `.pine/agent-log.json` is only a display/index projection and may be
/// edited by project contents, so the future engine must load this record,
/// compare the complete canonical projection, and honor private consumed/
/// in-flight state before performing any runtime validation.
nonisolated struct AgentHistoryPrivateAuthorityReference: Codable, Equatable, Sendable {
    static let currentManifestFormatVersion = 1

    let storage: AgentHistoryPrivateStorage
    let recordID: UUID
    let manifestFormatVersion: Int
    /// SHA-256 of the canonical change-set projection excluding this digest.
    /// This is an integrity cross-check, not an authentication primitive; the
    /// owner-private manifest remains the source of authority.
    let canonicalContractSHA256: String
}

/// Content-free reference to an inverse payload stored outside the project.
nonisolated struct AgentHistoryInversePayloadReference: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let storage: AgentHistoryPrivateStorage
    let blobID: UUID
    let formatVersion: Int
    let byteCount: UInt64
    let sha256: String
}

/// Exact, versioned input contract for a future checked inverse operation.
///
/// This type deliberately contains no patch bytes or source text. The payload
/// reference is integrity-bound, and the before/after identities let the
/// eventual engine reject divergence before applying anything.
nonisolated struct VerifiedAgentChangeSet: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    /// Entry identity bound into the owner-private authority manifest.
    let historyEntryID: UUID
    let schemaVersion: Int
    let capturedAt: Date
    let provenance: AgentHistoryWriterProvenance
    let workspace: AgentHistoryWorkspaceIdentity
    let changes: [AgentHistoryRecordedFileChange]
    let authority: AgentHistoryPrivateAuthorityReference
    let inversePayload: AgentHistoryInversePayloadReference
}
