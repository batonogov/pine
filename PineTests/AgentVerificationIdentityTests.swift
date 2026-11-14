import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("Content-bound ADE identities", .serialized)
nonisolated struct AgentVerificationIdentityTests {
    @Test func dirtyAndUntrackedSameSizeEditsChangeContentIdentity() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "base")
        try fixture.commit()
        try fixture.write("tracked.txt", "dirt")
        try fixture.write("draft.txt", "abc")
        let status = try fixture.git(["status", "--porcelain"])
        let before = try await fixture.current()
        let tracked = fixture.root.appending(path: "tracked.txt")
        let date = try #require(FileManager.default.attributesOfItem(atPath: tracked.path)[.modificationDate] as? Date)
        try fixture.write("tracked.txt", "edit")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tracked.path)
        let after = try await fixture.current()
        #expect(try fixture.git(["status", "--porcelain"]) == status)
        #expect(before.code.trackedFingerprint != after.code.trackedFingerprint)
        try fixture.write("draft.txt", "xyz")
        let untracked = try await fixture.current()
        #expect(try fixture.git(["status", "--porcelain"]) == status)
        #expect(after.code.untrackedFingerprint != untracked.code.untrackedFingerprint)
    }

    @Test func repeatedCaptureAndEnvironmentOrderingAreStable() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("space name.txt", "雪\n")
        try fixture.commit()
        let first = try await fixture.current(environment: ["B": "2", "A": "1"])
        let second = try await fixture.current(environment: ["A": "1", "B": "2"])
        #expect(first == second)
        let changed = try await fixture.current(environment: ["A": "new", "B": "2"])
        #expect(changed.code == second.code)
        #expect(changed.environment != second.environment)
    }

    @Test func ignoredInputsAreContentBoundAndDeclaredOutputsDoNotInvalidateBuilds() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write(".gitignore", "build/\ngenerated/\n")
        try fixture.write("source.txt", "source")
        try fixture.commit()
        try fixture.write("generated/input", "one")
        let policy = AgentVerificationCapturePolicy(declaredOutputs: ["build"], requiredIgnoredInputs: ["generated/input"])
        let first = try await fixture.current(policy: policy)
        try fixture.write("build/output", "result")
        let built = try await fixture.current(policy: policy)
        #expect(built == first)
        try fixture.write("generated/input", "two")
        let changed = try await fixture.current(policy: policy)
        #expect(changed.code.ignoredRelevantFingerprint != built.code.ignoredRelevantFingerprint)
        let invalidPolicy = AgentVerificationCapturePolicy(declaredOutputs: ["source.txt"], requiredIgnoredInputs: [])
        #expect(await fixture.capture(policy: invalidPolicy).isCurrent == false)
    }

    @Test func includedSymlinkCannotReadThroughExcludedOutput() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write(".gitignore", "build/\n")
        try fixture.commit()
        try fixture.write("build/input", "outside input coverage")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "source-link").path,
                                                  withDestinationPath: "build/input")
        let policy = AgentVerificationCapturePolicy(declaredOutputs: ["build"], requiredIgnoredInputs: [])
        #expect(await fixture.capture(policy: policy).isCurrent == false)
    }

    @Test func modesRenamesDeletionsAndContainedSymlinkTargetsAreInputs() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("first", "same")
        try fixture.write("second", "same")
        try fixture.commit()
        let before = try await fixture.current()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.appending(path: "first").path)
        let executable = try await fixture.current()
        #expect(executable.code != before.code)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "link").path, withDestinationPath: "first")
        let firstLink = try await fixture.current()
        try FileManager.default.removeItem(at: fixture.root.appending(path: "link"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "link").path, withDestinationPath: "second")
        let secondLink = try await fixture.current()
        #expect(secondLink.code != firstLink.code)
        try FileManager.default.moveItem(at: fixture.root.appending(path: "second"), to: fixture.root.appending(path: "renamed"))
        let renamed = try await fixture.current()
        #expect(renamed.code != secondLink.code)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "renamed"))
        #expect(try await fixture.current().code != renamed.code)
    }

    @Test func externalLinksUnreadableInputsAndMovedRootsFailClosed() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "value")
        try fixture.commit()
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "outside").path,
                                                  withDestinationPath: "/etc/hosts")
        #expect(await fixture.capture().isCurrent == false)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "outside"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.root.appending(path: "source").path)
        #expect(await fixture.capture().isCurrent == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.root.appending(path: "source").path)
        let lease = try fixture.lease()
        try FileManager.default.moveItem(at: fixture.root, to: fixture.parent.appending(path: "moved"))
        let capture = try fixture.service(lease: lease)
        #expect(await capture.capture().isCurrent == false)
    }

    @Test func unsavedBufferMustMatchDiskAndRemainCurrent() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "disk")
        try fixture.commit()
        let mismatch = AgentVerificationEditorPreflight.available([
            AgentVerificationUnsavedInput(relativePath: "source", saveBytes: Data("edit".utf8)),
        ], isCurrent: { true })
        #expect(await fixture.capture(editor: mismatch).isCurrent == false)
        let same = AgentVerificationEditorPreflight.available([
            AgentVerificationUnsavedInput(relativePath: "source", saveBytes: Data("disk".utf8)),
        ], isCurrent: { true })
        #expect(await fixture.capture(editor: same).isCurrent)
        #expect(await fixture.capture(editor: .available([], isCurrent: { false })).isCurrent == false)
        #expect(await fixture.capture(editor: .unavailable).isCurrent == false)
    }

    @Test func cancellationAndResourceBudgetsCannotReturnPartialIdentity() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("one", "source")
        try fixture.write("two", "source")
        try fixture.commit()
        let token = GitCommandCancellationToken()
        token.cancel()
        #expect(try await fixture.service(cancellation: token).capture().isCurrent == false)
        var limited = try fixture.service()
        limited.filesystemLimits.maximumEntries = 1
        #expect(await limited.capture().isCurrent == false)
        limited = try fixture.service()
        limited.filesystemLimits.maximumFileBytes = 1
        #expect(await limited.capture().isCurrent == false)
        let lease = try fixture.lease()
        let during = GitCommandCancellationToken()
        let inspector = AgentVerificationGitInspector(lease: lease, cancellation: during, deadline: .now.advanced(by: .seconds(15)))
        let collector = AgentVerificationFilesystemFingerprint(
            lease: lease, limits: .init(), policy: .conservative, editor: .available([], isCurrent: { true }),
            cancellation: during, gitSnapshot: { try inspector.capture() }, didReadFile: { _ in during.cancel() }
        )
        let refused = await runOnBackground { (try? collector.capture()) == nil }
        #expect(refused)
    }

    @Test func dirtyUntrackedAndCommittedSubmoduleChangesAreCovered() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let child = try IdentityFixture()
        defer { child.cleanup() }
        try child.write("value", "one")
        try child.commit()
        _ = try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", child.root.path, "modules/sub"])
        try fixture.commit()
        let first = try await fixture.current()
        try fixture.write("modules/sub/value", "two")
        let dirty = try await fixture.current()
        #expect(dirty.code.trackedFingerprint != first.code.trackedFingerprint)
        try fixture.write("modules/sub/draft", "draft")
        let untracked = try await fixture.current()
        #expect(untracked.code.untrackedFingerprint != dirty.code.untrackedFingerprint)
        _ = try fixture.git(["-C", fixture.root.appending(path: "modules/sub").path, "add", "value"])
        _ = try fixture.git(["-C", fixture.root.appending(path: "modules/sub").path, "commit", "-qm", "submodule revision"])
        #expect(try await fixture.current().code != untracked.code)
    }

    @Test func unbornRepositoryAndStagedVersusUnstagedChangesAreDistinct() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let unborn = try await fixture.current()
        #expect(unborn.code.headCommit == nil)
        try fixture.write("source", "base")
        try fixture.commit()
        try fixture.write("source", "stage")
        _ = try fixture.git(["add", "source"])
        let staged = try await fixture.current()
        try fixture.write("source", "dirty")
        let unstaged = try await fixture.current()
        #expect(staged.code != unstaged.code)
        _ = try fixture.git(["add", "source"])
        let newlyStaged = try await fixture.current()
        #expect(newlyStaged.code != unstaged.code)
    }

    @Test func replacementDuringReadCannotProduceCurrentCode() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "before")
        try fixture.commit()
        let lease = try fixture.lease()
        let token = GitCommandCancellationToken()
        let inspector = AgentVerificationGitInspector(lease: lease, cancellation: token, deadline: .now.advanced(by: .seconds(15)))
        let collector = AgentVerificationFilesystemFingerprint(
            lease: lease, limits: .init(), policy: .conservative, editor: .available([], isCurrent: { true }),
            cancellation: token, gitSnapshot: { try inspector.capture() }, didReadFile: { relative in
                if relative == "source" { try? fixture.write("source", "after!") }
            }
        )
        #expect(await runOnBackground { (try? collector.capture()) == nil })
    }

    @Test func selectedFileLeaseWitnessesParentAliasesAndRejectsLeafReplacement() throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let file = fixture.parent.appending(path: "observed-tool")
        try Data("tool".utf8).write(to: file)
        let lease = try #require(RecentAgentTaskFilesystemValidator.selectedFileLease(for: file))
        #expect(lease.revalidate())
        try FileManager.default.moveItem(at: file, to: fixture.parent.appending(path: "retired-tool"))
        try Data("tool".utf8).write(to: file)
        #expect(!lease.revalidate())
        let link = fixture.parent.appending(path: "tool-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(RecentAgentTaskFilesystemValidator.selectedFileLease(for: link) == nil)
        let fifo = fixture.parent.appending(path: "not-a-regular-input")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(RecentAgentTaskFilesystemValidator.selectedFileLease(for: fifo) == nil)
    }

    @Test func sha256RepositoryHeadsHaveCurrentContentIdentity() async throws {
        let fixture = try IdentityFixture(objectFormat: "sha256")
        defer { fixture.cleanup() }
        try fixture.write("source", "content")
        try fixture.commit()
        let current = try await fixture.current()
        #expect(current.code.headCommit?.utf8.count == 64)
        #expect(AgentTaskMetadataStore.validCodeState(current.code))
    }

    @Test func invalidUTF8IsExplicitWithoutChangingDisplaySuccess() {
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["\\377"],
            at: FileManager.default.temporaryDirectory, timeout: 5
        )
        #expect(result.succeeded)
        #expect(!result.outputIsValidUTF8)
        #expect(!result.output.isEmpty)
    }

    @Test func toolAndConfigurationContentChangesInvalidateEnvironment() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "source")
        try fixture.commit()
        let tool = fixture.parent.appending(path: "tool")
        let config = fixture.parent.appending(path: "configuration")
        try Data("tool-one".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try Data("one".utf8).write(to: config)
        let capture = AgentVerificationIdentityCapture(
            inputs: .init(lease: try fixture.lease(), policy: .conservative, editor: .available([], isCurrent: { true }),
                          tools: [tool], configurationFiles: [config]),
            environmentValues: { [:] }, cancellation: GitCommandCancellationToken()
        )
        let firstResult = await capture.capture()
        let first = try #require(firstResult.snapshot, "Capture result: \(String(describing: firstResult))")
        try Data("tool-two".utf8).write(to: tool)
        let changedTool = try #require(await capture.capture().snapshot)
        #expect(first.code == changedTool.code)
        #expect(first.environment.toolchain != changedTool.environment.toolchain)
        try Data("two".utf8).write(to: config)
        let changedConfig = try #require(await capture.capture().snapshot)
        #expect(changedConfig.environment.configurationFingerprint != changedTool.environment.configurationFingerprint)
    }
}

@Suite("Current identity gates shared evidence", .serialized)
nonisolated struct AgentVerificationIdentityEvidenceTests {
    @Test func changedDiskCannotAuthorizeOldReadyOrResultIdentity() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "state-A")
        try fixture.commit()
        let first = try await fixture.current()
        var task = await verifiedTask(first, root: fixture.root)
        #expect(AgentTaskLifecycleReducer.readiness(
            for: task, codeState: first.code, environment: first.environment
        ).isReady)
        let oldAccepted = task.acceptedSnapshot
        let oldReviewed = task.reviewedSnapshot
        try fixture.write("source", "state-B")
        let second = try await fixture.current()
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task, codeState: second.code, environment: second.environment
        ).isReady)
        #expect(try await fixture.service().revalidate(first).isCurrent == false)
        _ = AgentTaskLifecycleReducer.invalidate(&task, codeState: second.code, environment: second.environment)
        #expect(task.verificationState == .stale)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.acceptedSnapshot == oldAccepted)
        #expect(task.reviewedSnapshot == oldReviewed)
    }

    @MainActor
    private func verifiedTask(_ snapshot: AgentVerificationIdentitySnapshot, root: URL) -> AgentTask {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let terminal = UUID()
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(canonicalProjectPath: root.path, canonicalWorktreePath: root.path),
                route: AgentTaskRoute(paneID: UUID(), tabID: terminal, terminalID: terminal),
                origin: .discoveredInTerminal, observedAt: timestamp
            )
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: terminal,
            process: AgentProcessEvidence(processIdentifier: 9_999, processGeneration: 1,
                                          startIdentifier: "fixture", observedStartedAt: timestamp, startIsAuthoritative: true),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: timestamp)
        ))
        run.outcome = .success
        task.runs = [run]
        task.lifecycle = .completed
        task.completedAt = timestamp
        task.verificationState = .verified
        task.environment = snapshot.environment
        task.acceptanceState = .accepted
        task.evidence = [AgentTaskEvidenceKind.agentReportedCompletion, .independentCheck, .reviewerOutcome].map { kind in
            AgentTaskEvidenceFact(
                kind: kind, runID: run.id, processGeneration: 1, trust: .verified,
                result: kind == .agentReportedCompletion ? .reported : .succeeded,
                observedAt: timestamp, codeState: snapshot.code, environment: snapshot.environment,
                preOperationCodeState: kind == .agentReportedCompletion ? nil : snapshot.code,
                postOperationCodeState: kind == .agentReportedCompletion ? nil : snapshot.code
            )
        }
        let reviewed = AgentTaskResultSnapshot(runID: run.id, outcome: .success, codeState: snapshot.code,
                                               environment: snapshot.environment, recordedAt: timestamp)
        task.reviewedSnapshot = reviewed
        task.acceptedSnapshot = reviewed
        return task
    }
}

@Suite("Whole-capture identity consistency", .serialized)
nonisolated struct AgentVerificationCaptureConsistencyTests {
    @Test func restoredGitConfigurationDuringPayloadReadsRefusesSnapshot() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("z", "zzz")
        try fixture.commit()
        let config = fixture.root.appending(path: ".git/config")
        let original = try Data(contentsOf: config)
        let lease = try fixture.lease()
        let token = GitCommandCancellationToken()
        let inspector = AgentVerificationGitInspector(
            lease: lease, cancellation: token, deadline: .now.advanced(by: .seconds(15))
        )
        let collector = AgentVerificationFilesystemFingerprint(
            lease: lease, limits: .init(), policy: .conservative,
            editor: .available([], isCurrent: { true }), cancellation: token,
            gitSnapshot: { try inspector.capture() }, didReadFile: { _ in
                try? (original + Data("\n# transient mutation\n".utf8)).write(to: config)
                try? original.write(to: config)
            }
        )
        #expect(await runOnBackground { (try? collector.capture()) == nil })
        #expect(try Data(contentsOf: config) == original)
    }

    @Test func restoredSelectedToolDuringObservationRefusesSnapshot() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "source")
        let tool = fixture.parent.appending(path: "tool")
        let original = Data("original".utf8)
        try original.write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let capture = AgentVerificationIdentityCapture(
            inputs: .init(lease: try fixture.lease(), policy: .conservative,
                          editor: .available([], isCurrent: { true }), tools: [tool], configurationFiles: []),
            environmentValues: {
                try? Data("modified".utf8).write(to: tool)
                try? original.write(to: tool)
                return [:]
            }, cancellation: GitCommandCancellationToken()
        )
        let result = await capture.capture()
        if case .changed = result {} else { Issue.record("Restored tool mutation must invalidate observation") }
        #expect(try Data(contentsOf: tool) == original)
    }

    @Test func observationBudgetIncludesBothSidesOfCapture() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "source")
        let tool = fixture.parent.appending(path: "tool")
        try Data("tool".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var capture = AgentVerificationIdentityCapture(
            inputs: .init(lease: try fixture.lease(), policy: .conservative,
                          editor: .available([], isCurrent: { true }), tools: [tool], configurationFiles: []),
            environmentValues: { [:] }, cancellation: GitCommandCancellationToken()
        )
        capture.maximumObservedBytes = 7 // One observation fits, both require eight bytes.
        if case .unavailable(.budgetExceeded) = await capture.capture() {} else {
            Issue.record("Observation budget must span both sides of capture")
        }
    }

    @Test func symlinkIntoSkippedGitControlTreeRefusesCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "source"), withDestinationURL: fixture.root.appending(path: ".git/config")
        )
        let result = await fixture.capture()
        #expect(!result.isCurrent)
    }

    @Test func unscopedGitConfigIncludeRefusesCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "source")
        let external = fixture.parent.appending(path: "included-config")
        try Data("[untrusted]\nvalue = included\n".utf8).write(to: external)
        _ = try fixture.git(["config", "include.path", external.path])
        let result = await fixture.capture()
        if case .unavailable(.incompleteCoverage) = result {} else {
            Issue.record("Unscoped Git include must refuse capture")
        }
    }

    @Test func laterReadMutationOfPreviouslyReadFileRefusesSnapshot() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("a", "one")
        try fixture.write("z", "zzz")
        try fixture.commit()
        let lease = try fixture.lease()
        let token = GitCommandCancellationToken()
        let inspector = AgentVerificationGitInspector(
            lease: lease, cancellation: token, deadline: .now.advanced(by: .seconds(15))
        )
        let collector = AgentVerificationFilesystemFingerprint(
            lease: lease, limits: .init(), policy: .conservative,
            editor: .available([], isCurrent: { true }), cancellation: token,
            gitSnapshot: { try inspector.capture() }, didReadFile: { relative in
                // In-place same-size write changes no directory entry or Git
                // index/HEAD. The earlier file must remain witnessed globally.
                if relative == "z" { try? Data("two".utf8).write(to: fixture.root.appending(path: "a")) }
            }
        )
        let refused = await runOnBackground { (try? collector.capture()) == nil }
        #expect(try String(contentsOf: fixture.root.appending(path: "a"), encoding: .utf8) == "two")
        #expect(refused)
    }
}

@Suite("Descriptor-backed coverage boundaries", .serialized)
nonisolated struct AgentVerificationCoverageBoundaryTests {
    @Test func caseAliasIntoGitControlTreeCannotGrantCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let actual = fixture.root.appending(path: ".git/config")
        let alias = fixture.root.appending(path: ".GIT/config")
        // This regression exercises the case-insensitive supported local
        // filesystem explicitly; an unresolved alias cannot exercise the bug.
        #expect(try Data(contentsOf: alias) == Data(contentsOf: actual))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "source").path,
                                                  withDestinationPath: ".GIT/config")
        #expect(!(await fixture.capture()).isCurrent)
    }

    @Test func caseAliasIntoDeclaredOutputCannotGrantCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("build/object", "uncovered")
        #expect(try Data(contentsOf: fixture.root.appending(path: "BUILD/object")) == Data("uncovered".utf8))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "source").path,
                                                  withDestinationPath: "BUILD/object")
        let policy = AgentVerificationCapturePolicy(declaredOutputs: ["build"], requiredIgnoredInputs: [])
        #expect(!(await fixture.capture(policy: policy)).isCurrent)
    }

    @Test func parentTraversalAfterSymlinkCannotEscapeCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("secret", "inside")
        try Data("outside".utf8).write(to: fixture.parent.appending(path: "secret"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "alias").path,
                                                  withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "source").path,
                                                  withDestinationPath: "alias/../secret")
        #expect(try String(contentsOf: fixture.root.appending(path: "source"), encoding: .utf8) == "outside")
        #expect(!(await fixture.capture()).isCurrent)
    }

    @Test func witnessedMissingSymlinkTargetChangesIdentityWhenCreated() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appending(path: "source").path,
                                                  withDestinationPath: "missing/nested/input")
        let absent = try await fixture.current()
        try fixture.write("missing/nested/input", "now included")
        let present = try await fixture.current()
        #expect(absent.code != present.code)
    }

    @Test func localGitWorktreeRedirectCannotGrantCoverage() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        try fixture.write("source", "inside")
        try fixture.commit()
        let outside = fixture.parent.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: outside.appending(path: "untracked-outside"))
        _ = try fixture.git(["config", "core.worktree", outside.path])
        let redirected = try fixture.git(["ls-files", "--others", "--exclude-standard"])
        #expect(redirected.contains("untracked-outside"))
        #expect(!(await fixture.capture()).isCurrent)
    }
}

nonisolated private struct IdentityFixture: Sendable {
    let parent: URL
    let root: URL

    init(objectFormat: String = "sha1") throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "PineIdentity-\(UUID().uuidString)")
        root = parent.appending(path: "repo")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try git(["init", "-q", "--object-format=" + objectFormat])
    }

    func cleanup() { try? FileManager.default.removeItem(at: parent) }

    func write(_ relative: String, _ text: String) throws {
        let file = root.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func commit() throws {
        _ = try git(["add", "-A"])
        _ = try git(["commit", "-qm", "fixture"])
    }

    func git(_ arguments: [String]) throws -> String {
        var environment = ["-i", "PATH=/usr/bin:/bin", "HOME=/var/empty", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { environment.append("DEVELOPER_DIR=" + developer) }
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: environment + [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Pine Test",
                "-c", "user.email=pine@example.invalid", "-c", "commit.gpgsign=false",
            ] + arguments,
            at: root, timeout: 10
        )
        guard result.succeeded else { throw CocoaError(.fileReadUnknown) }
        return result.output
    }

    func lease() throws -> RecentAgentTaskFilesystemValidationLease {
        let identity = AgentTaskProjectIdentity(canonicalProjectPath: root.path, canonicalWorktreePath: root.path)
        return try #require(RecentAgentTaskFilesystemValidator.validationLease(for: identity, expectedProof: nil))
    }

    func service(
        lease: RecentAgentTaskFilesystemValidationLease? = nil,
        policy: AgentVerificationCapturePolicy = .conservative,
        editor: AgentVerificationEditorPreflight = .available([], isCurrent: { true }),
        cancellation: GitCommandCancellationToken = GitCommandCancellationToken(),
        environment: [String: String] = [:]
    ) throws -> AgentVerificationIdentityCapture {
        let selected: RecentAgentTaskFilesystemValidationLease
        if let lease { selected = lease } else { selected = try self.lease() }
        return AgentVerificationIdentityCapture(
            inputs: .init(lease: selected, policy: policy, editor: editor,
                          tools: [URL(fileURLWithPath: "/usr/bin/true")], configurationFiles: []),
            environmentValues: { environment }, cancellation: cancellation
        )
    }

    func capture(
        policy: AgentVerificationCapturePolicy = .conservative,
        editor: AgentVerificationEditorPreflight = .available([], isCurrent: { true })
    ) async -> AgentVerificationIdentityCaptureResult {
        do {
            return try await service(policy: policy, editor: editor).capture()
        } catch {
            return .unavailable(.unavailableBinding)
        }
    }

    func current(
        policy: AgentVerificationCapturePolicy = .conservative, environment: [String: String] = [:]
    ) async throws -> AgentVerificationIdentitySnapshot {
        let capture = try service(policy: policy, environment: environment)
        return try #require(await capture.capture().snapshot)
    }
}

nonisolated private extension AgentVerificationIdentityCaptureResult {
    var snapshot: AgentVerificationIdentitySnapshot? {
        if case .current(let value) = self { return value }
        return nil
    }
    var isCurrent: Bool { snapshot != nil }
}
