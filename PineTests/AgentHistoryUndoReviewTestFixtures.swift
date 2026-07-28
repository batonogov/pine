//
//  AgentHistoryUndoReviewTestFixtures.swift
//  PineTests
//

import Foundation

@testable import Pine

enum AgentHistoryUndoReviewTestFixtures {
    static let historyEntryID = UUID(uuid: (
        0xA8, 0x3C, 0x4B, 0x7C,
        0x10, 0xF5, 0x45, 0xBB,
        0x81, 0xCA, 0xDB, 0x16,
        0xFD, 0x29, 0x2C, 0xAA
    ))

    static func mixedContentModel() -> AgentHistoryUndoPreviewModel {
        AgentHistoryUndoPreviewModel(
            historyEntryID: historyEntryID,
            operations: [
                operation(
                    path: "Assets/logo.bin",
                    contentRepresentation: .binary,
                    expectedByteCount: 4_096,
                    resultByteCount: 3_584,
                    inode: 101
                ),
                operation(
                    path: "Sources/Generated.swift",
                    contentRepresentation: .omitted,
                    expectedByteCount: 2_400_000,
                    resultByteCount: 2_350_000,
                    inode: 102
                ),
            ]
        )
    }

    private static func operation(
        path: String,
        contentRepresentation: AgentHistoryUndoContentKind,
        expectedByteCount: UInt64,
        resultByteCount: UInt64,
        inode: UInt64
    ) -> AgentHistoryUndoPreviewOperation {
        AgentHistoryUndoPreviewOperation(
            id: path,
            relativePath: path,
            kind: .restoreModifiedFile,
            contentRepresentation: contentRepresentation,
            hunks: [],
            expectedContentSHA256: String(repeating: "a", count: 64),
            expectedByteCount: expectedByteCount,
            expectedPermissions: 0o644,
            resultContentSHA256: String(repeating: "b", count: 64),
            resultByteCount: resultByteCount,
            resultPermissions: 0o644,
            previewDevice: 42,
            previewInode: inode
        )
    }
}
