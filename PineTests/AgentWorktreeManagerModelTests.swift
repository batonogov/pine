//
//  AgentWorktreeManagerModelTests.swift
//  PineTests
//
//  #1524. `AgentWorktreeService` is covered against real repositories by
//  `AgentWorktreeServiceTests`; what is unproved is the layer above it — the
//  one that decides *what consent to send*. These tests script the service so
//  the interesting cases (a worktree that turns dirty between the alert and
//  the answer, a preview that conflicts, a stale refresh) are deterministic
//  rather than races nobody can reproduce.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Worktree Manager Model", .serialized)
@MainActor
struct AgentWorktreeManagerModelTests {

    // MARK: - Listing

    @Test("Each row reports its own working-tree state")
    func refreshReportsPerRowStatus() async throws {
        let clean = makeWorktree(branch: "pine/agent/codex/aaaaaaaa")
        let dirty = makeWorktree(branch: "pine/agent/codex/bbbbbbbb")
        let broken = makeWorktree(branch: "pine/agent/codex/cccccccc")
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(clean, dirtyPaths: [])),
            for: clean
        )
        await service.setInspection(
            .success(inspection(dirty, dirtyPaths: ["a.txt", "b.txt"])),
            for: dirty
        )
        await service.setInspection(.failure(.inspectionFailed), for: broken)
        let model = AgentWorktreeManagerModel(service: service)

        await model.refresh([clean, dirty, broken])

        #expect(model.rows.map(\.id) == [
            clean.worktreeRoot, dirty.worktreeRoot, broken.worktreeRoot,
        ])
        #expect(model.rows[0].status == .clean)
        #expect(model.rows[1].status == .dirty(["a.txt", "b.txt"]))
        #expect(model.rows[2].status == .unavailable)
    }

    @Test("A refresh overtaken by a newer one is discarded, not applied")
    func staleRefreshIsDiscarded() async throws {
        // Both refreshes list the *same* worktree: that is the case where a
        // late-arriving answer can actually corrupt the row. Two different
        // worktrees would let the stale write miss for the wrong reason — the
        // row simply is not there any more — and the generation guard could be
        // deleted without any test noticing.
        let worktree = makeWorktree(branch: "pine/agent/codex/dddddddd")
        let service = ScriptedWorktreeService()
        await service.setInspectionSequence(
            [
                .success(inspection(worktree, dirtyPaths: ["stale.txt"])),
                .success(inspection(worktree, dirtyPaths: [])),
            ],
            for: worktree
        )
        let gate = OneShotGate()
        let model = AgentWorktreeManagerModel(service: service)
        model.inspectionSeam = { await gate.pause() }

        let first = Task { @MainActor in await model.refresh([worktree]) }
        await gate.waitUntilPaused()
        await model.refresh([worktree])
        #expect(model.rows[0].status == .clean)
        await gate.release()
        await first.value

        #expect(model.rows.map(\.id) == [worktree.worktreeRoot])
        #expect(model.rows[0].status == .clean)
    }

    // MARK: - Removal consent

    @Test("The removal prompt names the directory and every dirty path")
    func removalPromptDisclosesEverythingAtRisk() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/ffffffff")
        let paths = ["Sources/App.swift", "notes.md"]
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: paths)),
            for: worktree
        )
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareRemoval(worktree)

        let prompt = try #require(model.removalPrompt)
        #expect(prompt.dirtyPaths == paths)
        #expect(prompt.destroysUncommittedWork)
        let message = AgentWorktreeManagerModel.removalMessage(
            for: prompt,
            locale: Locale(identifier: "en")
        )
        #expect(message.contains(worktree.worktreeRoot.path))
        for path in paths {
            #expect(message.contains(path))
        }
    }

    @Test("A truncated disclosure still accounts for every hidden path")
    func removalPromptCountsPathsItCannotList() {
        let worktree = makeWorktree(branch: "pine/agent/codex/10101010")
        let limit = AgentWorktreeManagerModel.disclosedDirtyPathLimit
        let paths = (0..<(limit + 3)).map { "file-\($0).txt" }
        let prompt = AgentWorktreeRemovalPrompt(
            worktree: worktree,
            dirtyPaths: paths
        )

        let message = AgentWorktreeManagerModel.removalMessage(
            for: prompt,
            locale: Locale(identifier: "en")
        )

        #expect(message.contains(paths[0]))
        #expect(message.contains(paths[limit - 1]))
        #expect(!message.contains(paths[limit]))
        #expect(message.contains(Strings.agentWorktreesMoreChangesText(
            3,
            locale: Locale(identifier: "en")
        )))
    }

    @Test("A clean worktree is removed without a destructive confirmation")
    func cleanRemovalSendsNoConfirmation() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/20202020")
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: [])),
            for: worktree
        )
        await service.setRemoval(.removed, for: worktree)
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareRemoval(worktree)
        await model.confirmRemoval()

        let calls = await service.removeCalls
        #expect(calls.count == 1)
        // The service rejects a confirmation it did not ask for. Sending one
        // anyway would turn every clean removal into `.confirmationMismatch`.
        #expect(calls[0].confirmation == nil)
    }

    @Test("A dirty removal repeats the inspected paths verbatim")
    func dirtyRemovalMirrorsTheInspection() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/30303030")
        let paths = ["one.txt", "two.txt"]
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: paths)),
            for: worktree
        )
        await service.setRemoval(.removed, for: worktree)
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareRemoval(worktree)
        await model.confirmRemoval()

        let calls = await service.removeCalls
        let confirmation = try #require(calls.first?.confirmation)
        #expect(confirmation.worktreeRoot == worktree.worktreeRoot)
        #expect(confirmation.dirtyPaths == paths)
        #expect(confirmation.acknowledgesUnrecoverableDataLoss)
    }

    @Test("Removal drops the row and hands the worktree back to its owner")
    func removalNotifiesOwner() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/40404040")
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: [])),
            for: worktree
        )
        await service.setRemoval(.removed, for: worktree)
        let forgotten = Recorder()
        let model = AgentWorktreeManagerModel(
            service: service,
            onRemoved: { await forgotten.record($0) }
        )

        await model.refresh([worktree])
        await model.prepareRemoval(worktree)
        await model.confirmRemoval()

        #expect(model.rows.isEmpty)
        #expect(model.removalPrompt == nil)
        #expect(model.message == .removed(branch: worktree.branchName))
        #expect(await forgotten.worktrees == [worktree])
    }

    @Test("A worktree that turns dirty mid-answer is re-asked, not forced")
    func racedDirtyWorktreeIsReprompted() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/50505050")
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: [])),
            for: worktree
        )
        await service.setRemoval(
            .failed(.confirmationRequired(
                inspection(worktree, dirtyPaths: ["appeared.txt"])
            )),
            for: worktree
        )
        let forgotten = Recorder()
        let model = AgentWorktreeManagerModel(
            service: service,
            onRemoved: { await forgotten.record($0) }
        )

        await model.refresh([worktree])
        await model.prepareRemoval(worktree)
        await model.confirmRemoval()

        let prompt = try #require(model.removalPrompt)
        #expect(prompt.dirtyPaths == ["appeared.txt"])
        #expect(model.rows.map(\.id) == [worktree.worktreeRoot])
        #expect(await forgotten.worktrees.isEmpty)
        #expect(model.message == nil)
    }

    @Test("A second confirmation while one is in flight issues no second git")
    func doubleConfirmationIssuesOneRemoval() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/60606060")
        let gate = OneShotGate()
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: [])),
            for: worktree
        )
        await service.setRemoval(.removed, for: worktree)
        await service.setRemoveGate(gate)
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareRemoval(worktree)
        let first = Task { @MainActor in await model.confirmRemoval() }
        await gate.waitUntilPaused()
        #expect(model.isBusy)
        await model.confirmRemoval()
        await gate.release()
        await first.value

        #expect(await service.removeCalls.count == 1)
    }

    @Test("A removal Pine cannot perform is reported, not swallowed")
    func removalFailureBecomesAMessage() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/70707070")
        let service = ScriptedWorktreeService()
        await service.setInspection(
            .success(inspection(worktree, dirtyPaths: [])),
            for: worktree
        )
        await service.setRemoval(.failed(.unsafeWorktree), for: worktree)
        let model = AgentWorktreeManagerModel(service: service)

        await model.refresh([worktree])
        await model.prepareRemoval(worktree)
        await model.confirmRemoval()

        #expect(model.removalPrompt == nil)
        #expect(model.rows.map(\.id) == [worktree.worktreeRoot])
        #expect(model.message == .failure(Strings.agentWorktreesUnsafeText()))
    }

    // MARK: - Integration consent

    @Test("The integration confirmation mirrors the preview exactly")
    func integrationConfirmationMirrorsPreview() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/80808080")
        let preview = makePreview(
            worktree,
            changedPaths: ["Sources/A.swift", "Sources/B.swift"]
        )
        let service = ScriptedWorktreeService()
        await service.setPreview(.ready(preview), for: worktree)
        await service.setIntegration(.integratedWithoutCommit)
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareIntegration(worktree)
        #expect(model.canConfirmIntegration)
        await model.confirmIntegration()

        let calls = await service.integrateCalls
        let confirmation = try #require(calls.first)
        #expect(confirmation.previewID == preview.id)
        #expect(confirmation.sourceCommit == preview.sourceCommit)
        #expect(confirmation.targetHead == preview.targetHead)
        #expect(confirmation.targetBranch == preview.targetBranch)
        #expect(confirmation.changedPaths == preview.changedPaths)
        #expect(model.integrationPreview == nil)
        #expect(model.message == .integrated(
            targetBranch: preview.targetBranch,
            changedPathCount: 2
        ))
    }

    @Test("The integration alert discloses commit, branch, and changed files")
    func integrationMessageDisclosesTheApproval() {
        let worktree = makeWorktree(branch: "pine/agent/codex/90909090")
        let preview = makePreview(
            worktree,
            changedPaths: ["Sources/A.swift", "docs/readme.md"]
        )

        let message = AgentWorktreeManagerModel.integrationMessage(
            for: preview,
            locale: Locale(identifier: "en")
        )

        #expect(message.contains(String(preview.sourceCommit.prefix(7))))
        #expect(message.contains(preview.targetBranch))
        #expect(message.contains("Sources/A.swift"))
        #expect(message.contains("docs/readme.md"))
    }

    @Test("A conflicting preview is shown but cannot be answered")
    func conflictingPreviewIsNotConfirmable() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/a0a0a0a0")
        let preview = makePreview(
            worktree,
            changedPaths: ["Sources/A.swift"],
            conflictingPaths: ["Sources/A.swift"]
        )
        let service = ScriptedWorktreeService()
        await service.setPreview(.ready(preview), for: worktree)
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareIntegration(worktree)
        #expect(model.integrationPreview == preview)
        #expect(!model.canConfirmIntegration)
        await model.confirmIntegration()

        #expect(await service.integrateCalls.isEmpty)
        #expect(model.integrationPreview == preview)
        let message = AgentWorktreeManagerModel.integrationMessage(
            for: preview,
            locale: Locale(identifier: "en")
        )
        #expect(message.contains("Sources/A.swift"))
    }

    @Test("Every preview refusal reaches the user as its own reason")
    func previewFailuresAreDistinguished() async throws {
        let cases: [(AgentWorktreeIntegrationPreviewFailure, String)] = [
            (.noChanges, Strings.agentWorktreesNoChangesText()),
            (.sourceWorktreeDirty(["a"]), Strings.agentWorktreesSourceDirtyText()),
            (.targetCheckoutDirty(["b"]), Strings.agentWorktreesTargetDirtyText()),
            (.targetDetached, Strings.agentWorktreesTargetDetachedText()),
            (.unsafeWorktree, Strings.agentWorktreesUnsafeText()),
        ]

        for (failure, expected) in cases {
            let worktree = makeWorktree(branch: "pine/agent/codex/b0b0b0b0")
            let service = ScriptedWorktreeService()
            await service.setPreview(.failed(failure), for: worktree)
            let model = AgentWorktreeManagerModel(service: service)

            await model.prepareIntegration(worktree)

            #expect(model.integrationPreview == nil)
            #expect(model.message == .failure(expected))
        }
    }

    @Test("A merge that stops part-way says so instead of claiming success")
    func integrationFailureBecomesAMessage() async throws {
        let worktree = makeWorktree(branch: "pine/agent/codex/c0c0c0c0")
        let preview = makePreview(worktree, changedPaths: ["a.txt"])
        let service = ScriptedWorktreeService()
        await service.setPreview(.ready(preview), for: worktree)
        await service.setIntegration(
            .failed(.manualRecoveryRequired("CONFLICT (content)"))
        )
        let model = AgentWorktreeManagerModel(service: service)

        await model.prepareIntegration(worktree)
        await model.confirmIntegration()

        #expect(model.integrationPreview == nil)
        #expect(model.message == .failure(
            Strings.agentWorktreesManualRecoveryText("CONFLICT (content)")
        ))
    }

    // MARK: - Row affordances

    @Test("Merge is offered only for a worktree git could read and call clean")
    func integrationIsOfferedOnlyForCleanRows() {
        let worktree = makeWorktree(branch: "pine/agent/codex/d0d0d0d0")
        func presentation(
            _ status: AgentWorktreeRowStatus
        ) -> AgentWorktreeRowPresentation {
            AgentWorktreeRowPresentation(
                row: AgentWorktreeRow(worktree: worktree, status: status),
                projectName: "Pine"
            )
        }

        #expect(presentation(.clean).canIntegrate)
        #expect(!presentation(.checking).canIntegrate)
        #expect(!presentation(.dirty(["a"])).canIntegrate)
        #expect(!presentation(.unavailable).canIntegrate)
        // Removal stays reachable for every row: an unreadable worktree is the
        // one the user most needs to be able to reclaim.
        #expect(presentation(.unavailable).canRemove)
    }
}

// MARK: - Fixtures

private func makeWorktree(
    branch: String,
    repository: URL = URL(fileURLWithPath: "/tmp/pine-repo"),
    managedRoot: URL = URL(fileURLWithPath: "/tmp/pine-managed")
) -> AgentManagedWorktree {
    let taskID = UUID()
    return AgentManagedWorktree(
        taskID: taskID,
        repositoryRoot: repository,
        managedRoot: managedRoot,
        worktreeRoot: managedRoot.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        ),
        branchName: branch,
        baseCommit: String(repeating: "a", count: 40),
        repositoryProof: RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: 1,
            commonDirectoryInode: 2,
            commonDirectoryGeneration: 3,
            commonDirectoryBirthSeconds: 4,
            commonDirectoryBirthNanoseconds: 5
        )
    )
}

private func inspection(
    _ worktree: AgentManagedWorktree,
    dirtyPaths: [String]
) -> AgentWorktreeRemovalInspection {
    AgentWorktreeRemovalInspection(
        worktree: worktree,
        dirtyPaths: dirtyPaths
    )
}

private func makePreview(
    _ worktree: AgentManagedWorktree,
    changedPaths: [String],
    conflictingPaths: [String] = []
) -> AgentWorktreeIntegrationPreview {
    AgentWorktreeIntegrationPreview(
        id: UUID(),
        worktree: worktree,
        sourceCommit: String(repeating: "b", count: 40),
        targetRoot: worktree.repositoryRoot,
        targetHead: String(repeating: "c", count: 40),
        targetBranch: "main",
        targetIndexDigest: String(repeating: "d", count: 64),
        changedPaths: changedPaths,
        conflictingPaths: conflictingPaths
    )
}

/// Records what the model handed back to its owner after a removal.
private actor Recorder {
    private(set) var worktrees: [AgentManagedWorktree] = []

    func record(_ worktree: AgentManagedWorktree) {
        worktrees.append(worktree)
    }
}

/// Parks the first caller of ``pause()`` until ``release()``; every later
/// caller passes straight through. Modelled on `RecoveryListingGate` in
/// `RecoveryTerminationSweepTests`, but one-shot, because the seam under test
/// is crossed by both the stale refresh and the one that overtakes it.
private actor OneShotGate {
    private var didPause = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !didPause else { return }
        didPause = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            pausedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Deterministic stand-in for ``AgentWorktreeService``. Records the exact
/// consent values it was handed, which is the whole point: a model that sends
/// a confirmation the service did not ask for, or one whose paths drifted from
/// the inspection, fails closed in production and would otherwise look fine
/// here.
private actor ScriptedWorktreeService: AgentWorktreeManaging {
    struct RemoveCall: Sendable, Equatable {
        let worktreeRoot: URL
        let confirmation: AgentWorktreeRemovalConfirmation?
    }

    private var inspections: [URL: Result<
        AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
    >] = [:]
    /// Successive answers for one worktree, consumed front to back. The last
    /// one sticks, so an extra inspection cannot make a test pass by accident.
    private var inspectionSequences: [URL: [Result<
        AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
    >]] = [:]
    private var removals: [URL: AgentWorktreeRemovalResult] = [:]
    private var previews: [URL: AgentWorktreeIntegrationPreviewResult] = [:]
    private var integration: AgentWorktreeIntegrationResult =
        .integratedWithoutCommit
    private var removeGate: OneShotGate?

    private(set) var inspectCalls: [URL] = []
    private(set) var removeCalls: [RemoveCall] = []
    private(set) var previewCalls: [URL] = []
    private(set) var integrateCalls: [AgentWorktreeIntegrationConfirmation] = []

    func setInspection(
        _ result: Result<
            AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
        >,
        for worktree: AgentManagedWorktree
    ) {
        inspections[worktree.worktreeRoot] = result
    }

    func setInspectionSequence(
        _ results: [Result<
            AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
        >],
        for worktree: AgentManagedWorktree
    ) {
        inspectionSequences[worktree.worktreeRoot] = results
    }

    func setRemoval(
        _ result: AgentWorktreeRemovalResult,
        for worktree: AgentManagedWorktree
    ) {
        removals[worktree.worktreeRoot] = result
    }

    func setPreview(
        _ result: AgentWorktreeIntegrationPreviewResult,
        for worktree: AgentManagedWorktree
    ) {
        previews[worktree.worktreeRoot] = result
    }

    func setIntegration(_ result: AgentWorktreeIntegrationResult) {
        integration = result
    }

    func setRemoveGate(_ gate: OneShotGate) {
        removeGate = gate
    }

    func inspectRemoval(
        _ worktree: AgentManagedWorktree
    ) async -> Result<
        AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
    > {
        inspectCalls.append(worktree.worktreeRoot)
        if var queued = inspectionSequences[worktree.worktreeRoot],
           !queued.isEmpty {
            let next = queued.removeFirst()
            if !queued.isEmpty {
                inspectionSequences[worktree.worktreeRoot] = queued
            }
            return next
        }
        return inspections[worktree.worktreeRoot]
            ?? .failure(.inspectionFailed)
    }

    func remove(
        _ worktree: AgentManagedWorktree,
        confirmation: AgentWorktreeRemovalConfirmation?
    ) async -> AgentWorktreeRemovalResult {
        removeCalls.append(RemoveCall(
            worktreeRoot: worktree.worktreeRoot,
            confirmation: confirmation
        ))
        if let removeGate {
            await removeGate.pause()
        }
        return removals[worktree.worktreeRoot]
            ?? .failed(.inspectionFailed)
    }

    func previewIntegration(
        _ worktree: AgentManagedWorktree,
        previewID: UUID
    ) async -> AgentWorktreeIntegrationPreviewResult {
        previewCalls.append(worktree.worktreeRoot)
        return previews[worktree.worktreeRoot] ?? .failed(.noChanges)
    }

    func integrate(
        _ preview: AgentWorktreeIntegrationPreview,
        confirmation: AgentWorktreeIntegrationConfirmation
    ) async -> AgentWorktreeIntegrationResult {
        integrateCalls.append(confirmation)
        return integration
    }
}
