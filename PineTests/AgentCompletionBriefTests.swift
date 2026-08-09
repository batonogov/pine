//
//  AgentCompletionBriefTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Completion Brief")
@MainActor
struct AgentCompletionBriefTests {
    @Test("Terminal text never manufactures a verified test result")
    func terminalTextIsNotVerified() {
        let sessionID = id(1)
        let action = AgentAction(
            sessionID: sessionID,
            agentType: .codex,
            kind: .command,
            status: .completed,
            summary: "xcodebuild test -scheme Pine"
        )

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(sessionID: sessionID, paths: ["Pine/App.swift"]),
            evidence: AgentCompletionBriefEvidence(activities: [action])
        )

        #expect(brief.commands.count == 1)
        #expect(brief.commands[0].kind == .test)
        #expect(brief.commands[0].outcome == .unknown)
        #expect(brief.commands[0].attribution == .inferred)
        #expect(brief.verifiedTestCount == 0)
        #expect(brief.gaps.contains(.noVerifiedTests))
    }

    @Test("Structured exit status is retained with its verified source")
    func structuredCommandResult() {
        let sessionID = id(2)
        let event = storedEvent(
            sessionID: sessionID,
            cursor: 1,
            payload: .commandResult(AgentCommandResult(
                command: "xcodebuild test -scheme Pine",
                exitStatus: 0
            ))
        )

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(sessionID: sessionID),
            evidence: AgentCompletionBriefEvidence(
                provenanceIntegrity: .healthy,
                events: [event]
            )
        )

        #expect(brief.commands.count == 1)
        #expect(brief.commands[0].outcome == .succeeded)
        #expect(brief.commands[0].attribution == .verified)
        #expect(brief.commands[0].source == "explicitAgentEvent")
        #expect(brief.verifiedTestCount == 1)
        #expect(!brief.gaps.contains(.noStructuredCommands))
        #expect(!brief.gaps.contains(.noVerifiedTests))
    }

    @Test("Quoted runner names cannot manufacture a verified test result")
    func quotedRunnerNameIsNotATest() {
        let sessionID = id(21)
        let decoys = [
            "echo \"go test ./...\"",
            "printf 'pytest\\n'",
            "echo xcodebuild test",
        ]
        let events = decoys.enumerated().map { index, command in
            storedEvent(
                sessionID: sessionID,
                cursor: UInt64(index + 1),
                payload: .commandResult(AgentCommandResult(
                    command: command,
                    exitStatus: 0
                ))
            )
        }

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(sessionID: sessionID),
            evidence: AgentCompletionBriefEvidence(
                provenanceIntegrity: .healthy,
                events: events
            )
        )

        #expect(brief.commands.map(\.kind) == [.command, .command, .command])
        #expect(brief.verifiedTestCount == 0)
        #expect(brief.gaps.contains(.noVerifiedTests))
    }

    @Test("Simple runner invocations retain build and test classification")
    func simpleRunnerInvocationsClassify() {
        let sessionID = id(22)
        let commands = [
            "DEVELOPER_DIR=/Applications/Xcode.app /usr/bin/xcodebuild -project Pine.xcodeproj test",
            "/usr/local/go/bin/go test ./...",
            "npm run build",
            "xcodebuild -scheme Pine build-for-testing",
        ]
        let events = commands.enumerated().map { index, command in
            storedEvent(
                sessionID: sessionID,
                cursor: UInt64(index + 1),
                payload: .commandResult(AgentCommandResult(
                    command: command,
                    exitStatus: 0
                ))
            )
        }

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(sessionID: sessionID),
            evidence: AgentCompletionBriefEvidence(
                provenanceIntegrity: .healthy,
                events: events
            )
        )

        #expect(brief.commands.map(\.kind) == [.test, .test, .build, .build])
        #expect(brief.verifiedTestCount == 2)
    }

    @Test("Completion statistics invert the checked undo preview")
    func exactStatsAndNarrativeLabel() {
        let sessionID = id(3)
        let preview = AgentHistoryUndoPreviewModel(
            historyEntryID: id(30),
            operations: [previewOperation(
                path: "Pine/App.swift",
                inverseAdded: 2,
                inverseRemoved: 5
            )]
        )

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(
                entryID: id(30),
                sessionID: sessionID,
                paths: ["Pine/App.swift"]
            ),
            evidence: AgentCompletionBriefEvidence(
                verifiedUndoPreview: preview,
                agentReportedNarrative: "Implemented the requested feature."
            )
        )

        #expect(brief.changes.count == 1)
        #expect(brief.changes[0].statistics == AgentCompletionDiffStatistics(
            addedLineCount: 5,
            removedLineCount: 2
        ))
        #expect(brief.changes[0].hasVerifiedDiff)
        #expect(brief.narrative?.attribution == .agentReported)
        #expect(brief.links.diffPaths == ["Pine/App.swift"])
    }

    @Test("Ambiguous writers remain ambiguous and disclose overlap")
    func ambiguityAndOverlap() {
        let sessionID = id(4)
        let otherSessionID = id(5)
        let root = URL(fileURLWithPath: "/tmp/project")
        let action = AgentAction(
            attribution: .ambiguous(candidates: [
                AgentActionCandidate(sessionID: sessionID, agentType: .codex),
                AgentActionCandidate(
                    sessionID: otherSessionID,
                    agentType: .claudeCode
                )
            ]),
            kind: .fileWrite,
            fileURL: root.appendingPathComponent("shared.swift"),
            summary: "shared.swift"
        )
        let scopeEvent = storedEvent(
            sessionID: sessionID,
            cursor: 1,
            payload: .none,
            worktree: root.path
        )

        let brief = AgentCompletionBriefBuilder.build(
            entry: history(
                sessionID: sessionID,
                paths: ["shared.swift"]
            ),
            evidence: AgentCompletionBriefEvidence(
                provenanceIntegrity: .healthy,
                events: [scopeEvent],
                activities: [action]
            )
        )

        #expect(brief.changes[0].attribution == .ambiguous)
        #expect(brief.changes[0].hasOverlappingEdits)
        #expect(brief.gaps.contains(.overlappingEdits(paths: ["shared.swift"])))
    }

    @Test("Recovered provenance and missing statistics are explicit gaps")
    func unverifiableGaps() {
        let report = AgentEventCorruptionReport(
            kind: .truncatedFrame,
            retainedRecordCount: 1,
            discardedByteCount: 20,
            quarantinedByteCount: 20,
            quarantineFileName: "events.quarantine"
        )
        let brief = AgentCompletionBriefBuilder.build(
            entry: history(sessionID: id(6), paths: ["unknown.bin"]),
            evidence: AgentCompletionBriefEvidence(
                provenanceIntegrity: .recovered(report)
            )
        )

        #expect(brief.gaps.contains(.provenanceRecoveredWithLoss))
        #expect(brief.gaps.contains(.noVerifiedChanges))
        #expect(brief.gaps.contains(.diffStatisticsUnavailable(
            paths: ["unknown.bin"]
        )))
    }

    private func history(
        entryID: UUID? = nil,
        sessionID: UUID,
        paths: [String] = []
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            id: entryID ?? id(20),
            sessionID: sessionID,
            agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            affectedFiles: paths,
            summary: "Observed completion"
        )
    }

    private func storedEvent(
        sessionID: UUID,
        cursor: UInt64,
        payload: AgentEventPayload,
        worktree: String = "/tmp/project"
    ) -> StoredAgentEvent {
        StoredAgentEvent(
            sequence: cursor,
            envelope: AgentEventEnvelope(
                id: id(Int(cursor) + 100),
                projectID: id(90),
                sessionID: sessionID,
                agentTypeRaw: "codex",
                process: AgentProcessIdentity(
                    terminalID: id(91),
                    processGeneration: 1
                ),
                location: AgentEventLocation(
                    worktreePath: worktree,
                    cwd: worktree
                ),
                cursorValue: cursor,
                timestamp: Date(timeIntervalSince1970: 150),
                source: .explicitAgentEvent,
                trustLevel: .verified,
                payload: payload
            )
        )
    }

    private func previewOperation(
        path: String,
        inverseAdded: Int,
        inverseRemoved: Int
    ) -> AgentHistoryUndoPreviewOperation {
        var lines: [AgentHistoryUndoPreviewHunk.Line] = []
        for index in 0..<inverseAdded {
            lines.append(AgentHistoryUndoPreviewHunk.Line(
                id: index,
                kind: .add,
                text: "+",
                lineEnding: .lf
            ))
        }
        for index in 0..<inverseRemoved {
            lines.append(AgentHistoryUndoPreviewHunk.Line(
                id: inverseAdded + index,
                kind: .remove,
                text: "-",
                lineEnding: .lf
            ))
        }
        return AgentHistoryUndoPreviewOperation(
            id: path,
            relativePath: path,
            kind: .restoreModifiedFile,
            contentRepresentation: .textual,
            hunks: [AgentHistoryUndoPreviewHunk(
                id: 0,
                header: "@@ -1 +1 @@",
                lines: lines
            )],
            expectedContentSHA256: String(repeating: "a", count: 64),
            expectedByteCount: 1,
            expectedPermissions: 0o644,
            resultContentSHA256: String(repeating: "b", count: 64),
            resultByteCount: 1,
            resultPermissions: 0o644,
            previewDevice: 1,
            previewInode: 1
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0,
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ))
    }
}
