//
//  AgentTaskContractTestSupport.swift
//  PineTests
//
//  Shared deterministic fixtures for the ADE contract tests (#1722):
//  state table, legacy .done migration, hydration barrier, crash ordering,
//  and the data policy. Kept separate from
//  AgentTaskLifecycleEvidenceTests so the contract suites stay additive.
//

import Foundation
import Testing
@testable import Pine

/// Armed fault: throws at EVERY agent-task store `beforeSync` write seam
/// while armed (no auto-disarm; the test disarms explicitly), modelling a
/// crash after the temporary file is written but before durability.
nonisolated final class ArmedADEWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    nonisolated func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    nonisolated func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    nonisolated func throwWhileArmed(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        lock.lock()
        let shouldFire = armed
        lock.unlock()
        guard shouldFire, store == .agentTask, phase == .beforeSync else {
            return
        }
        throw PersistenceFailureKind.noSpace
    }
}

/// Temp-directory fixture with a clean user-owned parent (no inherited
/// ACLs), mirroring the persistence fixtures' requirements.
final class ADEContractPersistenceFixture {
    let root: URL
    let project: URL
    let storage: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineADEContract-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        storage = root.appendingPathComponent("storage", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-N", root.path]
            let output = try runProcessBounded(
                chmod,
                commandDescription: "chmod -N \(root.path)"
            )
            guard output.terminationStatus == 0 else {
                try? fileManager.removeItem(at: root)
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.createDirectory(
                at: project,
                withIntermediateDirectories: false
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Deterministic value fixtures for ADE contract tests.
enum ADEContractFixtures {
    static func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    static func codeState(
        _ tag: Character,
        head: String = String(repeating: "b", count: 40)
    ) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: head,
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    static var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("c")
        )
    }

    static func project(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: URL(fileURLWithPath: path)
                .standardizedFileURL.path,
            canonicalWorktreePath: URL(fileURLWithPath: path)
                .standardizedFileURL.path
        )
    }

    static func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    /// One attempt with honest chronology. `now` is pinned to the file's
    /// fixed epoch for determinism; callers that route the task through a
    /// registry LOAD must pass a recent wall-clock `now`, or the 7-day
    /// retention sweep dismisses the settled task mid-test.
    static func makeAttempt(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentTaskRunInput {
        AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "ade-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: now
            ),
            lifecycleAccuracy: accuracy
        )
    }

    static func makeTask(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        outcome: AgentTaskOutcome? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-ade-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: liveness == .live ? .available : .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        var run = AgentTaskRun(makeAttempt(
            seed: seed,
            state: state,
            liveness: liveness,
            accuracy: accuracy,
            now: now
        ))
        run.outcome = outcome
        task.runs = [run]
        task.lifecycle = liveness == .terminated ? .paused : .active
        task.updatedAt = now
        task.lastActivityAt = now
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return task
    }

    static func fact(
        _ kind: AgentTaskEvidenceKind,
        runID: UUID,
        generation: UInt64,
        result: AgentTaskEvidenceResult,
        at: Date,
        trust: TrustLevel = .verified,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        sequence: UInt64? = nil,
        vendorSession: AgentVendorSessionIdentity? = nil,
        pre: AgentTaskCodeStateIdentity? = nil,
        post: AgentTaskCodeStateIdentity? = nil
    ) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: kind,
            runID: runID,
            processGeneration: generation,
            trust: trust,
            result: result,
            observedAt: at,
            codeState: codeState,
            environment: environment,
            vendorSession: vendorSession,
            sourceSequence: sequence,
            preOperationCodeState: pre,
            postOperationCodeState: post
        )
    }

    /// A settled (terminated, outcome recorded, process-completion fact
    /// bound) task, as production settlement produces it. `now` is pinned to
    /// the file's fixed epoch by default; pass a recent wall-clock date when
    /// the task will be loaded through a registry (retention sweep).
    static func settledTask(
        seed: Int,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) -> AgentTask {
        var task = makeTask(
            seed: seed,
            accuracy: accuracy,
            now: now,
            projectPath: projectPath ?? "/tmp/pine-ade-\(seed)"
        )
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        return task
    }

    /// A verified-success task: claim plus passing check and review bound
    /// to one shared code-state identity. `now` is pinned to the file's
    /// fixed epoch by default; pass a recent wall-clock date when the task
    /// will be loaded through a registry (retention sweep).
    static func verifiedSuccessTask(
        seed: Int,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) throws -> AgentTask {
        var task = settledTask(seed: seed, now: now, projectPath: projectPath)
        let run = try #require(task.runs.first)
        let t = now
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(seed),
            result: .reported,
            at: t,
            codeState: codeState,
            environment: environment,
            sequence: 1
        ))
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(1),
            codeState: codeState,
            environment: environment,
            sequence: 2,
            pre: codeState,
            post: codeState
        ))
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: codeState,
            environment: environment,
            sequence: 3,
            pre: codeState,
            post: codeState
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        return task
    }

    /// A session fixture for registry bridges (same shape as the
    /// lifecycle suite's fixture).
    static func makeSession(
        pid: Int32,
        generation: UInt64,
        start: String = "Mon Aug 3 10:00:00 2026",
        observedAt: Date? = nil
    ) -> AgentSession {
        let session = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            lifecycleAccuracy: .processTerminationOnly,
            startedAt: observedAt ?? Date(timeIntervalSince1970: TimeInterval(generation)),
            lastObservedAt: observedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: pid,
            processGeneration: generation,
            startIdentifier: start,
            observedStartedAt: observedAt ?? Date(timeIntervalSince1970: 0),
            startIsAuthoritative: true
        ))
        return session
    }
}
