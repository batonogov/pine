//
//  AgentTaskFilesystemAdmissionDriftTests.swift
//  PineTests
//
//  Filesystem drift between admission-lease capture and revalidation
//  (#1593): the OS restamps freshly created files asynchronously
//  (`com.apple.provenance` — a ctime-only bump), and git may rewrite a
//  control file in place or replace it. The lease must tolerate the
//  restamp, re-derive itself after a legitimate rewrite, and still reject
//  genuine identity changes.
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Agent task filesystem admission drift")
struct AgentTaskFilesystemAdmissionDriftTests {

    // MARK: - Fixtures

    private struct DriftFixture {
        let root: URL
        let repository: URL
        let worktree: URL
        let identity: AgentTaskProjectIdentity
        /// `<repository>/.git/worktrees/<name>/commondir` of the linked
        /// worktree — the regular-file descriptor whose captured ctime the
        /// OS restamps in production.
        let worktreeCommonDir: URL
        /// The linked worktree's `.git` pointer file.
        let worktreeControlFile: URL
    }

    private func makeDriftFixture(name: String) throws -> DriftFixture {
        let rawRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineAdmissionDrift-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rawRoot,
            withIntermediateDirectories: true
        )
        // `/tmp` is a symlink to `/private/tmp`; canonicalization in the
        // validator resolves it, so the fixture must ship resolved paths.
        let root = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let worktree = root.appendingPathComponent(
            "Worktree",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try runGit(["init", "--initial-branch=main"], at: repository)
        try runGit(
            ["config", "user.name", "Pine Admission Drift Tests"],
            at: repository
        )
        try runGit(
            ["config", "user.email", "admission-drift-tests@pine.invalid"],
            at: repository
        )
        try Data("drift-seed\n".utf8).write(
            to: repository.appendingPathComponent("seed.txt")
        )
        try runGit(["add", "--", "seed.txt"], at: repository)
        try runGit(["commit", "-m", "fixture"], at: repository)
        try runGit(
            ["worktree", "add", "-b", "feature/drift", "--", worktree.path],
            at: repository
        )
        let gitDirectory = repository.appendingPathComponent(
            ".git",
            isDirectory: true
        )
        return DriftFixture(
            root: root,
            repository: repository,
            worktree: worktree,
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: repository.path,
                canonicalWorktreePath: worktree.path
            ),
            worktreeCommonDir: gitDirectory
                .appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent("Worktree", isDirectory: true)
                .appendingPathComponent("commondir"),
            worktreeControlFile: worktree.appendingPathComponent(".git")
        )
    }

    private func removeFixture(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func runGit(
        _ arguments: [String],
        at directory: URL
    ) throws {
        let result = GitCommand.run(arguments, at: directory, timeout: 10)
        guard result.succeeded else {
            throw DriftFixtureError.gitFailed(
                arguments: arguments,
                diagnostics: result.errorOutput
            )
        }
    }

    private func makeProofAndLease(
        for fixture: DriftFixture
    ) async throws -> (
        proof: RecentAgentTaskRepositoryProof,
        lease: RecentAgentTaskFilesystemValidationLease
    ) {
        let identity = fixture.identity
        let proof = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.repositoryProof(for: identity)
        }.value
        #expect(proof != nil)
        let expectedProof = try #require(proof)
        let lease = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.validationLease(
                for: identity,
                expectedProof: expectedProof
            )
        }.value
        #expect(lease != nil)
        return (expectedProof, try #require(lease))
    }

    private func changeTimeNanoseconds(
        atPath path: String
    ) -> Int64? {
        var information = stat()
        guard stat(path, &information) == 0 else { return nil }
        return Int64(information.st_ctimespec.tv_sec) * 1_000_000_000
            + Int64(information.st_ctimespec.tv_nsec)
    }

    private func mode(atPath path: String) -> mode_t? {
        var information = stat()
        guard stat(path, &information) == 0 else { return nil }
        return information.st_mode & 0o7777
    }

    /// Rewrites `url` in place — same inode, fresh mtime/ctime — so only the
    /// timestamps drift and identity detection cannot mask a regression.
    private func rewriteInPlace(_ url: URL, contents: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: contents)
        try handle.close()
    }

    /// A metadata-only restamp, exactly like the OS provenance stamp: chmod
    /// with the mode the file already has updates ctime and nothing else.
    private func restampMetadataOnly(atPath path: String) throws {
        let currentMode = try #require(mode(atPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: Int(currentMode)],
            ofItemAtPath: path
        )
    }

    // MARK: - Descriptor drift tolerance

    @Test("OS provenance restamp keeps the lease valid")
    func provenanceRestampKeepsLeaseValid() async throws {
        let fixture = try makeDriftFixture(name: "ProvenanceRestamp")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        let beforeRestamp = try #require(
            changeTimeNanoseconds(
                atPath: fixture.worktreeCommonDir.path
            )
        )
        try restampMetadataOnly(atPath: fixture.worktreeCommonDir.path)
        // The restamp is the precondition this whole test exists for: if it
        // ever stops moving ctime on its own, the assertions below would
        // pass vacuously.
        let afterRestamp = try #require(
            changeTimeNanoseconds(
                atPath: fixture.worktreeCommonDir.path
            )
        )
        #expect(afterRestamp != beforeRestamp)

        let restamped = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(restamped)

        // Adopting the new ctime is a re-baseline, not a one-shot pardon:
        // a second validation with no further drift must also pass.
        let stable = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(stable)
    }

    @Test("A second restamp after an adopted one keeps the lease valid")
    func repeatedProvenanceRestampsStayValid() async throws {
        let fixture = try makeDriftFixture(name: "RepeatedRestamp")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        // Production observed the OS stamping the same fresh file more than
        // once (ctime deltas of +1.4 s and then +5.4 s on one probe). Each
        // restamp must be adoptable against the previously adopted baseline.
        for round in 0..<2 {
            try restampMetadataOnly(atPath: fixture.worktreeCommonDir.path)
            let validated = await Task.detached(priority: .utility) {
                lease.revalidate()
            }.value
            #expect(
                validated,
                "restamp round \(round) must not invalidate the lease"
            )
        }
    }

    @Test("Rewrite with an mtime rollback is the documented tolerance edge")
    func rewriteWithMtimeRollbackIsTolerated() async throws {
        let fixture = try makeDriftFixture(name: "MtimeRollback")
        defer { removeFixture(fixture.root) }

        // Pin the file to a millisecond-rounded mtime BEFORE the lease is
        // captured: a Date round-trips through double, so restoring a
        // git-written nanosecond mtime would not land bit-identical and the
        // test would fail on mtime, not on the behavior it exists to pin.
        let target = fixture.worktreeCommonDir
        let roundedModification = Date(
            timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000)
                .rounded(.down) / 1000
        )
        try FileManager.default.setAttributes(
            [.modificationDate: roundedModification],
            ofItemAtPath: target.path
        )
        let (_, lease) = try await makeProofAndLease(for: fixture)

        // This pins the security trade-off accepted in #1593: a same-size
        // rewrite followed by an mtime rollback leaves only ctime moved, and
        // ctime-only drift is tolerated because the OS itself produces it.
        // Detection of this synthetic sequence relies on the next whole-lease
        // re-derivation (proof comparison), not on per-descriptor stats.
        let original = try Data(contentsOf: target)
        try rewriteInPlace(target, contents: original)
        try FileManager.default.setAttributes(
            [.modificationDate: roundedModification],
            ofItemAtPath: target.path
        )

        let validated = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(validated)
    }

    @Test("In-place control-file rewrite with identical bytes is rejected")
    func inPlaceRewriteIsRejected() async throws {
        let fixture = try makeDriftFixture(name: "InPlaceRewrite")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        let original = try Data(contentsOf: fixture.worktreeCommonDir)
        try rewriteInPlace(fixture.worktreeCommonDir, contents: original)

        let validated = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(!validated)
    }

    @Test("Control-file replacement is rejected")
    func controlFileReplacementIsRejected() async throws {
        let fixture = try makeDriftFixture(name: "ControlReplacement")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        let original = try Data(contentsOf: fixture.worktreeCommonDir)
        try FileManager.default.removeItem(at: fixture.worktreeCommonDir)
        try original.write(to: fixture.worktreeCommonDir)

        let validated = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(!validated)
    }

    // MARK: - Lease re-derivation

    @Test("A rewritten control graph still re-derives the same lease")
    func rewrittenControlGraphRebuildsLease() async throws {
        let fixture = try makeDriftFixture(name: "RebuildLease")
        defer { removeFixture(fixture.root) }
        let (proof, lease) = try await makeProofAndLease(for: fixture)

        // Atomic rewrite is what git itself does (`git worktree repair`):
        // fresh inode, same logical pointer contents.
        let original = try Data(contentsOf: fixture.worktreeControlFile)
        try original.write(
            to: fixture.worktreeControlFile,
            options: .atomic
        )

        let stale = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        #expect(!stale)

        let identity = fixture.identity
        let rebuilt = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.validationLease(
                for: identity,
                expectedProof: proof
            )
        }.value
        #expect(rebuilt != nil)

        let rebuiltValid = await Task.detached(priority: .utility) {
            rebuilt?.revalidate()
        }.value
        #expect(rebuiltValid == true)
    }

    // MARK: - Manager-level re-arm

    @Test("Manager revalidation rebuilds the lease after a control rewrite")
    @MainActor
    func managerRebuildsAdmissionAfterControlRewrite() async throws {
        let fixture = try makeDriftFixture(name: "ManagerRebuild")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        let project = ProjectManager()
        project.loadDirectory(
            url: fixture.worktree,
            agentTaskProject: fixture.identity,
            filesystemAdmission: lease
        )
        let generationAtLoad = project
            .admissionGenerationForTesting

        let beforeRewrite = await project
            .revalidateAgentTaskFilesystemAdmission(
                workingDirectory: fixture.worktree
            )
        #expect(beforeRewrite)

        let original = try Data(contentsOf: fixture.worktreeControlFile)
        try original.write(
            to: fixture.worktreeControlFile,
            options: .atomic
        )

        // The captured lease is stale now; the manager must re-derive it
        // from the current graph instead of refusing forever (#1593).
        let afterRewrite = await project
            .revalidateAgentTaskFilesystemAdmission(
                workingDirectory: fixture.worktree
            )
        #expect(afterRewrite)

        // A rebuild re-derives the same rules, so it must not rotate the
        // admission generation: the workspace filesystem validator captured
        // at loadDirectory keeps validating against it, and a rotation would
        // suspend the file watcher on the next tree reload.
        #expect(
            project.admissionGenerationForTesting
                == generationAtLoad
        )
        let epochValidator = await project
            .revalidateAgentTaskFilesystemAdmission(
                expectedGeneration: generationAtLoad,
                workingDirectory: fixture.worktree
            )
        #expect(epochValidator)

        // The rebuilt lease is the new baseline: repeated validation with no
        // further drift stays valid.
        let stable = await project
            .revalidateAgentTaskFilesystemAdmission(
                workingDirectory: fixture.worktree
            )
        #expect(stable)
    }

    @Test("Manager revalidation refuses a worktree that changed identity")
    @MainActor
    func managerRefusesAfterWorktreeReplacement() async throws {
        let fixture = try makeDriftFixture(name: "ManagerRefuse")
        defer { removeFixture(fixture.root) }
        let (_, lease) = try await makeProofAndLease(for: fixture)

        let project = ProjectManager()
        project.loadDirectory(
            url: fixture.worktree,
            agentTaskProject: fixture.identity,
            filesystemAdmission: lease
        )

        // Swap the worktree for a different worktree of the same shape: the
        // inode identity of the worktree root changes, and no re-derivation
        // can honestly admit the replacement.
        let replacement = fixture.root.appendingPathComponent(
            "Replacement",
            isDirectory: true
        )
        try runGit(
            ["worktree", "add", "-b", "feature/replacement", "--",
             replacement.path],
            at: fixture.repository
        )
        try FileManager.default.removeItem(at: fixture.worktree)
        var isDirectory: ObjCBool = false
        try FileManager.default.moveItem(
            at: replacement,
            to: fixture.worktree
        )
        #expect(FileManager.default.fileExists(
            atPath: fixture.worktree.path,
            isDirectory: &isDirectory
        ))

        // First refusal attempts a throttled rebuild that cannot reproduce
        // the proof; validation must stay false.
        for _ in 0..<3 {
            let validated = await project
                .revalidateAgentTaskFilesystemAdmission(
                    workingDirectory: fixture.worktree
                )
            #expect(!validated)
        }
    }
}

private enum DriftFixtureError: Error {
    case gitFailed(arguments: [String], diagnostics: String)
}
