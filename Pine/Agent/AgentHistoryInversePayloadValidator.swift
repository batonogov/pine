//
//  AgentHistoryInversePayloadValidator.swift
//  Pine
//
//  One fail-closed validator shared by checked-undo preview and apply.
//

import Foundation

/// A precise reason an owner-private inverse payload does not match the
/// content-free verified change-set projection.
nonisolated enum AgentHistoryPayloadFailure:
    Error,
    Equatable,
    Sendable {
    case unsupportedFormatVersion(Int)
    case entryCountMismatch(expected: Int, actual: Int)
    case duplicatePath(String)
    case unexpectedPath(String)
    case operationMismatch(String)
    case missingBeforeContent(String)
    case unexpectedBeforeContent(String)
    case permissionMismatch(String)
    case byteCountMismatch(String)
    case contentHashMismatch(String)
}

/// A validated payload projection. Keeping the dictionary behind this type
/// prevents preview and apply from silently choosing different duplicate-key
/// behaviour.
nonisolated struct AgentHistoryValidatedInversePayload: Sendable {
    private let entriesByPath: [String: AgentHistoryInverseFileEntry]

    fileprivate init(
        entriesByPath: [String: AgentHistoryInverseFileEntry]
    ) {
        self.entriesByPath = entriesByPath
    }

    subscript(relativePath: String) -> AgentHistoryInverseFileEntry? {
        entriesByPath[relativePath]
    }
}

/// Validates the complete payload/change-set binding before any payload bytes
/// are rendered or applied.
nonisolated enum AgentHistoryInversePayloadValidator {
    static func validate(
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload
    ) -> Result<
        AgentHistoryValidatedInversePayload,
        AgentHistoryPayloadFailure
    > {
        guard payload.formatVersion
            == AgentHistoryInversePayload.currentFormatVersion else {
            return .failure(
                .unsupportedFormatVersion(payload.formatVersion)
            )
        }
        guard payload.entries.count == changeSet.changes.count else {
            return .failure(
                .entryCountMismatch(
                    expected: changeSet.changes.count,
                    actual: payload.entries.count
                )
            )
        }

        let expectedPaths = Set(changeSet.changes.map(\.relativePath))
        var entries: [String: AgentHistoryInverseFileEntry] = [:]
        for entry in payload.entries {
            guard expectedPaths.contains(entry.relativePath) else {
                return .failure(.unexpectedPath(entry.relativePath))
            }
            guard entries[entry.relativePath] == nil else {
                return .failure(.duplicatePath(entry.relativePath))
            }
            entries[entry.relativePath] = entry
        }

        for change in changeSet.changes {
            guard let entry = entries[change.relativePath] else {
                return .failure(.unexpectedPath(change.relativePath))
            }
            guard entry.operation == change.operation else {
                return .failure(.operationMismatch(change.relativePath))
            }
            switch change.operation {
            case .modify, .delete:
                guard let before = change.before,
                      let content = entry.beforeContent else {
                    return .failure(
                        .missingBeforeContent(change.relativePath)
                    )
                }
                guard entry.permissions == before.permissions else {
                    return .failure(
                        .permissionMismatch(change.relativePath)
                    )
                }
                guard UInt64(content.count) == before.byteCount else {
                    return .failure(
                        .byteCountMismatch(change.relativePath)
                    )
                }
                guard AgentHistoryContentHash.sha256Hex(content)
                    == before.contentSHA256 else {
                    return .failure(
                        .contentHashMismatch(change.relativePath)
                    )
                }
            case .create:
                guard entry.beforeContent == nil else {
                    return .failure(
                        .unexpectedBeforeContent(change.relativePath)
                    )
                }
                guard entry.permissions == nil else {
                    return .failure(
                        .permissionMismatch(change.relativePath)
                    )
                }
            case .rename, .symlink, .unsupported:
                return .failure(
                    .operationMismatch(change.relativePath)
                )
            }
        }

        return .success(
            AgentHistoryValidatedInversePayload(entriesByPath: entries)
        )
    }
}
