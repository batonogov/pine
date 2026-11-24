import Foundation
import Testing
@testable import Pine

struct AgentTaskResultActionTests {
    private static let taskOne = UUID()
    private static let taskTwo = UUID()
    private let project = AgentTaskProjectIdentity(
        canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/first"
    )

    private var snapshot: AgentVerificationIdentitySnapshot {
        AgentVerificationIdentitySnapshot(
            code: AgentTaskCodeStateIdentity(
                headCommit: String(repeating: "a", count: 64),
                trackedFingerprint: String(repeating: "b", count: 64),
                untrackedFingerprint: String(repeating: "c", count: 64),
                ignoredRelevantFingerprint: String(repeating: "d", count: 64)
            ),
            environment: AgentTaskEnvironmentIdentity(
                osBuild: "25A1",
                toolchain: String(repeating: "b", count: 64),
                configurationFingerprint: String(repeating: "c", count: 64)
            )
        )
    }

    private func binding(
        output: AgentProjectResultOutput = .server(host: "127.0.0.1", port: 8080),
        taskID: UUID = AgentTaskResultActionTests.taskOne
    ) -> AgentTaskResultActionBinding {
        AgentTaskResultActionBinding(
            taskID: taskID, project: project,
            recipeFingerprint: String(repeating: "a", count: 64),
            resultActionID: "preview", output: output, snapshot: snapshot
        )
    }

    private func readyServer(
        taskID: UUID = AgentTaskResultActionTests.taskOne
    ) -> AgentTaskResultActionState {
        var state = AgentTaskResultActionState(binding: binding(taskID: taskID))
        state = state.reduced(by: .launchRequested)
        state = state.reduced(by: .processObserved(processID: 42, processGroupID: 42))
        state = state.reduced(by: .readyObserved)
        return state
    }

    @Test func launchIsExplicitAndReadinessRequiresOwnership() {
        var state = AgentTaskResultActionState(binding: binding())
        #expect(state.phase == .prepared)
        #expect(state.attempts == 0)
        #expect(state.reduced(by: .readyObserved) == state) // no launch, no readiness
        state = state.reduced(by: .launchRequested)
        #expect(state.phase == .starting)
        #expect(state.attempts == 1)
        #expect(!state.reduced(by: .readyObserved).isCurrent) // no observed process yet
        state = state.reduced(by: .processObserved(processID: 42, processGroupID: 42))
        #expect(state.phase == .starting)
        #expect(state.ownership?.endpoint == AgentProjectResultEndpoint(host: "127.0.0.1", port: 8080))
        state = state.reduced(by: .readyObserved)
        #expect(state.isCurrent)
        #expect(state.isLivePreview)
    }

    @Test func serverReuseStopAndRelaunch() {
        let ready = readyServer()
        #expect(ready.reduced(by: .launchRequested) == ready) // reuse, no second process
        var stopping = ready.reduced(by: .stopRequested)
        #expect(stopping.phase == .stopping)
        stopping = stopping.reduced(by: .processExited(0))
        #expect(stopping.phase == .stopped)
        #expect(stopping.ownership == nil)
        var relaunch = stopping.reduced(by: .launchRequested)
        #expect(relaunch.phase == .starting)
        #expect(relaunch.attempts == 2)
        relaunch = relaunch.reduced(by: .processObserved(processID: 43, processGroupID: 43))
        relaunch = relaunch.reduced(by: .readyObserved)
        #expect(relaunch.isCurrent)
        #expect(relaunch.ownership?.processID == 43)
    }

    @Test func portConflictNeverKillsTheOccupant() {
        let occupant = readyServer()
        var challenger = AgentTaskResultActionState(binding: binding(taskID: Self.taskTwo))
        challenger = challenger.reduced(by: .launchRequested)
        challenger = challenger.reduced(by: .portOccupied)
        #expect(challenger.phase == .portConflict)
        #expect(challenger.ownership == nil)
        #expect(occupant.isCurrent) // occupant untouched
        #expect(occupant.ownership?.processID == 42)
        var retry = challenger.reduced(by: .launchRequested)
        #expect(retry.phase == .starting)
        #expect(retry.attempts == 2)
        #expect(retry.reduced(by: .stopRequested) == retry) // nothing owned to stop
    }

    @Test func oneShotCLIRunCompletesFromObservedExit() {
        var state = AgentTaskResultActionState(binding: binding(output: .cli))
        state = state.reduced(by: .launchRequested)
        state = state.reduced(by: .processObserved(processID: 7, processGroupID: 7))
        state = state.reduced(by: .processExited(0))
        #expect(state.isCurrent)
        #expect(state.ownership == nil)
        #expect(state.verb == .runExample)
        #expect(!state.isLivePreview)
        var rerun = state.reduced(by: .launchRequested) // re-run the example
        #expect(rerun.phase == .starting)
        #expect(rerun.attempts == 2)

        var failed = AgentTaskResultActionState(binding: binding(output: .cli))
        failed = failed.reduced(by: .launchRequested)
        failed = failed.reduced(by: .processObserved(processID: 8, processGroupID: 8))
        failed = failed.reduced(by: .processExited(1))
        #expect(failed.phase == .failed(.processExited(1)))
        #expect(failed.reduced(by: .launchRequested).phase == .starting) // relaunch after failure
    }

    @Test func unexpectedTerminationStaysTruthful() {
        let ready = readyServer()
        #expect(ready.reduced(by: .processExited(137)).phase == .failed(.processExited(137)))
        #expect(ready.reduced(by: .processExited(0)).phase == .stopped)
        var early = AgentTaskResultActionState(binding: binding())
        early = early.reduced(by: .launchRequested)
        early = early.reduced(by: .processObserved(processID: 9, processGroupID: 9))
        #expect(early.reduced(by: .processExited(0)).phase == .failed(.processExited(0)))
    }

    @Test func cancellationPreservesWorkAndTruthfulState() {
        var state = AgentTaskResultActionState(binding: binding())
        state = state.reduced(by: .launchRequested)
        state = state.reduced(by: .processObserved(processID: 10, processGroupID: 10))
        let cancelled = state.reduced(by: .cancelled)
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.ownership == nil)
        #expect(cancelled.binding == state.binding) // work and binding preserved
        #expect(cancelled.reduced(by: .launchRequested).phase == .starting)
    }

    @Test func candidateChangeStalesCurrentResultOnly() {
        let ready = readyServer()
        let stale = ready.reduced(by: .candidateChanged)
        #expect(stale.phase == .stale)
        #expect(!stale.isCurrent)
        #expect(!stale.isLivePreview)
        #expect(stale.ownership?.processID == 42) // the live preview still runs
        #expect(stale.reduced(by: .processExited(0)).phase == .stopped)
        #expect(stale.reduced(by: .processExited(1)).phase == .failed(.processExited(1)))
        #expect(stale.reduced(by: .processExited(0)).ownership == nil)
        var stopping = stale.reduced(by: .stopRequested)
        #expect(stopping.phase == .stopping)
        #expect(stopping.reduced(by: .processExited(0)).phase == .stopped)
        #expect(stale.reduced(by: .launchRequested) == stale) // stale rebinding, not a relaunch

        var starting = AgentTaskResultActionState(binding: binding())
        starting = starting.reduced(by: .launchRequested)
        #expect(starting.reduced(by: .candidateChanged) == starting)
    }

    @Test func twoTasksNeverShareEndpointOrProcessState() {
        let first = readyServer(taskID: Self.taskOne)
        var second = AgentTaskResultActionState(binding: binding(taskID: Self.taskTwo))
        second = second.reduced(by: .launchRequested)
        second = second.reduced(by: .portOccupied)
        #expect(second.phase == .portConflict)
        #expect(first.isCurrent)
        // Stopping task 1's server has no effect on task 2's state; task 2
        // must observe the freed port and relaunch against its own binding.
        let stoppingFirst = first.reduced(by: .stopRequested)
        #expect(stoppingFirst.phase == .stopping)
        #expect(second.phase == .portConflict)
    }

    @Test func missingPrerequisiteIsExplained() {
        let state = AgentTaskResultActionState(binding: binding())
        #expect(state.reduced(by: .prerequisiteMissing("swift"))
            .phase == .failed(.missingPrerequisite("swift")))
        var starting = state.reduced(by: .launchRequested)
        #expect(starting.reduced(by: .prerequisiteMissing("swift"))
            .phase == .failed(.missingPrerequisite("swift")))
    }

    @Test func verbsMapOutputsAndKeepViewChangesForNonRunnable() {
        #expect(AgentProjectResultOutput.server(host: "127.0.0.1", port: 8080).verb == .openPreview)
        #expect(AgentProjectResultOutput.artifact(relativePath: ".build/debug/app").verb == .runApplication)
        #expect(AgentProjectResultOutput.cli.verb == .runExample)
        #expect(AgentProjectResultOutput.document(relativePath: "docs/guide.md").verb == .viewChanges)
        #expect(AgentProjectResultOutput.document(relativePath: "docs/guide.md").isRunnable == false)
        #expect(AgentProjectResultVerb.allCases.map(\.title) == [
            "Open preview", "Run application", "Run example", "View changes",
        ])
    }

    @Test func endpointsAndPathsAreBoundedAndLoopbackOnly() {
        #expect(AgentProjectResultEndpoint(host: "127.0.0.1", port: 8080).isValid)
        #expect(AgentProjectResultEndpoint(host: "::1", port: 1).isValid)
        #expect(!AgentProjectResultEndpoint(host: "10.0.0.1", port: 8080).isValid)
        #expect(!AgentProjectResultEndpoint(host: "127.0.0.1", port: 0).isValid)
        #expect(!AgentProjectResultOutput.server(host: "10.0.0.1", port: 8080).isValid)
        #expect(!AgentProjectResultOutput.artifact(relativePath: "../escape").isValid)
        #expect(!AgentProjectResultOutput.artifact(relativePath: "/abs").isValid)
    }
}
