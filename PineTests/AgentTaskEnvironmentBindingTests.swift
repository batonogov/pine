import Foundation
import Testing
@testable import Pine

struct AgentTaskEnvironmentBindingTests {
    @Test func abandoningBindingOwnerRevokesRetainedSetupLease() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        var bindings: AgentTaskEnvironmentBindings? = AgentTaskEnvironmentBindings()
        let setup: AgentTaskEnvironmentSetupLease
        do {
            let owner = try #require(bindings)
            setup = try await owner.reserve(taskID: UUID(), runID: UUID(),
                canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        }
        bindings = nil
        #expect(await runOnBackground { !setup.revalidate() })
    }

    @Test func setupLeasePinsMissingTargetAndRevocationCannotBeRearmed() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = UUID()
        let runID = UUID()
        let setup = try await bindings.reserve(taskID: taskID, runID: runID,
            canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        #expect(await runOnBackground { setup.revalidate() })
        await bindings.revoke(taskID: taskID, runID: runID)
        #expect(await runOnBackground { !setup.revalidate() })
        let replacement = try await bindings.reserve(taskID: taskID, runID: UUID(),
            canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        #expect(await runOnBackground { replacement.revalidate() })
        #expect(await runOnBackground { !setup.revalidate() })
    }

    @Test func createdTargetEndsSetupLeaseAndRequiresIndependentAdoption() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = UUID()
        let runID = UUID()
        let setup = try await bindings.reserve(taskID: taskID, runID: runID,
            canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID) }
        #expect(await runOnBackground { !setup.revalidate() })
        let directoryURL = await runOnBackground { fixture.worktree.resolvingSymlinksInPath() }
        #expect(directoryURL.path == setup.expectedWorktree.path)
        let binding = try await bindings.adopt(taskID: taskID, runID: runID, candidates: [directoryURL])
        let lease = try await bindings.revalidate(binding)
        #expect(await runOnBackground { lease.revalidate() })
        #expect(await runOnBackground { !setup.revalidate() })
    }

    @Test func adoptsOnceRevalidatesAndRefusesReplacement() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = UUID()
        let runID = UUID()
        try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID) }
        let binding = try await bindings.adopt(taskID: taskID, runID: runID, candidates: [fixture.worktree])
        let lease = try await bindings.revalidate(binding)
        #expect(await runOnBackground { lease.revalidate() })
        #expect(lease.canonicalWorktree.path == fixture.worktree.path)
        await #expect(throws: AgentTaskEnvironmentBindingError.alreadyReserved) {
            try await bindings.adopt(taskID: taskID, runID: runID, candidates: [fixture.worktree])
        }
        try await runOnBackground {
            try FileManager.default.moveItem(at: fixture.worktree, to: fixture.root.appending(path: "moved"))
            try FileManager.default.createDirectory(at: fixture.worktree, withIntermediateDirectories: false)
        }
        #expect(await runOnBackground { !lease.revalidate() })
        await #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) {
            try await bindings.revalidate(binding)
        }
    }

    @Test func ambiguityAndWrongAttemptFailBeforeAdoption() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = UUID()
        let runID = UUID()
        try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID) }
        await #expect(throws: AgentTaskEnvironmentBindingError.ambiguousEnvironment) {
            try await bindings.adopt(taskID: taskID, runID: runID, candidates: [fixture.worktree, fixture.worktree])
        }
        await #expect(throws: AgentTaskEnvironmentBindingError.missingReservation) {
            try await bindings.adopt(taskID: taskID, runID: UUID(), candidates: [fixture.worktree])
        }
        let binding = try await bindings.adopt(taskID: taskID, runID: runID, candidates: [fixture.worktree])
        try binding.validateAuthority()
        await bindings.revoke(taskID: taskID, runID: runID)
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try binding.validateAuthority() }
        await #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) {
            try await bindings.revalidate(binding)
        }
    }

    @Test func activeEnvironmentCannotBelongToAnotherTask() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let first = UUID()
        let second = UUID()
        let runID = UUID()
        try await bindings.reserve(taskID: first, runID: runID, canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: first, runID: runID) }
        try await bindings.reserve(taskID: second, runID: runID, canonicalProject: fixture.project,
                                   expectedWorktree: fixture.root.appending(path: "second-worktree"))
        _ = try await bindings.adopt(taskID: first, runID: runID, candidates: [fixture.worktree])
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.adopt(taskID: second, runID: runID, candidates: [fixture.worktree])
        }
    }

    @Test func projectSymlinkCannotBeAdoptedAsTaskWorktree() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let alias = fixture.root.appending(path: "project-alias")
        try await runOnBackground {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.project)
        }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = UUID()
        let runID = UUID()
        try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID) }
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.adopt(taskID: taskID, runID: runID, candidates: [alias])
        }
    }

    @Test func symlinkAliasCannotStealAnotherTasksActiveWorktree() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let alias = fixture.root.appending(path: "worktree-alias")
        try await runOnBackground {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.worktree)
        }
        let bindings = AgentTaskEnvironmentBindings()
        let first = UUID()
        let second = UUID()
        let runID = UUID()
        try await bindings.reserve(taskID: first, runID: runID, canonicalProject: fixture.project, expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: first, runID: runID) }
        try await bindings.reserve(taskID: second, runID: runID, canonicalProject: fixture.project,
                                   expectedWorktree: fixture.root.appending(path: "second-worktree"))
        let firstBinding = try await bindings.adopt(taskID: first, runID: runID, candidates: [fixture.worktree])
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.adopt(taskID: second, runID: runID, candidates: [alias])
        }
        _ = try await bindings.revalidate(firstBinding)
    }

    @Test func unrelatedExistingEnvironmentCannotBecomeTaskOwned() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let taskID = UUID()
        let runID = UUID()
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID, branch: "unrelated") }
        let bindings = AgentTaskEnvironmentBindings()
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project,
                                       expectedWorktree: fixture.worktree)
        }
    }

    @Test func wrongBranchAtExpectedPathFailsClosed() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let taskID = UUID()
        let runID = UUID()
        let bindings = AgentTaskEnvironmentBindings()
        try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project,
                                   expectedWorktree: fixture.worktree)
        try await runOnBackground { try fixture.createWorktree(taskID: taskID, runID: runID, branch: "unrelated") }
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.adopt(taskID: taskID, runID: runID, candidates: [fixture.worktree])
        }
    }

    @Test func expectedParentReplacementDuringSetupInvalidatesReservation() async throws {
        let fixture = try await runOnBackground { try BindingFixture() }
        defer { fixture.remove() }
        let parent = fixture.root.appending(path: "task-parent")
        let expected = parent.appending(path: "worktree")
        try await runOnBackground {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let taskID = UUID()
        let runID = UUID()
        let bindings = AgentTaskEnvironmentBindings()
        try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: fixture.project, expectedWorktree: expected)
        try await runOnBackground {
            try FileManager.default.moveItem(at: parent, to: fixture.root.appending(path: "original-parent"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try fixture.createWorktree(taskID: taskID, runID: runID, at: expected)
        }
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await bindings.adopt(taskID: taskID, runID: runID, candidates: [expected])
        }
    }

}

nonisolated private struct BindingFixture: Sendable {
    let root: URL
    let project: URL
    let worktree: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PineBinding-\(UUID())")
            .resolvingSymlinksInPath()
        project = root.appending(path: "project")
        worktree = root.appending(path: "worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do {
            for arguments in [
                ["init", "-b", "main"],
                ["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid", "commit", "--allow-empty", "-m", "fixture"]
            ] {
                guard GitCommand.run(arguments, at: project).succeeded else { throw BindingFixtureError.gitFailed }
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func createWorktree(taskID: UUID, runID: UUID, at root: URL? = nil, branch: String? = nil) throws {
        let branch = branch ?? AgentTaskEnvironmentBindings.branchName(taskID: taskID, runID: runID)
        guard GitCommand.run(["worktree", "add", "-b", branch, (root ?? worktree).path], at: project).succeeded else {
            throw BindingFixtureError.gitFailed
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum BindingFixtureError: Error { case gitFailed }
