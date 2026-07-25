//
//  VerifiedPatchEngineTests.swift
//  PineTests
//
//  Pure verified patch, preview, merge, and overlap coverage for #933.
//

import Foundation
import Testing

@testable import Pine

@Suite("Verified Patch Engine")
struct VerifiedPatchEngineTests {
    @Test("Patch and preview are deterministic and identity-bound")
    func deterministicPatchAndPreview() throws {
        let before = data("header\nold\nfooter\n")
        let after = data("header\nagent\nfooter\n")
        let patch = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            before: before,
            after: after
        )
        let duplicate = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            before: before,
            after: after
        )

        #expect(patch == duplicate)
        let preview = VerifiedPatchEngine.previewInverse(patch)
        #expect(preview == VerifiedPatchEngine.previewInverse(duplicate))
        #expect(preview.count == 1)
        #expect(preview[0].kind == .applyTextHunks)
        #expect(preview[0].eventEnvelopeID == id(2))
        #expect(preview[0].expectedCurrentIdentity == ContentIdentity(content: after))
        #expect(preview[0].resultIdentity == ContentIdentity(content: before))
        #expect(preview[0].hunks.count == 1)
        #expect(preview[0].hunks[0].header == "@@ -2,1 +2,1 @@")
        #expect(preview[0].hunks[0].lines.contains {
            $0.kind == .remove && $0.bytes == data("agent\n")
        })
        #expect(preview[0].hunks[0].lines.contains {
            $0.kind == .add && $0.bytes == data("old\n")
        })
    }

    @Test("Exact expected text is inverted byte-for-byte")
    func exactTextInverse() throws {
        let before = data("before\n")
        let after = data("after\n")
        let patch = try singlePatch(
            before: before,
            after: after
        )

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(
                files: ["file.txt": after, "unrelated.txt": data("keep")]
            )
        )

        let applied = try #require(appliedSnapshot(result))
        #expect(applied.files["file.txt"] == before)
        #expect(applied.files["unrelated.txt"] == data("keep"))
    }

    @Test("Checked text hunks preserve a non-overlapping human edit")
    func nonOverlappingHumanEditIsPreserved() throws {
        let before = data(
            "human-old\nstable-a\nstable-b\nold\nstable-c\nstable-d\n"
        )
        let after = data(
            "human-old\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
        )
        let current = data(
            "human-new\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
        )
        let expected = data(
            "human-new\nstable-a\nstable-b\nold\nstable-c\nstable-d\n"
        )
        let patch = try singlePatch(before: before, after: after)

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: ["file.txt": current])
        )

        let applied = try #require(appliedSnapshot(result))
        #expect(applied.files["file.txt"] == expected)
    }

    @Test("A human edit overlapping an agent hunk fails closed")
    func overlappingHumanEditConflicts() throws {
        let before = data("a\nb\nold\nc\nd\n")
        let after = data("a\nb\nagent\nc\nd\n")
        let current = data("a\nb\nhuman-overlap\nc\nd\n")
        let patch = try singlePatch(before: before, after: after)

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: ["file.txt": current])
        )

        let conflicts = try #require(conflicts(result))
        #expect(conflicts.count == 1)
        #expect(conflicts[0].reason == .textContextMissing(hunkIndex: 0))
    }

    @Test("Duplicate checked context is ambiguous and fails closed")
    func duplicateContextConflicts() throws {
        let before = data("a\nb\nold\nc\nd\n")
        let after = data("a\nb\nagent\nc\nd\n")
        let current = data(
            "a\nb\nagent\nc\nd\nhuman\n"
                + "a\nb\nagent\nc\nd\n"
        )
        let patch = try singlePatch(before: before, after: after)

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: ["file.txt": current])
        )

        let conflicts = try #require(conflicts(result))
        #expect(conflicts[0].reason == .ambiguousTextContext(hunkIndex: 0))
    }

    @Test("CRLF and a missing final newline survive hunk application")
    func crlfAndNoFinalNewline() throws {
        let before = data(
            "human-old\r\nstable-a\r\nstable-b\r\nold\r\n"
                + "stable-c\r\nlast"
        )
        let after = data(
            "human-old\r\nstable-a\r\nstable-b\r\nagent\r\n"
                + "stable-c\r\nlast"
        )
        let current = data(
            "human-new\r\nstable-a\r\nstable-b\r\nagent\r\n"
                + "stable-c\r\nlast"
        )
        let expected = data(
            "human-new\r\nstable-a\r\nstable-b\r\nold\r\n"
                + "stable-c\r\nlast"
        )
        let patch = try singlePatch(before: before, after: after)

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: ["file.txt": current])
        )

        let applied = try #require(appliedSnapshot(result))
        #expect(applied.files["file.txt"] == expected)
        let preview = VerifiedPatchEngine.previewInverse(patch)
        #expect(preview[0].hunks[0].lines.contains {
            $0.bytes == data("agent\r\n")
        })
        #expect(preview[0].hunks[0].lines.last?.bytes == data("last"))
    }

    @Test("Create and delete use exact-state inverse fallbacks")
    func createAndDeleteExactFallbacks() throws {
        let created = data("created")
        let deleted = data("deleted")
        let createTransition = transition(
            path: "created.txt",
            before: nil,
            after: created
        )
        let deleteTransition = transition(
            path: "deleted.txt",
            before: deleted,
            after: nil
        )
        let binding = try makeBinding(events: [
            VerifiedPatchEventReference(
                envelopeID: id(2),
                cursorValue: 1,
                transitions: [createTransition]
            ),
            VerifiedPatchEventReference(
                envelopeID: id(3),
                cursorValue: 2,
                transitions: [deleteTransition]
            )
        ])
        let patch = try VerifiedPatchEngine.makePatch(
            id: id(1),
            binding: binding,
            operations: [
                VerifiedPatchSourceOperation(
                    eventEnvelopeID: id(3),
                    sourcePath: "deleted.txt",
                    beforeContent: deleted,
                    afterContent: nil
                ),
                VerifiedPatchSourceOperation(
                    eventEnvelopeID: id(2),
                    sourcePath: "created.txt",
                    beforeContent: nil,
                    afterContent: created
                )
            ]
        )

        let previews = VerifiedPatchEngine.previewInverse(patch)
        #expect(previews.map(\.kind) == [
            .removeCreatedFile,
            .restoreDeletedFile
        ])
        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(
                files: ["created.txt": created]
            )
        )
        let applied = try #require(appliedSnapshot(result))
        #expect(applied.files["created.txt"] == nil)
        #expect(applied.files["deleted.txt"] == deleted)
    }

    @Test("A diverged created file is never removed")
    func divergedCreateConflicts() throws {
        let patch = try singlePatch(
            before: nil,
            after: data("agent-created")
        )
        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(
                files: ["file.txt": data("human-edited")]
            )
        )

        let found = try #require(conflicts(result))
        #expect(found[0].reason == .exactStateDiverged)
    }

    @Test("Binary changes require an exact after-state")
    func binaryExactFallback() throws {
        let before = Data([0x00, 0x01, 0x02])
        let after = Data([0x00, 0x03, 0x04])
        let patch = try singlePatch(before: before, after: after)
        #expect(VerifiedPatchEngine.previewInverse(patch)[0].kind
            == .restoreExactBytes)

        let exact = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: ["file.txt": after])
        )
        #expect(try #require(appliedSnapshot(exact)).files["file.txt"]
            == before)

        let diverged = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(
                files: ["file.txt": Data([0x00, 0x03, 0x05])]
            )
        )
        #expect(try #require(conflicts(diverged))[0].reason
            == .exactStateDiverged)
    }

    @Test("Rename inversion is exact and preserves unrelated files")
    func renameExactFallback() throws {
        let before = data("original")
        let after = data("renamed")
        let eventID = id(2)
        let contentTransition = VerifiedPatchContentTransition(
            sourcePath: "old.txt",
            destinationPath: "new.txt",
            beforeIdentity: ContentIdentity(content: before),
            afterIdentity: ContentIdentity(content: after)
        )
        let binding = try makeBinding(events: [
            VerifiedPatchEventReference(
                envelopeID: eventID,
                cursorValue: 1,
                transitions: [contentTransition]
            )
        ])
        let patch = try VerifiedPatchEngine.makePatch(
            id: id(1),
            binding: binding,
            operations: [
                VerifiedPatchSourceOperation(
                    eventEnvelopeID: eventID,
                    sourcePath: "old.txt",
                    destinationPath: "new.txt",
                    beforeContent: before,
                    afterContent: after
                )
            ]
        )

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: VerifiedPatchWorkspaceSnapshot(files: [
                "new.txt": after,
                "keep.txt": data("keep")
            ])
        )
        let applied = try #require(appliedSnapshot(result))
        #expect(applied.files["new.txt"] == nil)
        #expect(applied.files["old.txt"] == before)
        #expect(applied.files["keep.txt"] == data("keep"))
        #expect(VerifiedPatchEngine.previewInverse(patch)[0].kind
            == .restoreRenamedFile)
    }

    @Test("One conflict keeps a multi-operation inverse atomic")
    func multiOperationConflictIsAtomic() throws {
        let firstBefore = data("one-before")
        let firstAfter = data("one-after")
        let secondBefore = data("two-before")
        let secondAfter = data("two-after")
        let binding = try makeBinding(events: [
            event(
                id: id(2),
                cursor: 1,
                path: "one.bin",
                before: firstBefore,
                after: firstAfter
            ),
            event(
                id: id(3),
                cursor: 2,
                path: "two.bin",
                before: secondBefore,
                after: secondAfter
            )
        ])
        let patch = try VerifiedPatchEngine.makePatch(
            id: id(1),
            binding: binding,
            operations: [
                source(
                    eventID: id(2),
                    path: "one.bin",
                    before: firstBefore,
                    after: firstAfter
                ),
                source(
                    eventID: id(3),
                    path: "two.bin",
                    before: secondBefore,
                    after: secondAfter
                )
            ]
        )
        let original = VerifiedPatchWorkspaceSnapshot(files: [
            "one.bin": firstAfter,
            "two.bin": data("human")
        ])

        let result = VerifiedPatchEngine.applyCheckedInverse(
            patch,
            to: original
        )

        #expect(appliedSnapshot(result) == nil)
        #expect(try #require(conflicts(result))[0].path == "two.bin")
        #expect(original.files["one.bin"] == firstAfter)
    }

    @Test("Cursor replay and gaps are rejected by the binding")
    func cursorReplayAndGap() throws {
        let contentTransition = transition(
            path: "file.txt",
            before: data("a"),
            after: data("b")
        )
        #expect(throws: VerifiedPatchValidationError.cursorReplay(1)) {
            try makeBinding(events: [
                VerifiedPatchEventReference(
                    envelopeID: id(2),
                    cursorValue: 1,
                    transitions: [contentTransition]
                ),
                VerifiedPatchEventReference(
                    envelopeID: id(3),
                    cursorValue: 1,
                    transitions: [contentTransition]
                )
            ])
        }
        #expect(throws: VerifiedPatchValidationError.cursorGap(
            expected: 2,
            actual: 3
        )) {
            try makeBinding(events: [
                VerifiedPatchEventReference(
                    envelopeID: id(2),
                    cursorValue: 1,
                    transitions: [contentTransition]
                ),
                VerifiedPatchEventReference(
                    envelopeID: id(3),
                    cursorValue: 3,
                    transitions: [contentTransition]
                )
            ])
        }
    }

    @Test("Captured bytes must match the event content identities")
    func eventIdentityMismatchIsRejected() throws {
        let binding = try makeBinding(events: [
            event(
                id: id(2),
                cursor: 1,
                path: "file.txt",
                before: data("before"),
                after: data("after")
            )
        ])

        #expect(throws: VerifiedPatchValidationError.unboundOperation) {
            try VerifiedPatchEngine.makePatch(
                id: id(1),
                binding: binding,
                operations: [
                    source(
                        eventID: id(2),
                        path: "file.txt",
                        before: data("different-before"),
                        after: data("after")
                    )
                ]
            )
        }
    }
}

@Suite("Verified Patch Version Chains")
struct VerifiedPatchVersionChainTests {
    @Test("Two agents branching from one file version conflict")
    func twoAgentOverlapConflicts() throws {
        let base = data("base")
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            before: base,
            after: data("agent-a"),
            sessionID: id(11),
            terminalID: id(21)
        )
        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(4),
            before: base,
            after: data("agent-b"),
            sessionID: id(12),
            terminalID: id(22)
        )

        let result = VerifiedPatchVersionChainDetector.analyze([
            second,
            first
        ])

        let found = try #require(versionConflicts(result))
        #expect(found.contains {
            $0.path == "file.txt"
                && $0.reason == .ambiguousVersionChain
        })
    }

    @Test("Two agents with an exact content chain are ordered")
    func exactMultiAgentChainIsAccepted() throws {
        let base = data("base")
        let middle = data("agent-a")
        let final = data("agent-b")
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            before: base,
            after: middle,
            sessionID: id(11),
            terminalID: id(21)
        )
        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(4),
            before: middle,
            after: final,
            sessionID: id(12),
            terminalID: id(22)
        )

        let result = VerifiedPatchVersionChainDetector.analyze([
            second,
            first
        ])

        guard case .valid(let report) = result else {
            Issue.record("Expected a valid exact version chain")
            return
        }
        let pathScope = VerifiedPatchPathScope(
            projectID: id(10),
            worktreePath: "/tmp/project",
            relativePath: "file.txt"
        )
        #expect(report.orderedPatchIDsByPath[pathScope]
            == [first.id, second.id])
    }

    @Test("Identical relative paths in separate worktrees do not overlap")
    func separateWorktreesDoNotConflict() throws {
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            before: data("base"),
            after: data("agent-a"),
            worktreePath: "/tmp/first"
        )
        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(4),
            before: data("base"),
            after: data("agent-b"),
            worktreePath: "/tmp/second"
        )

        let result = VerifiedPatchVersionChainDetector.analyze([
            first,
            second
        ])

        guard case .valid(let report) = result else {
            Issue.record("Separate worktrees must not share a version chain")
            return
        }
        #expect(report.orderedPatchIDsByPath.isEmpty)
    }

    @Test("Separate patches in one process detect cursor gaps")
    func streamCursorGapConflicts() throws {
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            cursor: 1,
            path: "one.txt",
            before: data("a"),
            after: data("b")
        )
        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(4),
            cursor: 3,
            path: "two.txt",
            before: data("c"),
            after: data("d")
        )

        let result = VerifiedPatchVersionChainDetector.analyze([
            first,
            second
        ])

        let found = try #require(versionConflicts(result))
        #expect(found.contains {
            $0.reason == .cursorGap(expected: 2, actual: 3)
        })
    }

    @Test("Envelope replay across patch sets is detected")
    func envelopeReplayConflicts() throws {
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(2),
            path: "one.txt",
            before: data("a"),
            after: data("b")
        )
        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(2),
            path: "two.txt",
            before: data("c"),
            after: data("d"),
            sessionID: id(12),
            terminalID: id(22)
        )

        let result = VerifiedPatchVersionChainDetector.analyze([
            first,
            second
        ])

        let found = try #require(versionConflicts(result))
        #expect(found.contains {
            $0.reason == .replayedEnvelope(id(2))
        })
    }
}

private func singlePatch(
    patchID: UUID = id(1),
    envelopeID: UUID = id(2),
    cursor: UInt64 = 1,
    path: String = "file.txt",
    before: Data?,
    after: Data?,
    sessionID: UUID = id(11),
    terminalID: UUID = id(21),
    projectID: UUID = id(10),
    worktreePath: String = "/tmp/project"
) throws -> VerifiedPatchSet {
    let binding = try makeBinding(
        events: [
            event(
                id: envelopeID,
                cursor: cursor,
                path: path,
                before: before,
                after: after
            )
        ],
        sessionID: sessionID,
        terminalID: terminalID,
        projectID: projectID,
        worktreePath: worktreePath
    )
    return try VerifiedPatchEngine.makePatch(
        id: patchID,
        binding: binding,
        operations: [
            source(
                eventID: envelopeID,
                path: path,
                before: before,
                after: after
            )
        ]
    )
}

private func makeBinding(
    events: [VerifiedPatchEventReference],
    sessionID: UUID = id(11),
    terminalID: UUID = id(21),
    projectID: UUID = id(10),
    worktreePath: String = "/tmp/project"
) throws -> VerifiedPatchEventBinding {
    try VerifiedPatchEventBinding(
        projectID: projectID,
        worktreePath: worktreePath,
        sessionID: sessionID,
        process: AgentProcessIdentity(
            terminalID: terminalID,
            processGeneration: 1
        ),
        events: events
    )
}

private func event(
    id eventID: UUID,
    cursor: UInt64,
    path: String,
    before: Data?,
    after: Data?
) -> VerifiedPatchEventReference {
    VerifiedPatchEventReference(
        envelopeID: eventID,
        cursorValue: cursor,
        transitions: [
            transition(
                path: path,
                before: before,
                after: after
            )
        ]
    )
}

private func transition(
    path: String,
    before: Data?,
    after: Data?
) -> VerifiedPatchContentTransition {
    VerifiedPatchContentTransition(
        sourcePath: path,
        beforeIdentity: before.map(ContentIdentity.init),
        afterIdentity: after.map(ContentIdentity.init)
    )
}

private func source(
    eventID: UUID,
    path: String,
    before: Data?,
    after: Data?
) -> VerifiedPatchSourceOperation {
    VerifiedPatchSourceOperation(
        eventEnvelopeID: eventID,
        sourcePath: path,
        beforeContent: before,
        afterContent: after
    )
}

private func appliedSnapshot(
    _ result: VerifiedCheckedInverseResult
) -> VerifiedPatchWorkspaceSnapshot? {
    guard case .applied(let snapshot, _) = result else { return nil }
    return snapshot
}

private func conflicts(
    _ result: VerifiedCheckedInverseResult
) -> [VerifiedPatchConflict]? {
    guard case .conflicted(let conflicts) = result else { return nil }
    return conflicts
}

private func versionConflicts(
    _ result: VerifiedPatchVersionChainResult
) -> [VerifiedPatchVersionConflict]? {
    guard case .conflicted(let conflicts) = result else { return nil }
    return conflicts
}

private func data(_ value: String) -> Data {
    Data(value.utf8)
}

private func id(_ value: UInt8) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, value
    ))
}
