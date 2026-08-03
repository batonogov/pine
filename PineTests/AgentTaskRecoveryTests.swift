import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentTaskRecoveryTests {
    @Test("New session is an honest shell plan with the saved objective")
    func newSessionPlan() throws {
        let task = makeTask()
        let result = AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .startNewSession,
            inspection: inspection(),
            recipes: []
        )
        guard case .ready(let plan) = result else {
            Issue.record("Expected a recoverable new session")
            return
        }
        #expect(plan.action == .startNewSession)
        #expect(plan.process == nil)
        #expect(plan.objective == "Finish the release")
        #expect(plan.workingDirectory.path == task.project.canonicalWorktreePath)
    }

    @Test("Missing and removed directories have distinct deterministic outcomes")
    func directoryOutcomes() {
        let task = makeTask()
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .startNewSession,
            inspection: inspection(projectExists: false),
            recipes: []
        ) == .unavailable(.projectMissing))
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .startNewSession,
            inspection: inspection(worktreeExists: false),
            recipes: []
        ) == .unavailable(.worktreeMissing))
    }

    @Test("Resume requires a documented adapter and persisted vendor identity")
    func capabilityGate() {
        var missingIdentity = makeTask()
        missingIdentity.runs[0].vendorIdentity = nil
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: missingIdentity,
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: []
        ) == .unavailable(.vendorIdentityMissing))

        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: makeTask(),
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: []
        ) == .unavailable(.adapterUnavailable))
    }

    @Test("Opaque session ID remains one argv element without shell parsing")
    func opaqueIdentifierIsOneArgument() {
        let opaqueID = "session; touch /tmp/never-run $(whoami)"
        let task = makeTask(opaqueIdentifier: opaqueID)
        let recipe = AgentTaskResumeRecipe(
            provider: "example",
            agentTypeIdentifier: task.descriptor.typeIdentifier,
            executableAliases: ["codex"],
            supportedVersions: ["1.2.3"],
            identifierArgumentPrefix: ["resume", "--session"],
            identifierArgumentSuffix: ["--no-update"]
        )
        let result = AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: [recipe]
        )
        guard case .ready(let plan) = result else {
            Issue.record("Expected documented resume plan")
            return
        }
        #expect(plan.process?.executablePath == "/usr/local/bin/codex")
        #expect(plan.process?.arguments == [
            "resume", "--session", opaqueID, "--no-update",
        ])
    }

    @Test("Executable and version changes fail closed")
    func executableAndVersionChanges() {
        let task = makeTask()
        let recipe = AgentTaskResumeRecipe(
            provider: "example",
            agentTypeIdentifier: task.descriptor.typeIdentifier,
            executableAliases: ["codex"],
            supportedVersions: ["1.2.3"],
            identifierArgumentPrefix: ["resume"],
            identifierArgumentSuffix: []
        )
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(executable: nil),
            recipes: [recipe]
        ) == .unavailable(.executableMissing))
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(version: "2.0.0"),
            recipes: [recipe]
        ) == .unavailable(.versionChanged))
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(version: nil),
            recipes: [recipe]
        ) == .unavailable(.versionProbeFailed))

        var unversionedTask = task
        unversionedTask.runs[0].vendorIdentity = AgentVendorSessionIdentity(
            provider: "example",
            opaqueIdentifier: "opaque-session-123"
        )
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: unversionedTask,
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: [recipe]
        ) == .unavailable(.versionProbeFailed))
    }

    @Test("Control characters in persisted identity are rejected")
    func invalidOpaqueIdentity() {
        let task = makeTask(opaqueIdentifier: "session\nsecret")
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: []
        ) == .unavailable(.vendorIdentityInvalid))
    }

    @Test("Completed tasks may start fresh but cannot resume a finished session")
    func completedTaskRecoveryPolicy() {
        var task = makeTask()
        task.lifecycle = .completed
        let recipe = AgentTaskResumeRecipe(
            provider: "example",
            agentTypeIdentifier: task.descriptor.typeIdentifier,
            executableAliases: ["codex"],
            supportedVersions: ["1.2.3"],
            identifierArgumentPrefix: ["resume"],
            identifierArgumentSuffix: []
        )
        #expect(AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .resumeVendorSession,
            inspection: inspection(),
            recipes: [recipe]
        ) == .unavailable(.taskNotRecoverable))
        guard case .ready(let plan) = AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: .startNewSession,
            inspection: inspection(),
            recipes: []
        ) else {
            Issue.record("Expected completed task to allow a fresh session")
            return
        }
        #expect(plan.process == nil)
    }

    @Test("Inspector revalidates an executable cached before it was removed")
    func removedCachedExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let resolver = ExternalToolResolver(searchDirectories: [root.path])
        #expect(resolver.resolve(tool: "codex") == executable.path)
        try FileManager.default.removeItem(at: executable)

        let inspector = AgentTaskRecoveryInspector(
            resolver: resolver,
            processRunner: { _, _, _, _ in
                Issue.record("Removed executable must not be launched")
                return ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            recipes: []
        )
        #expect(await inspector.inspect(
            task: makeTask(root: root.path),
            action: .resumeVendorSession
        ) == .unavailable(.executableMissing))
    }

    private func makeTask(
        opaqueIdentifier: String = "opaque-session-123",
        root: String = "/tmp/pine-recovery-project"
    ) -> AgentTask {
        let root = URL(fileURLWithPath: root)
            .standardizedFileURL.path
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: root,
            canonicalWorktreePath: root
        )
        let route = AgentTaskRoute(
            paneID: UUID(),
            tabID: UUID(),
            terminalID: UUID(),
            availability: .missing
        )
        // Persisted routes always use the terminal identity for tab identity.
        let validRoute = AgentTaskRoute(
            paneID: route.paneID,
            tabID: route.terminalID,
            terminalID: route.terminalID,
            availability: .missing
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: validRoute,
            origin: .pineLaunched,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(
                agentType: .codex,
                launchExecutable: "codex"
            ),
            context: context,
            title: "Release",
            objective: "Finish the release"
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: UUID(),
            terminalID: validRoute.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: nil,
                processGeneration: 7,
                startIdentifier: nil,
                observedStartedAt: Date(timeIntervalSince1970: 100)
            ),
            status: AgentTaskRunStatus(
                state: .done,
                liveness: .terminated,
                observedAt: Date(timeIntervalSince1970: 110)
            )
        ))
        run.vendorIdentity = AgentVendorSessionIdentity(
            provider: "example",
            opaqueIdentifier: opaqueIdentifier,
            executableVersion: "1.2.3"
        )
        task.runs = [run]
        task.lifecycle = .paused
        task.updatedAt = Date(timeIntervalSince1970: 110)
        task.lastActivityAt = Date(timeIntervalSince1970: 110)
        return task
    }

    private func inspection(
        projectExists: Bool = true,
        worktreeExists: Bool = true,
        executable: String? = "/usr/local/bin/codex",
        version: String? = "1.2.3"
    ) -> AgentTaskRecoveryInspection {
        AgentTaskRecoveryInspection(
            projectExists: projectExists,
            worktreeExists: worktreeExists,
            resolvedExecutablePath: executable,
            executableVersion: version
        )
    }
}
