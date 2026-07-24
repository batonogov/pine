//
//  AgentHistoryRecovery.swift
//  Pine
//
//  Versioned, owner-private recovery records for checked Agent History undo.
//  Recovery discovery is deliberately read-only: these values make interrupted
//  transactions visible after restart, but never authorize an automatic write
//  back into a workspace.
//

import Foundation

nonisolated enum AgentHistoryRecoveryPhase:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable {
    case prepared
    case authorityConsumed
    case finalized

    var markerFileName: String {
        switch self {
        case .prepared: "phase-prepared.json"
        case .authorityConsumed: "phase-authority-consumed.json"
        case .finalized: "phase-finalized.json"
        }
    }
}

nonisolated struct AgentHistoryRecoveryPhaseMarker: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let transactionID: UUID
    let phase: AgentHistoryRecoveryPhase
    let recordedAt: Date
}

nonisolated struct AgentHistoryRecoveryManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    let transactionID: UUID
    let authorityRecordID: UUID
    let historyEntryID: UUID
    let changeSetID: UUID
    let resolvedRootPath: String
    let rootDevice: UInt64
    let rootInode: UInt64
    let createdAt: Date
    let entries: [AgentHistoryRecoveryManifestEntry]
}

nonisolated struct AgentHistoryRecoveryManifestEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let existed: Bool
    let permissions: UInt16?
    let contentFile: String?
    let byteCount: UInt64?
    let contentSHA256: String?
}

nonisolated struct AgentHistoryRecoveryPathsManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let recoveryPaths: [String]
}

nonisolated enum AgentHistoryRecoveryCorruption: String, Equatable, Sendable {
    case invalidRecoveryRoot
    case enumerationLimitExceeded
    case untrustedDirectory
    case invalidManifest
    case invalidPhaseMarkers
    case invalidRecoveryMetadata
    case invalidWorkspaceArtifacts
}

nonisolated enum AgentHistoryRecoveryDiscoveryState: Equatable, Sendable {
    case prepared
    case authorityConsumed
    case finalized
    case corrupt(AgentHistoryRecoveryCorruption)
}

/// One descriptor-validated recovery directory discovered after launch.
///
/// A corrupt record intentionally remains visible with a directory path even
/// when its manifest cannot be trusted. Paths are display/reveal hints only;
/// recovery application remains a separate, explicit future workflow.
nonisolated struct AgentHistoryRecoveryRecord: Identifiable, Equatable, Sendable {
    var id: String { directoryPath }

    let directoryName: String
    let directoryPath: String
    let manifest: AgentHistoryRecoveryManifest?
    let state: AgentHistoryRecoveryDiscoveryState
    let recoveryPaths: [String]
    let workspaceArtifactPaths: [String]
    /// Paths proven descriptor-relative during discovery. Only these paths
    /// may receive reveal/copy actions in the UI.
    let validatedPaths: [String]

    init(
        directoryName: String,
        directoryPath: String,
        manifest: AgentHistoryRecoveryManifest?,
        state: AgentHistoryRecoveryDiscoveryState,
        recoveryPaths: [String],
        workspaceArtifactPaths: [String] = [],
        validatedPaths: [String] = []
    ) {
        self.directoryName = directoryName
        self.directoryPath = directoryPath
        self.manifest = manifest
        self.state = state
        self.recoveryPaths = recoveryPaths
        self.workspaceArtifactPaths = workspaceArtifactPaths
        self.validatedPaths = validatedPaths
    }

    var transactionID: UUID? { manifest?.transactionID }
    var authorityRecordID: UUID? { manifest?.authorityRecordID }
    var historyEntryID: UUID? { manifest?.historyEntryID }
    var affectedPaths: [String] { manifest?.entries.map(\.relativePath) ?? [] }
}
