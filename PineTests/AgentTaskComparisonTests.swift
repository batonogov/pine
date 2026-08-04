//
//  AgentTaskComparisonTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Task Comparison and Handoff")
@MainActor
struct AgentTaskComparisonTests {
    @Test("Comparison keeps facts and narratives separate without ranking")
    func comparisonIsFactOnly() throws {
        let left = task(path: "/tmp/repo/left", objective: "Implement feature")
        let right = task(path: "/tmp/repo/right", objective: "Implement feature")
        let leftBrief = brief(
            task: left,
            path: "Pine/Left.swift",
            verifiedTests: 1,
            narrative: "I think this is best."
        )
        let rightBrief = brief(
            task: right,
            path: "Pine/Right.swift",
            failedCommands: 1
        )

        let result = AgentTaskComparisonBuilder.build(
            leftTask: left,
            leftBrief: leftBrief,
            rightTask: right,
            rightBrief: rightBrief
        )
        let comparison = try success(result)

        #expect(comparison.objective == "Implement feature")
        #expect(comparison.left.changedFiles.map(\.relativePath)
            == ["Pine/Left.swift"])
        #expect(comparison.left.verifiedTestCount == 1)
        #expect(comparison.left.agentReportedNarrative?.attribution
            == .agentReported)
        #expect(comparison.right.failedCommandCount == 1)
        #expect(!Mirror(reflecting: comparison).children.contains {
            $0.label == "winner" || $0.label == "recommendation"
        })
    }

    @Test("Comparison rejects cross-project and mismatched session evidence")
    func comparisonScopeValidation() {
        let left = task(project: "/tmp/one", path: "/tmp/one/left")
        let right = task(project: "/tmp/two", path: "/tmp/two/right")
        let leftBrief = brief(task: left, path: "a.swift")
        let rightBrief = brief(task: right, path: "b.swift")

        #expect(AgentTaskComparisonBuilder.build(
            leftTask: left,
            leftBrief: leftBrief,
            rightTask: right,
            rightBrief: rightBrief
        ) == .failure(.differentProject))

        let sameProjectRight = task(
            project: "/tmp/one",
            path: "/tmp/one/right"
        )
        #expect(AgentTaskComparisonBuilder.build(
            leftTask: left,
            leftBrief: leftBrief,
            rightTask: sameProjectRight,
            rightBrief: rightBrief
        ) == .failure(.briefDoesNotBelongToTask(sameProjectRight.id)))
    }

    @Test("Handoff copies only fresh user intent and attribution references")
    func handoffDoesNotCopyTranscriptOrSecrets() throws {
        let source = task(
            path: "/tmp/repo/source",
            objective: "SECRET source objective and full transcript"
        )
        let target = task(path: "/tmp/repo/target")
        let sourceBrief = brief(
            task: source,
            path: "Pine/Feature.swift",
            narrative: "SECRET agent narrative"
        )
        let request = AgentTaskHandoffRequest(
            sourceTaskID: source.id,
            targetTaskID: target.id,
            sourceCompletionBriefID: sourceBrief.id,
            followUpObjective: "  Review the verified change.  ",
            selectedEvidencePaths: ["Pine/Feature.swift"]
        )

        let package = try handoff(AgentTaskHandoffPlanner.prepare(
            request: request,
            sourceTask: source,
            targetTask: target,
            sourceBrief: sourceBrief,
            handoffID: id(40),
            createdAt: Date(timeIntervalSince1970: 500)
        ))

        #expect(package.followUpObjective == "Review the verified change.")
        #expect(package.priorAttribution == [AgentTaskHandoffAttribution(
            relativePath: "Pine/Feature.swift",
            sourceTaskID: source.id,
            sourceSessionID: sourceBrief.sessionID,
            originalEvidence: .verified
        )])
        let labels = Set(Mirror(reflecting: package).children.compactMap(\.label))
        #expect(labels.isDisjoint(with: [
            "transcript", "environment", "credentials", "narrative",
            "commandOutput", "sourceObjective",
        ]))
        #expect(!package.followUpObjective.contains("SECRET"))
    }

    @Test("Handoff paths and objective fail closed")
    func invalidHandoffFailsClosed() {
        let source = task(path: "/tmp/repo/source")
        let target = task(path: "/tmp/repo/target")
        let sourceBrief = brief(task: source, path: "Pine/Feature.swift")

        func request(
            objective: String = "Review",
            paths: [String]
        ) -> AgentTaskHandoffRequest {
            AgentTaskHandoffRequest(
                sourceTaskID: source.id,
                targetTaskID: target.id,
                sourceCompletionBriefID: sourceBrief.id,
                followUpObjective: objective,
                selectedEvidencePaths: paths
            )
        }

        #expect(AgentTaskHandoffPlanner.prepare(
            request: request(paths: ["../escape"]),
            sourceTask: source,
            targetTask: target,
            sourceBrief: sourceBrief
        ) == .failure(.invalidEvidencePath("../escape")))
        #expect(AgentTaskHandoffPlanner.prepare(
            request: request(paths: ["unknown.swift"]),
            sourceTask: source,
            targetTask: target,
            sourceBrief: sourceBrief
        ) == .failure(.evidencePathNotInBrief("unknown.swift")))
        #expect(AgentTaskHandoffPlanner.prepare(
            request: request(
                objective: "bad\u{0}objective",
                paths: ["Pine/Feature.swift"]
            ),
            sourceTask: source,
            targetTask: target,
            sourceBrief: sourceBrief
        ) == .failure(.invalidObjective))
    }

    private func task(
        project: String = "/tmp/repo",
        path: String,
        objective: String? = nil
    ) -> AgentTask {
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: project,
                    canonicalWorktreePath: path
                ),
                route: AgentTaskRoute(
                    paneID: UUID(),
                    tabID: UUID(),
                    terminalID: UUID()
                ),
                origin: .pineLaunched,
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            objective: objective,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let sessionID = UUID()
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: sessionID,
            terminalID: task.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: 123,
                processGeneration: 1,
                startIdentifier: "start",
                observedStartedAt: Date(timeIntervalSince1970: 100),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .done,
                liveness: .terminated,
                observedAt: Date(timeIntervalSince1970: 200)
            )
        ))]
        return task
    }

    private func brief(
        task: AgentTask,
        path: String,
        verifiedTests: Int = 0,
        failedCommands: Int = 0,
        narrative: String? = nil
    ) -> AgentCompletionBrief {
        var commands: [AgentCompletionCommand] = []
        for _ in 0..<verifiedTests {
            commands.append(AgentCompletionCommand(
                id: UUID(),
                command: "swift test",
                kind: .test,
                outcome: .succeeded,
                attribution: .verified,
                source: "explicitAgentEvent"
            ))
        }
        for _ in 0..<failedCommands {
            commands.append(AgentCompletionCommand(
                id: UUID(),
                command: "swift build",
                kind: .build,
                outcome: .failed(exitStatus: 1),
                attribution: .verified,
                source: "explicitAgentEvent"
            ))
        }
        let sessionID = task.runs.first?.id ?? UUID()
        return AgentCompletionBrief(
            id: UUID(),
            sessionID: sessionID,
            agentTypeRaw: task.descriptor.typeIdentifier,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            changes: [AgentCompletionChange(
                relativePath: path,
                kind: .modified,
                statistics: AgentCompletionDiffStatistics(
                    addedLineCount: 2,
                    removedLineCount: 1
                ),
                attribution: .verified,
                hasOverlappingEdits: false,
                hasVerifiedDiff: true
            )],
            commands: commands,
            gaps: [],
            narrative: narrative.map(AgentCompletionNarrative.init),
            links: AgentCompletionEvidenceLinks(
                terminalID: task.route.terminalID,
                diffPaths: [path]
            )
        )
    }

    private func success(
        _ result: Result<AgentTaskComparison, AgentTaskComparisonFailure>
    ) throws -> AgentTaskComparison {
        switch result {
        case .success(let comparison): comparison
        case .failure(let failure): throw failure
        }
    }

    private func handoff(
        _ result: Result<AgentTaskHandoffPackage, AgentTaskHandoffFailure>
    ) throws -> AgentTaskHandoffPackage {
        switch result {
        case .success(let package): package
        case .failure(let failure): throw failure
        }
    }
}

private func id(_ value: Int) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 1, UInt8(value)
    ))
}
