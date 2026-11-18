//
//  AgentTaskConcurrencyAdmissionTests.swift
//  PineTests
//
//  Bounded concurrent launch admission for independent ADE tasks (#1728):
//  the documented limit N, honest N+1 queueing/deferral, one slot per task,
//  dead grants, and no process launch without a grant.
//
//  Every test uses the REALISTIC configuration the binding contract allows:
//  same canonical project (repository), distinct worktree paths — one active
//  task per (repo, worktree), all sharing one admission bucket.
//

import Foundation
import Testing
@testable import Pine

@Suite("Concurrent ADE task launch admission (#1728)")
struct AgentTaskConcurrencyAdmissionTests {
    private let repositoryPath = "/private/tmp/pine-1728/admission-repo"

    /// Same repository, distinct worktrees: the configuration three
    /// same-repository tasks actually have.
    private func identity(_ worktree: Int) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: repositoryPath,
            canonicalWorktreePath: "\(repositoryPath)/wt-\(worktree)"
        )
    }

    /// A different repository: a different admission bucket.
    private func foreignIdentity(_ worktree: Int) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: "/private/tmp/pine-1728/admission-repo-b",
            canonicalWorktreePath: "/private/tmp/pine-1728/admission-repo-b/wt-\(worktree)"
        )
    }

    private func task(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed + 1))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    @Test func admitsUpToNWithDistinctGenerationsAndQueuesNPlusOneHonestly() async {
        let gate = AgentTaskConcurrencyAdmission()
        var admissions: [AgentTaskLaunchAdmission] = []
        for seed in 0..<5 {
            admissions.append(
                await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
            )
        }
        let granted = admissions.compactMap {
            if case .admitted(let grant) = $0 { return grant }
            return nil
        }
        #expect(granted.count == AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks)
        #expect(granted.map(\.launchGeneration) == [1, 2, 3])
        #expect(admissions[3] == .queued(position: 1))
        #expect(admissions[4] == .queued(position: 2))
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 2)
    }

    @Test func sameRepositoryDifferentWorktreesShareOneBucket() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<3 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        #expect(await gate.activeCount(project: identity(0)) == 3)
        // A fourth task in a DIFFERENT worktree of the SAME repository must
        // queue: N is enforced per repository, not per (repo, worktree).
        #expect(
            await gate.requestLaunch(project: identity(9), taskID: task(9), runID: UUID())
                == .queued(position: 1)
        )
        #expect(await gate.activeCount(project: identity(9)) == 3)
        #expect(await gate.queuedCount(project: identity(9)) == 1)
    }

    @Test func nPlusOneRequestNeverStartsAnotherProcess() async {
        let gate = AgentTaskConcurrencyAdmission()
        // The launch path may start a process ONLY from a grant.
        var processesLaunched = 0
        for seed in 0..<4 {
            switch await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID()) {
            case .admitted:
                processesLaunched += 1
            case .queued, .deferred:
                break
            }
        }
        #expect(
            processesLaunched
                == AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks
        )
    }

    @Test func releasePromotesExactlyOneQueuedRequestInFifoOrder() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<4 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        let promoted = await gate.release(project: identity(0), taskID: task(0))
        #expect(promoted.count == 1)
        #expect(promoted.first?.taskID == task(3))
        // The promoted grant carries the REQUESTING task's identity.
        #expect(promoted.first?.project == identity(3))
        #expect(promoted.first?.launchGeneration == 4)
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 0)
        // A sixth request now takes the next FIFO position, not a slot.
        _ = await gate.requestLaunch(project: identity(4), taskID: task(4), runID: UUID())
        #expect(await gate.queuedCount(project: identity(0)) == 1)
    }

    @Test func duplicateRequestForSameTaskIsDeferredNotDuplicated() async {
        let gate = AgentTaskConcurrencyAdmission()
        _ = await gate.requestLaunch(project: identity(0), taskID: task(0), runID: UUID())
        #expect(
            await gate.requestLaunch(project: identity(0), taskID: task(0), runID: UUID())
                == .deferred(.duplicateRequest)
        )
        for seed in 1..<3 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        _ = await gate.requestLaunch(project: identity(3), taskID: task(3), runID: UUID())
        #expect(
            await gate.requestLaunch(project: identity(3), taskID: task(3), runID: UUID())
                == .deferred(.duplicateRequest)
        )
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 1)
    }

    @Test func queueFullDefersHonestlyAndBoundsAreNeverExceeded() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<(3 + AgentTaskConcurrencyLimits.maximumQueuedLaunchRequests) {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        #expect(
            await gate.requestLaunch(project: identity(99), taskID: task(99), runID: UUID())
                == .deferred(.queueFull)
        )
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 8)
    }

    @Test func cancelActiveFreesSlotPromotesQueueAndGrantIsDead() async {
        let gate = AgentTaskConcurrencyAdmission()
        let first = await gate.requestLaunch(project: identity(0), taskID: task(0), runID: UUID())
        for seed in 1..<4 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        guard case .admitted(let firstGrant) = first else {
            Issue.record("first request should be admitted")
            return
        }
        await gate.cancel(project: identity(0), taskID: task(0))
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 0)
        let promoted = await gate.grant(project: identity(0), taskID: task(3))
        #expect(promoted?.launchGeneration == 4)
        #expect(promoted?.project == identity(3))
        #expect(firstGrant.launchGeneration < (promoted?.launchGeneration ?? 0))
        // Free one other slot, then relaunch the cancelled task: a FRESH
        // grant with a FRESH generation; the old grant's generation is never
        // reused.
        _ = await gate.release(project: identity(1), taskID: task(1))
        let relaunch = await gate.requestLaunch(project: identity(0), taskID: task(0), runID: UUID())
        guard case .admitted(let relaunchGrant) = relaunch else {
            Issue.record("relaunch should be admitted")
            return
        }
        #expect(relaunchGrant.launchGeneration > firstGrant.launchGeneration)
        #expect(relaunchGrant != firstGrant)
    }

    @Test func cancelQueuedRemovesRequestWithoutPromotingOthers() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<4 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        await gate.cancel(project: identity(3), taskID: task(3))
        #expect(await gate.queuedCount(project: identity(0)) == 0)
        #expect(await gate.activeCount(project: identity(0)) == 3)
        let promoted = await gate.release(project: identity(0), taskID: task(0))
        #expect(promoted.isEmpty)
    }

    @Test func doubleReleaseNeverPromotesTwice() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<4 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        let first = await gate.release(project: identity(0), taskID: task(0))
        #expect(first.count == 1)
        let second = await gate.release(project: identity(0), taskID: task(0))
        #expect(second.isEmpty)
        #expect(await gate.activeCount(project: identity(0)) == 3)
        // Cancellation of an already-released task is also a no-op.
        await gate.cancel(project: identity(0), taskID: task(0))
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 0)
    }

    @Test func differentRepositoriesAreIndependentBuckets() async {
        let gate = AgentTaskConcurrencyAdmission()
        for seed in 0..<3 {
            _ = await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
        }
        #expect(await gate.activeCount(project: identity(0)) == 3)
        // A full repository A never blocks the first launch of repository B.
        let admission = await gate.requestLaunch(
            project: foreignIdentity(0), taskID: task(50), runID: UUID()
        )
        #expect(await gate.activeCount(project: foreignIdentity(0)) == 1)
        guard case .admitted(let grant) = admission else {
            Issue.record("repository B should be admitted")
            return
        }
        #expect(grant.launchGeneration == 1)
        #expect(grant.project == foreignIdentity(0))
    }

    @Test func sameRepositoryBurstNeverOverAdmitsAndPromotesOnRelease() async {
        let gate = AgentTaskConcurrencyAdmission()
        let total = 16
        // Sixteen same-repository tasks in distinct worktrees, requested
        // concurrently.
        let admissions = await withTaskGroup(of: AgentTaskLaunchAdmission.self) { group in
            for seed in 0..<total {
                group.addTask {
                    await gate.requestLaunch(project: identity(seed), taskID: task(seed), runID: UUID())
                }
            }
            var collected: [AgentTaskLaunchAdmission] = []
            for await admission in group {
                collected.append(admission)
            }
            return collected
        }
        let admitted = admissions.filter {
            if case .admitted = $0 { return true }
            return false
        }
        let queued = admissions.filter {
            if case .queued = $0 { return true }
            return false
        }
        let deferred = admissions.filter {
            if case .deferred = $0 { return true }
            return false
        }
        #expect(admitted.count == AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks)
        #expect(queued.count == AgentTaskConcurrencyLimits.maximumQueuedLaunchRequests)
        #expect(deferred.count == total - 3 - 8)
        // All granted generations are unique.
        let generations = admitted.compactMap {
            if case .admitted(let grant) = $0 { return grant.launchGeneration }
            return nil
        }
        #expect(Set(generations).count == generations.count)
        // Releasing all active tasks promotes the queue, never more than the
        // freed slots.
        let admittedTasks = admitted.compactMap {
            if case .admitted(let grant) = $0 { return grant.taskID }
            return nil
        }
        var promotedTotal = 0
        for admittedTask in admittedTasks {
            promotedTotal += await gate.release(project: identity(0), taskID: admittedTask).count
        }
        #expect(promotedTotal == 3)
        #expect(await gate.activeCount(project: identity(0)) == 3)
        #expect(await gate.queuedCount(project: identity(0)) == 5)
    }
}
