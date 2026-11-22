import Foundation
import Testing
@testable import Pine

/// Opt-in production-spawn smoke: no model prompt, no auth mutation, and only
/// synthetic working directories. The deterministic contract suites remain the
/// CI gate; this proves the currently installed pinned binary through Pine's
/// actual ownership/channel/session path when explicitly requested.
struct OpenCodeACPNativeSmokeTests {
    nonisolated private static let optedIn =
        ProcessInfo.processInfo.environment["PINE_RUN_OPENCODE_ACP_SMOKE"] == "1"
        || FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-acp-smoke").path)

    @Test(.enabled(if: Self.optedIn, "Forward PINE_RUN_OPENCODE_ACP_SMOKE=1 or create $TMPDIR/pine-opencode-acp-smoke"))
    func productionOwnerStartsExactSessionAndCleansUp() async throws {
        let binary = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["PINE_OPENCODE_BINARY"] ?? "/opt/homebrew/bin/opencode")
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))

        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        var taskRoot: URL?
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            if let taskRoot { try? FileManager.default.removeItem(at: taskRoot) }
        }

        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: projectRoot.path, canonicalWorktreePath: projectRoot.path
        )
        let tasks = AgentTaskRegistry(persistence: OpenCodeSmokeTaskStore())
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            title: "Synthetic smoke", objective: "No model prompt"
        ))
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let working = URL(fileURLWithPath: binding.identity.canonicalWorktreePath)
        taskRoot = working.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = OpenCodeSmokeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"), selectedExecutable: binary
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID, bindingID: binding.id,
            selection: selection, provenance: testLaunchProvenance
        ) else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        let projects = ProjectRegistry(agentTasks: tasks)
        _ = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        // Production composition is notified by the prepared native owner.
        try #require(await waitUntilMainActor {
            projects.openCodeRuntime(for: reservation.taskID) != nil
        })
        let runtime = try #require(projects.openCodeRuntime(for: reservation.taskID))
        #expect(runtime.snapshot == nil) // Composition did not launch an agent.
        try await runtime.start()
        let snapshot = try #require(runtime.snapshot)
        #expect(snapshot.state == .idle && snapshot.nativeSession != nil)
        #expect(snapshot.result.isEmpty && snapshot.questions.isEmpty)
        #expect(!snapshot.ready && !snapshot.settlementKnown)
        let task = try #require(tasks.task(for: reservation.taskID))
        #expect(task.nativeDispatch?.phase == .sessionBound)
        #expect(task.runs.last?.outcome == nil)
        let processID = try #require(task.runs.last?.process.processIdentifier)
        let incarnation = await runOnBackground { UserTaskProcessInspector.identity(for: processID) }
        #expect(incarnation != nil)
        await runtime.stop(deadline: .now.advanced(by: .seconds(10)))
        let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: processID) }
        #expect(remaining == nil || remaining != incarnation)
        #expect(tasks.task(for: reservation.taskID)?.runs.last?.liveness == .stale)
    }
}

private actor OpenCodeSmokeTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil, requiresMigration: false, envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard tasks.allSatisfy({ $0.nativeDispatch?.isValid(for: $0) ?? true }),
              let encoded = try? JSONEncoder().encode(tasks) else { return .rejected(.invalidMetadata) }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

private actor OpenCodeSmokeBindingValidator: AgentTaskNativeBindingValidator {
    let binding: AgentTaskEnvironmentBinding
    let lease: RecentAgentTaskFilesystemValidationLease
    init(binding: AgentTaskEnvironmentBinding, lease: RecentAgentTaskFilesystemValidationLease) {
        self.binding = binding
        self.lease = lease
    }
    func revalidate(_ requested: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease {
        guard requested == binding else { throw AgentTaskEnvironmentBindingError.staleBinding }
        try requested.validateAuthority()
        return lease
    }
}
