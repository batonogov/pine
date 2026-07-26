//
//  VerifiedDiffPreviewSnapshotTests.swift
//  PineTests
//
//  Exact-state and checked-text visual coverage for prepared inverse review.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Prepared Inverse Preview Snapshots", .serialized)
@MainActor
struct VerifiedDiffPreviewSnapshotTests {
    private static let panelSize = NSSize(width: 760, height: 390)
    private static let tolerance = 0.005
    private static let english = Locale(identifier: "en")

    @Test(
        "Prepared inverse modes render in light and dark appearances",
        arguments: [
            (Fixture.exactMetadata, SnapshotAppearance.light),
            (Fixture.exactMetadata, SnapshotAppearance.dark),
            (Fixture.checkedText, SnapshotAppearance.light),
            (Fixture.checkedText, SnapshotAppearance.dark),
        ]
    )
    func visual(
        fixture: Fixture,
        appearance: SnapshotAppearance
    ) throws {
        try assertSnapshot(
            of: makeView(fixture),
            size: Self.panelSize,
            appearance: appearance,
            named: "VerifiedDiffPreview.\(fixture.rawValue)."
                + appearance.suffix,
            tolerance: Self.tolerance
        )
    }

    @Test("Engine-backed fixtures retain truthful mode and state semantics")
    func semantics() throws {
        let exact = try makeModel(.exactMetadata)
        let exactRow = try #require(exact.rows.first)
        #expect(exactRow.preparedMode == .exactState)
        #expect(exactRow.presentationKind == .restoreExactFile)
        #expect(exactRow.previewKind == .restoreExactFile)
        #expect(exactRow.isMetadataOnly)
        #expect(exactRow.expectations.first?.identity?.posixMode == 0o644)
        #expect(exactRow.results.first?.identity?.posixMode == 0o755)
        #expect(exactRow.expectations.first?.identity?.kind == .regularFile)
        #expect(exactRow.results.first?.identity?.kind == .regularFile)

        let checked = try makeModel(.checkedText)
        let checkedRow = try #require(checked.rows.first)
        #expect(checkedRow.preparedMode == .checkedText)
        #expect(checkedRow.presentationKind == .applyTextHunks)
        #expect(checkedRow.previewKind == .applyTextHunks)
        #expect(!checkedRow.isMetadataOnly)
        let endings = Set(
            checkedRow.hunks.flatMap(\.lines).map(\.lineEnding)
        )
        #expect(endings == [.lf, .crlf, .noFinalNewline])
    }

    @Test("Strict tolerance rejects a completely blank preview")
    func blankViewExceedsTolerance() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let preview = try SnapshotHarness.render(
            view: makeView(.checkedText),
            size: Self.panelSize,
            appearance: .light
        )
        let blank = try SnapshotHarness.render(
            view: Color.clear,
            size: Self.panelSize,
            appearance: .light
        )
        let previewPNG = try #require(
            preview.representation(using: .png, properties: [:])
        )
        let blankPNG = try #require(
            blank.representation(using: .png, properties: [:])
        )
        let diff = try SnapshotHarness.meanAbsoluteDiff(
            actualPNG: blankPNG,
            referencePNG: previewPNG
        )
        #expect(diff > Self.tolerance)
    }

    private func makeView(
        _ fixture: Fixture
    ) throws -> some View {
        VerifiedDiffPreviewView(model: try makeModel(fixture))
            .environment(\.locale, Self.english)
    }

    /// Builds every visual fixture through checked preparation and complete
    /// engine revalidation, never from a hand-built display row.
    private func makeModel(
        _ fixture: Fixture
    ) throws -> VerifiedDiffPreviewModel {
        let states = fixture.states
        let patchID = id(fixture.baseID)
        let envelopeID = id(fixture.baseID + 1)
        let receiptID = id(fixture.baseID + 2)
        let projectID = id(fixture.baseID + 3)
        let sessionID = id(fixture.baseID + 4)
        let terminalID = id(fixture.baseID + 5)
        let workspace = VerifiedPatchWorkspaceIdentity(
            privateWorkspaceID: id(fixture.baseID + 6),
            canonicalRootPath: "/private/tmp/Pine-Diff-Preview",
            rootDevice: 11,
            rootInode: 22,
            capturedHeadOID: String(repeating: "a", count: 40),
            capturedIndexSHA256: String(repeating: "b", count: 64)
        )
        let path = "Sources/Greeting.swift"
        let transition = VerifiedPatchContentTransition(
            sourcePath: path,
            before: states.before.stateIdentity,
            after: states.after.stateIdentity
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
                relativePath: path,
                before: states.before.stateIdentity.contentIdentity,
                after: states.after.stateIdentity.contentIdentity
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
                receiptID: id(fixture.baseID + 7),
                userApprovalID: id(fixture.baseID + 8),
                descriptorTransactionID: id(fixture.baseID + 9),
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
                sourcePath: path,
                destinationPath: nil,
                before: states.before,
                after: states.after
            )]
        )

        switch VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: VerifiedPatchWorkspaceSnapshot(
                files: [path: states.current]
            )
        ) {
        case .success(let prepared):
            return try VerifiedDiffPreviewModel(prepared: prepared)
        case .failure(let failure):
            throw SnapshotFixtureError.preparation(failure)
        }
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

enum Fixture: String, CaseIterable, Sendable {
    case exactMetadata = "exact"
    case checkedText = "checked"

    var baseID: Int {
        switch self {
        case .exactMetadata: 200
        case .checkedText: 220
        }
    }

    var states: (
        before: VerifiedPatchFileState,
        after: VerifiedPatchFileState,
        current: VerifiedPatchFileState
    ) {
        switch self {
        case .exactMetadata:
            let content = Data("#!/bin/sh\r\necho Pine\r\n".utf8)
            return (
                file(content, mode: 0o755),
                file(content, mode: 0o644),
                file(content, mode: 0o644)
            )
        case .checkedText:
            return (
                file(Data("header\nagent before\r\nfooter".utf8)),
                file(Data("header\r\nagent after\nfooter".utf8)),
                file(Data("human note\nheader\r\nagent after\nfooter".utf8))
            )
        }
    }

    private func file(
        _ content: Data,
        mode: UInt16 = 0o644
    ) -> VerifiedPatchFileState {
        VerifiedPatchFileState(
            content: content,
            kind: .regularFile,
            posixMode: mode
        )
    }
}

private enum SnapshotFixtureError: Error {
    case preparation(VerifiedPatchPreparationFailure)
}
