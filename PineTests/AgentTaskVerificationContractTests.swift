//
//  AgentTaskVerificationContractTests.swift
//  PineTests
//
//  ADE verification orchestration contract (issue #1724): deterministic
//  integration scenarios over the durable task model and the registry's
//  persistence seams. Provider capabilities run as fake ports on the
//  coordinator's seam types; the real #1753/#1754/#1755 adapters plug into
//  the same ports, so these scenarios hold when the seams are wired.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE verification orchestration contract", .serialized)
struct AgentTaskVerificationContractTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "a", count: 40),
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26B131",
            toolchain: "Xcode 26.2",
            configurationFingerprint: hex("e")
        )
    }

    private func snapshot(
        _ state: AgentTaskCodeStateIdentity
    ) -> AgentVerificationIdentitySnapshot {
        AgentVerificationIdentitySnapshot(code: state, environment: environment)
    }

    private func checkObservation(
        _ state: AgentTaskCodeStateIdentity,
        requiredStatus: AgentTaskCheckObservation.Status
    ) -> AgentTaskCheckObservation {
        AgentTaskCheckObservation(
            results: [
                .init(fingerprint: hex("1"), required: true, status: requiredStatus),
                .init(fingerprint: hex("2"), required: false, status: .succeeded)
            ],
            preCodeState: state, postCodeState: state, environment: environment
        )
    }

    private func reviewObservation(
        _ outcome: AgentTaskReviewObservation.Outcome,
        _ state: AgentTaskCodeStateIdentity,
        post: AgentTaskCodeStateIdentity? = nil
    ) -> AgentTaskReviewObservation {
        AgentTaskReviewObservation(
            outcome: outcome,
            preCodeState: state, postCodeState: post ?? state, environment: environment
        )
    }

    /// One settled, terminated run with a completion claim bound to `state`,
    /// bridged into a real registry the way the detector delivers it.
    private func settledClaimedTask(
        in registry: AgentTaskRegistry,
        fixture: CoordinatorFixture,
        state: AgentTaskCodeStateIdentity,
        seed: Int
    ) throws -> AgentTask {
        let now = Date()
        let route = AgentTaskRoute(paneID: UUID(), tabID: UUID(), terminalID: UUID())
        let context = AgentTaskBridgeContext(
            project: fixture.project,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: now
        )
        let session = AgentSession(
            agentType: .claudeCode,
            state: .done,
            startedAt: now.addingTimeInterval(-300)
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(5_000 + seed),
            processGeneration: UInt64(seed),
            startIdentifier: "ade-contract-\(seed)",
            observedStartedAt: now.addingTimeInterval(-300),
            startIsAuthoritative: true
        ))
        registry.bridge(session, replacing: nil, context: context)
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])
        var task = try #require(registry.historicalTask(forSessionID: session.id))
        let run = try #require(task.runs.last)
        #expect(AgentTaskLifecycleReducer.isSettled(run))
        let claim = AgentTaskEvidenceFact(
            kind: .agentReportedCompletion,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: .reported,
            observedAt: now.addingTimeInterval(1),
            codeState: state,
            environment: environment
        )
        #expect(registry.recordEvidence(claim, taskID: task.id) == .accepted)
        task = try #require(registry.task(for: task.id))
        #expect(task.runs.last?.outcome == .unverified)
        return task
    }

    // MARK: - Scenario: checks pass + review pass -> Ready publishable

    @Test("checks pass and review pass publish Ready")
    func checksPassAndReviewPassPublishesReady() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 1
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let coordinator = probe.coordinator

        let result = await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(result.readiness.isReady)
        #expect(result.readiness.gaps.isEmpty)

        let settled = try #require(registry.task(for: task.id))
        #expect(settled.runs.last?.outcome == .success)
        #expect(settled.verificationState == .verified)
        for kind in AgentTaskLifecycleReducer.requiredEvidenceForSuccess {
            let fact = try #require(settled.evidence.first { $0.kind == kind })
            #expect(fact.codeState == state)
            #expect(fact.environment == environment)
            #expect(fact.preOperationCodeState == state)
            #expect(fact.postOperationCodeState == state)
        }
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
    }

    // MARK: - Scenario: checks stale after edit -> refused, names repeat work

    @Test("checks stale after edit refuse Ready and re-verification re-grant-gates")
    func staleChecksAfterEditAreRefusedAndReverified() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stateA = codeState("a")
        let stateB = codeState("b")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: stateA, seed: 2
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(stateA, requiredStatus: .succeeded),
            review: reviewObservation(.passed, stateA)
        )
        probe.anchor = snapshot(stateA)
        let coordinator = probe.coordinator
        #expect((await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)

        // A relevant edit: the recorded evidence no longer matches.
        let gaps = registry.invalidateEvidence(
            taskID: task.id, codeState: stateB, environment: environment
        )
        #expect(gaps.contains(.staleEvidence(.independentCheck)))
        #expect(gaps.contains(.staleEvidence(.reviewerOutcome)))
        let refused = registry.readiness(
            for: task.id, codeState: stateB, environment: environment
        )
        #expect(!refused.isReady)
        #expect(refused.gaps.contains(.staleEvidence(.independentCheck)))
        #expect(refused.gaps.contains(.staleEvidence(.reviewerOutcome)))

        // Re-verification revalidates the grant immediately before execution.
        let grantCallsBefore = probe.grantCalls
        probe.anchor = snapshot(stateB)
        probe.checkObservation = checkObservation(stateB, requiredStatus: .succeeded)
        probe.reviewObservation = reviewObservation(.passed, stateB)
        let result = await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(probe.grantCalls > grantCallsBefore)

        let reverified = try #require(registry.task(for: task.id))
        #expect(reverified.evidence.contains {
            $0.kind == .independentCheck && $0.codeState == stateB
                && $0.result == .succeeded
        })
        #expect(reverified.evidence.contains {
            $0.kind == .reviewerOutcome && $0.codeState == stateB
                && $0.result == .succeeded
        })
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
    }

    // MARK: - Scenario: review unresolved -> Needs decision, no Ready

    @Test("unresolved review escalates to Needs decision without Ready")
    func unresolvedReviewEscalatesWithoutReady() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 3
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.requestedChanges, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .needsDecision)
        #expect(result.reason == .reviewRequestedChanges)
        #expect(result.requiredAction == .resolveReviewFindings)
        #expect(!result.readiness.isReady)
        #expect(result.readiness.gaps.contains(.failedAttempt))

        let settled = try #require(registry.task(for: task.id))
        #expect(settled.runs.last?.outcome == .failure)
        #expect(settled.verificationState == .none)
        #expect(settled.evidence.contains {
            $0.kind == .reviewerOutcome && $0.result == .requestedChanges
        })
    }

    // MARK: - Scenario: cancelled run -> no Ready, no review

    @Test("a cancelled required check records no judgment and starts no review")
    func cancelledCheckProducesNoReadyAndNoReview() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 4
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .cancelled),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .cancelled)
        #expect(!result.readiness.isReady)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains {
            $0.kind == .independentCheck || $0.kind == .reviewerOutcome
        })
        #expect(settled.runs.last?.outcome == .unverified)
    }

    // MARK: - Scenario: missing grant -> explicit action, no execution

    @Test("a missing current grant offers the explicit grant action without executing")
    func missingGrantOffersExplicitActionWithoutExecution() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 5
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.grantIsCurrent = false
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .checkGrantNotCurrent)
        #expect(result.requiredAction == .approveCheckGrant)
        #expect(!result.readiness.isReady)
        #expect(probe.checkCalls == 0)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains {
            $0.kind == .independentCheck || $0.kind == .reviewerOutcome
        })
    }

    // MARK: - Scenario: crash between check and review evidence -> fail closed

    @Test("a crash between check evidence and review evidence fails closed")
    func crashBetweenCheckAndReviewEvidenceFailsClosed() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let fault = ArmedWriteFault()
        let registry = AgentTaskRegistry(
            persistence: fixture.store(injector: fault.injector)
        )
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 6
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.onReview = { fault.arm() }
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .persistenceUnavailable)
        #expect(!result.readiness.isReady)

        // Relaunch: the process died before the review evidence was durable.
        let revived = AgentTaskRegistry(persistence: fixture.store())
        revived.registerProject(fixture.project)
        #expect(await revived.flushPersistence() == .saved)
        let revivedTask = try #require(revived.task(for: task.id))
        #expect(revivedTask.evidence.contains {
            $0.kind == .independentCheck && $0.result == .succeeded
                && $0.codeState == state
        })
        #expect(!revivedTask.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(revivedTask.runs.last?.outcome == .unverified)
        let readiness = revived.readiness(
            for: task.id, codeState: state, environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
        #expect(readiness.gaps.contains(.missingEvidence(.reviewerOutcome)))
    }

    // MARK: - Scenario: restore and reads never execute verification

    @Test("restoring the app and reading readiness never execute checks or review")
    func restoreAndReadsNeverExecuteVerification() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 7
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        #expect((await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)
        let probesAfterPass = probe.totalCalls
        let grantsAfterPass = probe.grantCalls
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        // A fresh process restores from the same storage and reads readiness.
        // Relaunch is a fail-closed boundary (#1722): the restored task's
        // verification is normalized to .stale, so the durable evidence alone
        // cannot publish Ready without an explicit re-verification pass.
        let revived = AgentTaskRegistry(persistence: fixture.store())
        revived.registerProject(fixture.project)
        #expect(await revived.flushPersistence() == .saved)
        let revivedReadiness = revived.readiness(
            for: task.id, codeState: state, environment: environment
        )
        #expect(!revivedReadiness.isReady)
        #expect(revivedReadiness.gaps.contains(.verificationNotCurrent))

        // Opening/restoring/reading executed nothing: no port was touched.
        #expect(probe.totalCalls == probesAfterPass)
        #expect(probe.grantCalls == grantsAfterPass)
    }

    // MARK: - Scenario: reviewer-caused mutation is not an independent pass

    @Test("a review that observed a moving candidate is not an independent pass")
    func reviewOverAMovedCandidateRecordsNoJudgment() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stateA = codeState("a")
        let stateB = codeState("b")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: stateA, seed: 8
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(stateA, requiredStatus: .succeeded),
            review: reviewObservation(.passed, stateA, post: stateB)
        )
        probe.anchor = snapshot(stateA)
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .reviewNotObserved)
        #expect(result.requiredAction == .rerunReview)
        #expect(!result.readiness.isReady)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(settled.runs.last?.outcome == .unverified)
    }

    // MARK: - Scenario: infrastructure retries are bounded and re-grant-gated

    @Test("a transient check failure retries once, revalidated under the grant")
    func transientCheckFailureRetriesOnce() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 9
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.checkFailsBelowAttempt = 1
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(probe.checkCalls == 2)
        #expect(probe.grantCalls == 2)
        #expect(probe.reviewCalls == 1)
    }

    @Test("repeatedly unobservable checks escalate after the retry bound")
    func unobservableChecksEscalateAfterBound() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 10
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .timedOut),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .needsDecision)
        #expect(result.reason == .checksNotObserved)
        #expect(result.requiredAction == .rerunRequiredChecks)
        #expect(!result.readiness.isReady)
        #expect(probe.checkCalls == 2)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains { $0.kind == .independentCheck })
    }

    // MARK: - Fakes

    private struct PortFailure: Error {}

    nonisolated private final class PortProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _anchor: AgentVerificationIdentitySnapshot?
        private var _grantIsCurrent = true
        private var _checkObservation: AgentTaskCheckObservation
        private var _reviewObservation: AgentTaskReviewObservation
        private var _checkFailsBelowAttempt = 0
        private var _onReview: (@Sendable () -> Void)?
        private var _clock = Date()
        private var _probeCalls = 0
        private var _grantCalls = 0
        private var _checkCalls = 0
        private var _reviewCalls = 0

        init(
            check: AgentTaskCheckObservation,
            review: AgentTaskReviewObservation
        ) {
            _checkObservation = check
            _reviewObservation = review
        }

        var anchor: AgentVerificationIdentitySnapshot? {
            get { lock.withLock { _anchor } }
            set { lock.withLock { _anchor = newValue } }
        }
        var grantIsCurrent: Bool {
            get { lock.withLock { _grantIsCurrent } }
            set { lock.withLock { _grantIsCurrent = newValue } }
        }
        var checkObservation: AgentTaskCheckObservation {
            get { lock.withLock { _checkObservation } }
            set { lock.withLock { _checkObservation = newValue } }
        }
        var reviewObservation: AgentTaskReviewObservation {
            get { lock.withLock { _reviewObservation } }
            set { lock.withLock { _reviewObservation = newValue } }
        }
        var checkFailsBelowAttempt: Int {
            get { lock.withLock { _checkFailsBelowAttempt } }
            set { lock.withLock { _checkFailsBelowAttempt = newValue } }
        }
        var onReview: (@Sendable () -> Void)? {
            get { lock.withLock { _onReview } }
            set { lock.withLock { _onReview = newValue } }
        }
        var probeCalls: Int { lock.withLock { _probeCalls } }
        var grantCalls: Int { lock.withLock { _grantCalls } }
        var checkCalls: Int { lock.withLock { _checkCalls } }
        var reviewCalls: Int { lock.withLock { _reviewCalls } }
        var totalCalls: Int {
            lock.withLock { _probeCalls + _grantCalls + _checkCalls + _reviewCalls }
        }

        func nextTimestamp() -> Date {
            lock.withLock {
                defer { _clock += 0.02 }
                return _clock
            }
        }

        var coordinator: AgentTaskVerificationCoordinator {
            AgentTaskVerificationCoordinator(
                probeIdentity: { [weak self] _ in
                    guard let self else { return nil }
                    self.lock.withLock { self._probeCalls += 1 }
                    return self.anchor
                },
                grantIsCurrent: { [weak self] _ in
                    guard let self else { return false }
                    self.lock.withLock { self._grantCalls += 1 }
                    return self.grantIsCurrent
                },
                runRequiredChecks: { [weak self] request in
                    guard let self else { throw PortFailure() }
                    self.lock.withLock { self._checkCalls += 1 }
                    if request.attempt <= self.checkFailsBelowAttempt {
                        throw PortFailure()
                    }
                    return self.checkObservation
                },
                startReview: { [weak self] _ in
                    guard let self else { throw PortFailure() }
                    self.lock.withLock { self._reviewCalls += 1 }
                    self.onReview?()
                    return self.reviewObservation
                },
                now: { [weak self] in
                    self?.nextTimestamp() ?? Date()
                }
            )
        }
    }

    /// A write fault that fires on every agent-task atomic replace while
    /// armed: the deterministic stand-in for a process dying mid-write.
    nonisolated private final class ArmedWriteFault: @unchecked Sendable {
        private let lock = NSLock()
        private var _armed = false

        func arm() {
            lock.withLock { _armed = true }
        }

        var injector: PersistenceFaultInjector {
            PersistenceFaultInjector { [weak self] store, phase in
                guard let self else { return }
                if self.lock.withLock({ self._armed }),
                   store == .agentTask,
                   phase == .beforeAtomicReplace {
                    throw PersistenceFailureKind.interrupted
                }
            }
        }
    }

    /// The minimal real-storage fixture: a clean 0700 root with a user-owned
    /// project directory and the store-owned private storage directory.
    private final class CoordinatorFixture {
        let root: URL
        let project: AgentTaskProjectIdentity
        let storage: URL

        init() throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("PineVerificationContract-\(UUID().uuidString)")
            let projectURL = root.appendingPathComponent("project", isDirectory: true)
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
                    chmod, commandDescription: "chmod -N verification fixture root"
                )
                guard output.terminationStatus == 0 else {
                    try? fileManager.removeItem(at: root)
                    throw CocoaError(.fileWriteNoPermission)
                }
                try fileManager.createDirectory(
                    at: projectURL, withIntermediateDirectories: false
                )
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
            project = AgentTaskProjectIdentity(
                canonicalProjectPath: projectURL.standardizedFileURL.path,
                canonicalWorktreePath: projectURL.standardizedFileURL.path
            )
        }

        func store(
            injector: PersistenceFaultInjector = .none
        ) -> AgentTaskMetadataStore {
            AgentTaskMetadataStore(
                storageRoot: storage,
                configuration: AgentTaskStoreConfiguration(faultInjector: injector)
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
