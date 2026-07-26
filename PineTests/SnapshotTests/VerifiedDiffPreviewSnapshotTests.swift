//
//  VerifiedDiffPreviewSnapshotTests.swift
//  PineTests
//
//  Light/dark visual coverage for the read-only prepared inverse preview.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Prepared Inverse Preview Snapshots")
@MainActor
struct VerifiedDiffPreviewSnapshotTests {
    private static let panelSize = NSSize(width: 620, height: 300)
    private static let tolerance = 0.05

    @Test("Prepared inverse preview renders in light appearance")
    func light() throws {
        try assertSnapshot(
            of: makeView(),
            size: Self.panelSize,
            appearance: .light,
            named: "VerifiedDiffPreview.prepared.light",
            tolerance: Self.tolerance
        )
    }

    @Test("Prepared inverse preview renders in dark appearance")
    func dark() throws {
        try assertSnapshot(
            of: makeView(),
            size: Self.panelSize,
            appearance: .dark,
            named: "VerifiedDiffPreview.prepared.dark",
            tolerance: Self.tolerance
        )
    }

    private func makeView() throws -> VerifiedDiffPreviewView {
        VerifiedDiffPreviewView(model: try makeModel())
    }

    /// Builds the visual fixture through the same checked preparation and
    /// complete engine revalidation required by a production caller.
    private func makeModel() throws -> VerifiedDiffPreviewModel {
        let patchID = id(121)
        let envelopeID = id(122)
        let receiptID = id(123)
        let projectID = id(124)
        let sessionID = id(125)
        let terminalID = id(126)
        let privateWorkspaceID = id(127)
        let before = file(
            """
            func greeting() {
                print("before")
            }

            """
        )
        let after = file(
            """
            func greeting() {
                print("agent edit")
            }

            """
        )
        let workspace = VerifiedPatchWorkspaceIdentity(
            privateWorkspaceID: privateWorkspaceID,
            canonicalRootPath: "/private/tmp/Pine-Diff-Preview",
            rootDevice: 11,
            rootInode: 22,
            capturedHeadOID: String(repeating: "a", count: 40),
            capturedIndexSHA256: String(repeating: "b", count: 64)
        )
        let transition = VerifiedPatchContentTransition(
            sourcePath: "Sources/Greeting.swift",
            destinationPath: nil,
            before: before.stateIdentity,
            after: after.stateIdentity
        )
        let envelope = AgentEventEnvelope(
            id: envelopeID,
            projectID: projectID,
            sessionID: sessionID,
            agentTypeRaw: "generic:snapshot",
            process: AgentProcessIdentity(
                terminalID: terminalID,
                processGeneration: 1
            ),
            location: AgentEventLocation(
                worktreePath: workspace.canonicalRootPath,
                cwd: workspace.canonicalRootPath
            ),
            cursorValue: 1,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            source: .explicitAgentEvent,
            trustLevel: .verified,
            payload: .fileChange(AgentFileChange(
                relativePath: transition.sourcePath,
                before: before.stateIdentity.contentIdentity,
                after: after.stateIdentity.contentIdentity
            ))
        )
        let durableIdentity = VerifiedPatchDurableEventIdentity(
            projectID: projectID,
            canonicalWorktreePath: workspace.canonicalRootPath,
            sessionID: sessionID,
            terminalID: terminalID,
            processGeneration: 1,
            eventCursor: 1,
            envelopeID: envelopeID,
            journalSequence: 1
        )
        let record = VerifiedPatchUntrustedEventRecord(
            envelope: envelope,
            durableIdentity: durableIdentity,
            mediatedWriterReceipt: PineMediatedWriterReceipt(
                receiptID: id(128),
                userApprovalID: id(129),
                descriptorTransactionID: id(130),
                descriptorCASSequence: 1,
                workspace: workspace,
                auditEvent: durableIdentity,
                transitions: [transition]
            ),
            transitions: [transition]
        )
        let receipt = try VerifiedPatchIngressCoordinator.accept(
            receiptID: receiptID,
            workspace: workspace,
            records: [record]
        )
        let patch = try VerifiedPatchEngine.makePatch(
            id: patchID,
            receipt: receipt,
            operations: [VerifiedPatchSourceOperation(
                transitionID: VerifiedPatchTransitionID(
                    envelopeID: envelopeID,
                    ordinal: 0
                ),
                sourcePath: transition.sourcePath,
                destinationPath: nil,
                before: before,
                after: after
            )]
        )

        switch VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: VerifiedPatchWorkspaceSnapshot(
                files: [transition.sourcePath: after]
            )
        ) {
        case .success(let prepared):
            return try VerifiedDiffPreviewModel(prepared: prepared)
        case .failure(let failure):
            throw SnapshotFixtureError.preparation(failure)
        }
    }

    private func file(_ value: String) -> VerifiedPatchFileState {
        VerifiedPatchFileState(
            content: Data(value.utf8),
            kind: .regularFile,
            posixMode: 0o644
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0,
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ))
    }
}

private enum SnapshotFixtureError: Error {
    case preparation(VerifiedPatchPreparationFailure)
}
