//
//  CodexAppServerNativeSmokeTests.swift
//  PineTests
//
//  Opt-in bounded smoke coverage for the real `codex app-server` owned-stdio
//  path (#1723). Discovery, handshake, and thread bind only: no turn is
//  started, so no model call and no quota spend. A stored provider thread is
//  created as a local side effect in the bound working directory's account.
//  The binary must match the pinned version exactly; anything else skips.
//

import Foundation
import Testing
@testable import Pine

@Suite("Codex app-server native smoke", .serialized)
@MainActor
struct CodexAppServerNativeSmokeTests {
    @Test(
        "Handshake, account discovery, and thread bind against the pinned binary",
        .enabled(
            if: Configuration.isRunnable,
            Comment(rawValue: Configuration.skipReason)
        ),
        .timeLimit(.minutes(1))
    )
    func realCodexAppServerBoundedDiscovery() async throws {
        let executable = try #require(Configuration.executable)
        let fixture = try await SmokeFixture(executable: executable)
        defer { fixture.remove() }

        let factory = try CodexAppServerNativeFactory(materials: fixture.materials, factoryID: .init(validating: "pine.codex.native-smoke"))
        let agentID = try AgentID(validating: "codex")
        let adapterID = try AdapterID(validating: "pine:codex-native")
        let versions = PineAdapterContractVersionRange(
            minimum: CodexAppServerNativeFactory.contractVersion,
            maximum: CodexAppServerNativeFactory.contractVersion
        )
        let presentation = try AgentPresentationDescriptor(
            agentID: agentID, displayName: "Codex",
            executableAliases: [ExecutableAlias(validating: "codex")], style: .codex
        )
        let adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(
                AdapterDescriptor(
                    adapterID: adapterID, agentID: agentID, factoryID: factory.id,
                    contractVersions: versions, maximumProfiles: [factory.maximumProfile]
                ),
                factory
            )]
        )
        let offer = try await adapters.probe(adapterID: adapterID)
        let contract = try await adapters.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: versions,
                transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        let session = try await adapters.makeSession(
            contract: contract, resumeFrom: nil,
            downstream: { event in
                await fixture.tasks.ingestNativeEvent(event, ownership: fixture.ownership)
            }
        )
        try fixture.tasks.bindNativeSource(fixture.ownership, registry: adapters, session: session)
        do {
            try await session.start()
        } catch {
            await session.stop(deadline: .now.advanced(by: .seconds(5)))
            throw error
        }
        // The supervised child is live and bound; teardown supervises the
        // process group and the session reports the negative observation.
        guard await fixture.waitUntil({
            fixture.tasks.task(for: fixture.taskID)?.nativeDispatch?.phase == .sessionBound
        }) else {
            await session.stop(deadline: .now.advanced(by: .seconds(5)))
            Issue.record("Session binding was not recorded against the real codex")
            return
        }
        #expect(fixture.tasks.task(for: fixture.taskID)?.runs.last?.liveness == .live)
        await session.stop(deadline: .now.advanced(by: .seconds(10)))
        guard await fixture.waitUntil({
            fixture.tasks.task(for: fixture.taskID)?.runs.last?.liveness == .stale
        }) else {
            Issue.record("Torn-down real child was not observed stale")
            return
        }
        await #expect(throws: AdapterSessionError.self) {
            try await session.start()
        }
    }
}

nonisolated private enum Configuration {
    static let optInEnvironmentVariable = "PINE_RUN_CODEX_NATIVE_SMOKE"
    static let executableEnvironmentVariable = "PINE_CODEX_SMOKE_EXECUTABLE"

    static let isOptedIn =
        ProcessInfo.processInfo.environment[optInEnvironmentVariable] == "1"

    static let executable: URL? = isOptedIn ? resolveExecutable() : nil

    /// Bounded synchronous probe so a version mismatch is a static skip,
    /// not a mid-test failure.
    static let versionCheck: (output: String, succeeded: Bool)? = executable.map { candidate in
        let result = GitCommand.runExecutable(
            candidate, arguments: ["--version"],
            at: FileManager.default.temporaryDirectory, timeout: 10, captureLimit: 4_096
        )
        return (result.output.trimmingCharacters(in: .whitespacesAndNewlines), result.succeeded)
    }

    static var isRunnable: Bool {
        executable != nil
            && versionCheck?.succeeded == true
            && versionCheck?.output == CodexAppServerExecutableIdentity.supportedVersion
    }

    static var skipReason: String {
        guard !isOptedIn else {
            if executable == nil {
                return "codex is unavailable at PINE_CODEX_SMOKE_EXECUTABLE or the common Homebrew paths"
            }
            return "machine codex reports '\(versionCheck?.output ?? "nothing")'; "
                + "the pinned gate is '\(CodexAppServerExecutableIdentity.supportedVersion)'. "
                + "Pass a matching PINE_CODEX_SMOKE_EXECUTABLE."
        }
        return "Pass PINE_RUN_CODEX_NATIVE_SMOKE=1 (and optionally PINE_CODEX_SMOKE_EXECUTABLE) as xcodebuild settings"
    }

    private static func resolveExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment[executableEnvironmentVariable] {
            let url = URL(fileURLWithPath: explicitPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

private actor SmokeBindingValidator: AgentTaskNativeBindingValidator {
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

nonisolated private struct SmokeFixture: Sendable {
    let root: URL
    let tasks: AgentTaskRegistry
    let ownership: AgentTaskNativeOwnership
    let taskID: UUID
    let materials: CodexAppServerNativeMaterials

    @MainActor
    init(executable: URL) async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pine-native-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let store = AgentTaskMetadataStore(
            storageRoot: storage,
            configuration: AgentTaskStoreConfiguration()
        )
        tasks = AgentTaskRegistry(persistence: store)
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            title: "Native smoke", objective: "Explicit request"
        ))
        taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(
            await runOnBackground {
                RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
            }
        )
        let validator = SmokeBindingValidator(binding: binding, lease: lease)
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID, bindingID: binding.id,
            selection: .init(agentID: try AgentID(validating: "codex"), selectedExecutable: executable),
            provenance: testLaunchProvenance
        ) else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        // Pre-source creation contract: capture the pinned executable and
        // probe its exact version before any registry preparation.
        let identity = try await CodexAppServerExecutableIdentity.capture(
            selectedURL: executable, deadline: .now.advanced(by: .seconds(20))
        )
        try await identity.probeVersion(at: root, deadline: .now.advanced(by: .seconds(20)))
        ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        materials = CodexAppServerNativeMaterials.owned(
            registry: tasks,
            ownership: ownership,
            executable: identity,
            workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(90))
        )
    }

    @MainActor
    func waitUntil(_ condition: @MainActor () -> Bool, within seconds: Double = 15) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
