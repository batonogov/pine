import Foundation
import Observation
import Testing
@testable import Pine

struct AgentTaskCheckCaptureTests {
    @Test func fixtureGitIgnoresOwnedHooksAndSigningConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PineCheckGit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await runOnBackground {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try CheckCaptureFixture.git(["init", "-b", "main"], at: root)
            let hooks = root.appending(path: "hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
            let marker = root.appending(path: "executed-marker")
            let script = Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 1\n".utf8)
            for name in ["pre-commit", "post-checkout", "signer"] {
                let file = hooks.appending(path: name)
                try script.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            for arguments in [
                ["config", "core.hooksPath", hooks.path],
                ["config", "commit.gpgsign", "true"],
                ["config", "gpg.program", hooks.appending(path: "signer").path]
            ] {
                try CheckCaptureFixture.git(arguments, at: root)
            }
            try CheckCaptureFixture.git(["commit", "--allow-empty", "-m", "fixture"], at: root)
            try CheckCaptureFixture.git(["worktree", "add", "-b", "owned", root.appending(path: "worktree").path], at: root)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func exactRunnerEnvironmentAndPostOperationEditsAreBound() async throws {
        let fixture = try await CheckCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture(environment: ["CHECK_INPUT": "one"])
        let before = try await fixture.snapshot(capture)
        let equivalent = try await fixture.snapshot(fixture.capture(environment: ["CHECK_INPUT": "one"]))
        #expect(before == equivalent)
        let changedEnvironment = try await fixture.snapshot(fixture.capture(environment: ["CHECK_INPUT": "two"]))
        #expect(before.code == changedEnvironment.code)
        #expect(before.environment != changedEnvironment.environment)
        try await runOnBackground {
            try Data("two".utf8).write(to: fixture.operation.capture.lease.canonicalWorktree.appending(path: "input"))
        }
        if case .changed = await capture.revalidate(before) {} else {
            Issue.record("An already-untracked same-size edit must not authorize the checked result")
        }
    }

    @Test func revocationAfterFactoryAndDuringCaptureFailsClosed() async throws {
        let fixture = try await CheckCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        fixture.setup.revokeAuthority()
        if case .unavailable(.unavailableBinding) = await capture.capture() {} else {
            Issue.record("A retained filesystem lease must not outlive binding authority")
        }
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try fixture.capture() }

        let during = try await CheckCaptureFixture()
        defer { during.remove() }
        var inFlight = try during.capture()
        inFlight.environmentValues = {
            during.setup.revokeAuthority()
            return [:]
        }
        if case .unavailable(.unavailableBinding) = await inFlight.capture() {} else {
            Issue.record("Revocation while observing inputs must refuse the snapshot")
        }
    }

    @Test func selectedToolBytesCannotInheritPriorEnvironmentIdentity() async throws {
        let fixture = try await CheckCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let before = try await fixture.snapshot(capture)
        let tool = try #require(fixture.operation.capture.tools.first)
        try await runOnBackground { try Data("two".utf8).write(to: tool) }
        let after = try await fixture.snapshot(capture)
        #expect(before.code == after.code)
        #expect(before.environment != after.environment)
        if case .changed = await capture.revalidate(before) {} else {
            Issue.record("Selected executable byte replacement must invalidate prior authority")
        }
    }

    @Test func wrongTaskRootToolsConfigurationAndEditorCoverageAreRejected() async throws {
        let fixture = try await CheckCaptureFixture()
        defer { fixture.remove() }
        let original = fixture.operation.capture
        let wrongRoot = try await runOnBackground {
            try #require(RecentAgentTaskFilesystemValidator.validationLease(
                for: AgentTaskProjectIdentity(
                    canonicalProjectPath: fixture.project.path, canonicalWorktreePath: fixture.project.path
                ), expectedProof: nil
            ))
        }
        let variants: [AgentVerificationIdentityCapture.Inputs] = [
            .init(lease: wrongRoot, policy: original.policy, editor: original.editor,
                  tools: original.tools, configurationFiles: original.configurationFiles),
            .init(lease: original.lease, policy: original.policy, editor: original.editor,
                  tools: [], configurationFiles: original.configurationFiles),
            .init(lease: original.lease, policy: original.policy, editor: original.editor,
                  tools: original.tools, configurationFiles: []),
            .init(lease: original.lease, policy: original.policy, editor: .unavailable,
                  tools: original.tools, configurationFiles: original.configurationFiles)
        ]
        for inputs in variants {
            let operation = fixture.operationReplacing(inputs: inputs)
            #expect(throws: AgentVerificationIdentityCapture.CheckInputError.self) {
                try AgentVerificationIdentityCapture.forCheckOperation(
                    operation, environmentValues: [:], cancellation: GitCommandCancellationToken()
                )
            }
        }
        let wrongTask = fixture.operationReplacing(inputs: original, taskID: UUID())
        #expect(throws: AgentVerificationIdentityCapture.CheckInputError.self) {
            try AgentVerificationIdentityCapture.forCheckOperation(
                wrongTask, environmentValues: [:], cancellation: GitCommandCancellationToken()
            )
        }
    }

    @MainActor @Test func realEditorObservationRevokesOnEditAndOwnerCollectionChange() throws {
        let manager = TabManager()
        manager.tabs = [EditorTab(url: URL(fileURLWithPath: "/project/input"), content: "one", savedContent: "one")]
        let owners = EditorOwners(managers: [manager])
        let preflight = AgentVerificationEditorPreflight.observing { owners.managers.flatMap(\.tabs) }
        guard case .available(_, let isCurrent) = preflight else {
            Issue.record("Clean editor coverage must be available")
            return
        }
        #expect(isCurrent())
        manager.tabs[0].content = "two"
        #expect(!isCurrent())
        if case .unavailable = AgentVerificationEditorPreflight.observing({ owners.managers.flatMap(\.tabs) }) {} else {
            Issue.record("Unsaved work must never be silently saved or treated as disk verification")
        }
        manager.tabs[0].content = "one"
        let next = AgentVerificationEditorPreflight.observing { owners.managers.flatMap(\.tabs) }
        guard case .available(_, let nextIsCurrent) = next else { return }
        owners.managers.append(TabManager())
        #expect(!nextIsCurrent())
    }
}

@MainActor @Observable private final class EditorOwners {
    var managers: [TabManager]
    init(managers: [TabManager]) { self.managers = managers }
}

nonisolated private struct CheckCaptureFixture: Sendable {
    let root: URL
    let project: URL
    let bindings: AgentTaskEnvironmentBindings
    let setup: AgentTaskEnvironmentSetupLease
    let operation: AgentTaskCheckOperationInputs

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PineCheckCapture-\(UUID())")
            .resolvingSymlinksInPath()
        project = root.appending(path: "project")
        let worktree = root.appending(path: "worktree")
        let taskID = UUID()
        let runID = UUID()
        let project = project
        let tool = root.appending(path: "tool")
        try await runOnBackground {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            for arguments in [
                ["init", "-b", "main"],
                ["commit", "--allow-empty", "-m", "fixture"]
            ] {
                try Self.git(arguments, at: project)
            }
        }
        bindings = AgentTaskEnvironmentBindings()
        setup = try await bindings.reserve(taskID: taskID, runID: runID, canonicalProject: project, expectedWorktree: worktree)
        try await runOnBackground {
            try Self.git(
                ["worktree", "add", "-b", AgentTaskEnvironmentBindings.branchName(taskID: taskID, runID: runID), worktree.path],
                at: project
            )
            try Data("one".utf8).write(to: worktree.appending(path: "input"))
        }
        let binding = try await bindings.adopt(taskID: taskID, runID: runID, candidates: [worktree])
        let lease = try await bindings.revalidate(binding)
        let command = AgentTaskCheckCommand(
            id: "check", required: true, executable: tool,
            arguments: [], workingDirectory: "", timeout: 30
        )
        let plan = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: String(repeating: "a", count: 64), commands: [command],
            capturePolicy: .conservative, configurationFiles: ["input"]
        )
        let inputs = AgentVerificationIdentityCapture.Inputs(
            lease: lease, policy: plan.capturePolicy, editor: .available([], isCurrent: { true }),
            tools: [command.executable], configurationFiles: [lease.canonicalWorktree.appending(path: "input")]
        )
        let initial = AgentVerificationIdentityCapture(
            inputs: inputs, environmentValues: { [:] }, cancellation: GitCommandCancellationToken()
        )
        guard case .current(let expected) = await initial.capture() else {
            throw AgentVerificationIdentityCapture.CheckInputError.inconsistentOperation
        }
        operation = AgentTaskCheckOperationInputs(
            operationID: UUID(), taskID: taskID, runID: runID, processGeneration: 1,
            binding: binding, grantID: UUID(), plan: plan, commandID: command.id, expected: expected, capture: inputs
        )
    }

    func capture(environment: [String: String] = [:]) throws -> AgentVerificationIdentityCapture {
        try AgentVerificationIdentityCapture.forCheckOperation(
            operation, environmentValues: environment, cancellation: GitCommandCancellationToken()
        )
    }

    func snapshot(_ capture: AgentVerificationIdentityCapture) async throws -> AgentVerificationIdentitySnapshot {
        guard case .current(let value) = await capture.capture() else {
            throw AgentVerificationIdentityCapture.CheckInputError.inconsistentOperation
        }
        return value
    }

    func operationReplacing(inputs: AgentVerificationIdentityCapture.Inputs, taskID: UUID? = nil) -> AgentTaskCheckOperationInputs {
        AgentTaskCheckOperationInputs(
            operationID: operation.operationID, taskID: taskID ?? operation.taskID, runID: operation.runID,
            processGeneration: operation.processGeneration, binding: operation.binding, grantID: operation.grantID,
            plan: operation.plan, commandID: operation.commandID, expected: operation.expected, capture: inputs
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func git(_ arguments: [String], at root: URL) throws {
        var environment = [
            "-i", "PATH=/usr/bin:/bin", "HOME=/var/empty", "LC_ALL=C",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment.append("DEVELOPER_DIR=" + developer)
        }
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: environment + [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                "-c", "init.templateDir=", "-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid"
            ] + arguments,
            at: root, timeout: 10
        )
        guard result.succeeded else { throw CocoaError(.fileReadUnknown) }
    }
}
