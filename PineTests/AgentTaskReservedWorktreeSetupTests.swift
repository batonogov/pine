import Darwin
import Foundation
import Synchronization
import Testing
@testable import Pine

struct AgentTaskReservedWorktreeSetupTests {
    @Test func adoptedAuthorityIsSynchronouslyRevokedWithoutInvalidatingFilesystemEvidence() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let checkpoint = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { value in checkpoint.withLock { $0 = value }; return true } == .adopted)
        let binding = try await owner.reconcile { _ in true }
        let filesystem = try await bindings.revalidate(binding)
        try binding.validateAuthority()
        #expect(await runOnBackground { filesystem.revalidate() })

        owner.revokeAuthority()
        // No actor hop or cleanup may be needed to fence a retained executor.
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try binding.validateAuthority() }
        #expect(await runOnBackground {
            (try? binding.validateAuthority()) != nil && filesystem.revalidate()
        } == false)
        // Unchanged filesystem evidence is not an execution authority.
        #expect(await runOnBackground { filesystem.revalidate() })
        await #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try await bindings.revalidate(binding) }

        await owner.releaseRevokedReservation()
        let saved = try #require(checkpoint.withLock { $0 })
        let restored = try await bindings.restore(saved.reservation)
        let replacement = AgentTaskReservedWorktreeSetup(lease: restored, bindings: bindings, recovering: saved)
        let replacementBinding = try await replacement.reconcile { _ in true }
        let replacementFilesystem = try await bindings.revalidate(replacementBinding)
        #expect(replacementBinding.id != binding.id)
        owner.revokeAuthority()
        try replacementBinding.validateAuthority()
        await owner.releaseRevokedReservation()
        try replacementBinding.validateAuthority()
        #expect(await runOnBackground { replacementFilesystem.revalidate() })
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try binding.validateAuthority() }
    }

    @Test func createsOnceAcrossConcurrentSubmissionsAndOwnersThenAdoptsMetadata() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let dispatches = Mutex(0)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            if argv.contains("add") { dispatches.withLock { $0 += 1 } }
            return GitCommand.spawn(executable, arguments: argv, directory: directory)
        })
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls)
        let gate = ReservedSetupIntentGate()
        let first = Task { await owner.create { _ in await gate.record() } }
        defer { first.cancel() }
        #expect(await gate.waitForIntent())
        #expect(await owner.create { _ in Issue.record("duplicate intent"); return true } == .inProgress)
        let secondOwner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls)
        #expect(await secondOwner.create { _ in Issue.record("duplicate intent"); return true } == .reconciliationRequired)
        gate.release()
        #expect(await first.value == .adopted)
        #expect(await owner.create { _ in Issue.record("duplicate intent"); return true } == .adopted)
        #expect(dispatches.withLock { $0 } == 1)
        let binding = try await owner.reconcile { _ in true }
        #expect(binding == (try await owner.reconcile { _ in true }))
        let validated = try await bindings.revalidate(binding)
        #expect(await runOnBackground { validated.revalidate() })
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("tracked".utf8))
    }

    @Test func hostileHooksFiltersAndFsmonitorNeverExecute() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        try await runOnBackground {
            let hooks = fixture.root.appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
            let script = "#!/bin/sh\nprintf executed >> '\(fixture.marker.path)'\n"
            let hook = hooks.appendingPathComponent("post-checkout")
            try script.write(to: hook, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
            for (key, value) in [
                ("core.hooksPath", hooks.path), ("core.fsmonitor", hook.path),
                ("filter.pine-hostile.smudge", hook.path), ("filter.pine-hostile.process", hook.path),
                ("filter.pine-hostile.required", "true"), ("submodule.recurse", "true")
            ] {
                try fixture.git(["config", key, value])
            }
        }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { _ in true } == .adopted)
        _ = try await owner.reconcile { _ in true }
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        try await runOnBackground {
            let tracked = try Data(contentsOf: fixture.target.appendingPathComponent("tracked"))
            let executable = fixture.target.appendingPathComponent("executable")
            let contents = try Data(contentsOf: executable)
            let mode = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.target.appendingPathComponent("link").path)
            #expect(tracked == Data("tracked".utf8))
            #expect(contents == Data("#!/bin/sh\n".utf8))
            #expect(mode?.intValue == 0o755)
            #expect(link == "tracked")
        }
    }

    @Test func environmentUsesAnExplicitAllowlist() {
        let argv = AgentTaskReservedWorktreeSetup.arguments(["worktree", "add"])
        #expect(argv.first == "-i")
        let git = argv.firstIndex(of: "/usr/bin/git")
        #expect(git != nil)
        let environment = argv.dropFirst().prefix { $0 != "/usr/bin/git" }
        #expect(environment.allSatisfy {
            ["PATH", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ATTR_NOSYSTEM",
             "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_NO_LAZY_FETCH"].contains(String($0.prefix { $0 != "=" }))
        })
        #expect(!argv.contains { $0.hasPrefix("DEVELOPER_DIR=") || $0.hasPrefix("HOME=") || $0.hasPrefix("GIT_DIR=") })
        #expect(argv.contains("core.hooksPath=/dev/null"))
        #expect(argv.contains("core.fsmonitor=false"))
    }

    @Test func inheritedGitSelectorsAndInjectedConfigAreScrubbedBeforeGit() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            GitCommand.spawn(executable, arguments: [
                "GIT_DIR=/does-not-exist", "GIT_WORK_TREE=/does-not-exist",
                "GIT_COMMON_DIR=/does-not-exist", "GIT_INDEX_FILE=/does-not-exist",
                "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=core.bare", "GIT_CONFIG_VALUE_0=true",
                "GIT_TRACE=\(fixture.marker.path)", "GIT_CONFIG_PARAMETERS='invalid'",
                executable.path
            ] + argv, directory: directory)
        })
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls)
        #expect(await owner.create { _ in true } == .adopted)
        _ = try await owner.reconcile { _ in true }
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test func existingUnrelatedTargetIsPreservedWithoutIntentOrCreation() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        try await runOnBackground { try Data("user data".utf8).write(to: fixture.target) }
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { _ in Issue.record("unexpected intent"); return true } == .blocked)
        #expect(try Data(contentsOf: fixture.target) == Data("user data".utf8))
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await owner.reconcile { _ in true } }
    }

    @Test func absentButRegisteredTargetNeverGetsRecreated() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        try await runOnBackground {
            try fixture.git(["worktree", "add", "--no-checkout", "-b", "unrelated", fixture.target.path])
            try FileManager.default.moveItem(at: fixture.target, to: fixture.root.appendingPathComponent("preserved"))
        }
        #expect(await runOnBackground { lease.revalidate() })
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { _ in Issue.record("unexpected intent"); return true } == .blocked)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func lostCompletionAfterCreateRequiresExplicitRecoveryAndNeverRetries() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let mutationPID = Mutex<pid_t?>(nil)
        let mutationReaped = Mutex(false)
        let dispatches = Mutex(0)
        let calls = GitCommandSystemCalls(
            waitpid: { pid, status, options in
                // Hide confirmed completion until the deadline. The kill seam
                // below never signals the reaped PID (which could be reused).
                if mutationPID.withLock({ $0 }) == pid {
                    if mutationReaped.withLock({ $0 }) { return 0 }
                    let observed = Darwin.waitpid(pid, status, options)
                    if observed == pid {
                        mutationReaped.withLock { $0 = true }
                        return 0
                    }
                    return observed
                }
                return Darwin.waitpid(pid, status, options)
            },
            kill: { pid, signal in
                if mutationPID.withLock({ $0 }) == -pid, mutationReaped.withLock({ $0 }) {
                    mutationPID.withLock { $0 = nil }
                    return 0
                }
                return Darwin.kill(pid, signal)
            },
            spawn: { executable, argv, directory in
                let spawned = GitCommand.spawn(executable, arguments: argv, directory: directory)
                if argv.contains("add"), case .success(let child) = spawned {
                    dispatches.withLock { $0 += 1 }
                    mutationPID.withLock { $0 = child.processIdentifier }
                }
                return spawned
            }
        )
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls, timeout: 5)
        let saved = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        #expect(await owner.create { value in saved.withLock { $0 = value }; return true } == .reconciliationRequired)
        #expect(FileManager.default.fileExists(atPath: fixture.target.path))
        #expect(await owner.create { _ in Issue.record("retry"); return true } == .reconciliationRequired)
        let recovered = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, recovering: saved.withLock { $0 })
        _ = try await recovered.reconcile { _ in true }
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("tracked".utf8))
        #expect(dispatches.withLock { $0 } == 1)
    }

    @Test func revokedOwnershipAtIntentBoundaryPreventsEffect() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { _ in
            await bindings.revoke(taskID: lease.taskID, runID: lease.reservationRunID)
            return true
        } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test(arguments: [true, false]) func replacedParentOrProjectPreventsEffect(replaceParent: Bool) async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { _ in
            try await runOnBackground {
                let replaced = replaceParent ? fixture.target.deletingLastPathComponent() : fixture.project
                try FileManager.default.moveItem(at: replaced, to: fixture.root.appendingPathComponent("preserved"))
                try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
            }
            return true
        } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test(arguments: ["valid", "wrongBranch", "foreignRepository", "reportedWrongBranch"])
    func recoveryRequiresExactBranchAndRepository(scenario: String) async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let base = try await runOnBackground { try fixture.output(["rev-parse", "--verify", "HEAD"]) }
        let branch = AgentTaskEnvironmentBindings.branchName(taskID: lease.taskID, runID: lease.reservationRunID)
        try await runOnBackground {
            let repository: URL
            if scenario == "foreignRepository" {
                repository = fixture.root.appendingPathComponent("foreign")
                let bundle = fixture.root.appendingPathComponent("objects.bundle")
                try fixture.git(["bundle", "create", bundle.path, "HEAD"])
                try fixture.git(["init", "-b", "main", repository.path])
                try fixture.git(["bundle", "unbundle", bundle.path], at: repository)
                try fixture.git(["update-ref", "refs/heads/main", base], at: repository)
            } else {
                repository = fixture.project
            }
            let actualBranch = scenario == "wrongBranch" ? "unrelated" : branch
            try fixture.git(["worktree", "add", "--no-checkout", "-b", actualBranch,
                "--", fixture.target.path, base], at: repository)
            #expect(try fixture.output(["rev-parse", "--verify", "HEAD"], at: fixture.target) == base)
            #expect(try fixture.output(["symbolic-ref", "--short", "HEAD"], at: fixture.target) == actualBranch)
            let proof = try #require(RecentAgentTaskFilesystemValidator.repositoryProof(for:
                AgentTaskProjectIdentity(canonicalProjectPath: repository.path, canonicalWorktreePath: fixture.target.path)))
            #expect(proof.hasExactWorktreeInstance)
            #expect(proof.identifiesSameRepository(as: lease.snapshot.repositoryProof) == (scenario != "foreignRepository"))
            #expect(lease.revalidateOrigin())
            #expect((lease.createdFilesystemLease() != nil) == (scenario != "foreignRepository"))
        }
        let branchReads = Mutex(0)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            if Array(argv.suffix(3)) == ["symbolic-ref", "--short", "HEAD"] {
                branchReads.withLock { $0 += 1 }
                if scenario == "reportedWrongBranch" {
                    return GitCommand.spawn(URL(fileURLWithPath: "/usr/bin/printf"),
                        arguments: ["%s\n", "unrelated"], directory: directory)
                }
            }
            return GitCommand.spawn(executable, arguments: argv, directory: directory)
        })
        let checkpoint = AgentTaskReservedWorktreeCheckpoint(
            reservation: lease.snapshot, baseCommit: base, phase: .creationIntent, worktreeProof: nil)
        let owner = AgentTaskReservedWorktreeSetup(
            lease: lease, bindings: bindings, recovering: checkpoint, systemCalls: calls)
        if scenario == "valid" {
            let binding = try await owner.reconcile { _ in true }
            _ = try await bindings.revalidate(binding)
            try binding.validateAuthority()
            #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("tracked".utf8))
        } else {
            await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
                try await owner.reconcile { _ in Issue.record("invalid target advanced its checkpoint"); return true }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        }
        #expect(branchReads.withLock { $0 } == (scenario == "foreignRepository" ? 0 : 1))
        #expect(FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func partialArtifactsSurviveFailedAdoptionAndNoIntentReplay() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { _ in
            try await runOnBackground {
                try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
                try Data("partial".utf8).write(to: fixture.target.appendingPathComponent("keep"))
            }
            return true
        } == .reconciliationRequired)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await owner.reconcile { _ in true } }
        #expect(await owner.create { _ in Issue.record("retry"); return true } == .reconciliationRequired)
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("keep")) == Data("partial".utf8))
    }

    @Test func failedDurableIntentNeverDispatches() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { _ in false } == .reconciliationRequired)
        #expect(await owner.create { _ in Issue.record("retry"); return true } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func failedRecoveryOfMissingTargetCannotBecomeFreshCreation() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await owner.reconcile { _ in true } }
        #expect(await owner.create { _ in Issue.record("recovery retried creation"); return true } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func retiringAnOldLeaseCannotRevokeItsColdRestoredReplacement() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let original = try await fixture.reserve(in: bindings)
        await bindings.revoke(original)
        let restored = try await bindings.restore(original.snapshot)
        await bindings.revoke(original)
        #expect(await runOnBackground { restored.revalidateOrigin() })
        #expect(!restored.claimCreationAttempt())
    }

    @Test func successfulGitExitCannotSubstituteForExactAdoption() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let branch = AgentTaskEnvironmentBindings.branchName(taskID: lease.taskID, runID: lease.reservationRunID)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            // Simulate a successful command whose filesystem result is not
            // the reserved task's branch. Exit zero must not authorize it.
            GitCommand.spawn(executable, arguments: argv.map { $0 == branch ? "unrelated" : $0 }, directory: directory)
        })
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls)
        #expect(await owner.create { _ in true } == .reconciliationRequired)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await owner.reconcile { _ in true } }
        #expect(FileManager.default.fileExists(atPath: fixture.target.path))
        #expect(await owner.create { _ in Issue.record("failed adoption retried"); return true } == .reconciliationRequired)
    }

    @Test func cancellationWhileRecordingIntentNeverDispatchesOrRetries() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        let gate = ReservedSetupIntentGate()
        let submission = Task { await owner.create { _ in await gate.record() } }
        defer { submission.cancel() }
        #expect(await gate.waitForIntent())
        submission.cancel()
        gate.release()
        #expect(await submission.value == .reconciliationRequired)
        #expect(await owner.create { _ in Issue.record("cancelled creation retried"); return true } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test func coldReservationRestoresExistingPopulatedTargetWithoutAnyRepeatedEffects() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let durable = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        do {
            let bindings = AgentTaskEnvironmentBindings()
            let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
            #expect(await owner.create { value in durable.withLock { $0 = value }; return true } == .adopted)
        }
        let loaded = try #require(durable.withLock { $0 })
        let restoredBindings = AgentTaskEnvironmentBindings()
        let restored = try await restoredBindings.restore(loaded.reservation)
        #expect(!restored.claimCreationAttempt())
        let mutations = Mutex(0)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            if argv.contains("add") || argv.contains("-u") { mutations.withLock { $0 += 1 } }
            return GitCommand.spawn(executable, arguments: argv, directory: directory)
        })
        let recovered = AgentTaskReservedWorktreeSetup(lease: restored, bindings: restoredBindings, recovering: loaded, systemCalls: calls)
        let binding = try await recovered.reconcile { _ in Issue.record("completed checkpoint should not be republished"); return false }
        _ = try await restoredBindings.revalidate(binding)
        #expect(await recovered.create { _ in Issue.record("recreated"); return true } == .adopted)
        #expect(mutations.withLock { $0 } == 0)
    }

    @Test func uncertainPopulationIntentIsNeverReplayedEvenWhenNothingWasWritten() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let attempted = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { value in
            attempted.withLock { $0 = value }
            return value.phase != .populationIntent
        } == .reconciliationRequired)
        let loaded = try #require(attempted.withLock { $0 })
        #expect(loaded.phase == .populationIntent)
        let restoredBindings = AgentTaskEnvironmentBindings()
        let restored = try await restoredBindings.restore(loaded.reservation)
        let recovered = AgentTaskReservedWorktreeSetup(lease: restored, bindings: restoredBindings, recovering: loaded)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await recovered.reconcile { _ in Issue.record("uncertain population replayed"); return true }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        #expect(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent(".git").path))
    }

    @Test func lostOutcomeReceiptRecoversByInspectionNotAnotherPopulation() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let durable = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        do {
            let bindings = AgentTaskEnvironmentBindings()
            let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
            #expect(await owner.create { value in
                guard value.phase != .populated else { return false }
                durable.withLock { $0 = value }
                return true
            } == .reconciliationRequired)
        }
        let loaded = try #require(durable.withLock { $0 })
        #expect(loaded.phase == .populationIntent)
        let bindings = AgentTaskEnvironmentBindings()
        let restored = try await bindings.restore(loaded.reservation)
        let mutations = Mutex(0)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            if argv.contains("add") || argv.contains("-u") { mutations.withLock { $0 += 1 } }
            return GitCommand.spawn(executable, arguments: argv, directory: directory)
        })
        let recovered = AgentTaskReservedWorktreeSetup(lease: restored, bindings: bindings, recovering: loaded, systemCalls: calls)
        _ = try await recovered.reconcile { value in
            #expect(value.phase == .populated)
            durable.withLock { $0 = value }
            return true
        }
        #expect(mutations.withLock { $0 } == 0)
    }

    @Test func sameOwnerCannotTreatAnUnknownOutcomeReceiptAsDurable() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { $0.phase != .populated } == .reconciliationRequired)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await owner.reconcile { value in
                #expect(value.phase == .populated)
                return false
            }
        }
        _ = try await owner.reconcile { value in
            #expect(value.phase == .populated)
            return true
        }
    }

    @Test func sha256ObjectStorePreservesThePinnedTree() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture(sha256: true) }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { $0.baseCommit.count == 64 } == .adopted)
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("tracked".utf8))
    }

    @Test func emptyPinnedTreeStillGetsAUsableIndex() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        try await runOnBackground {
            try fixture.git(["read-tree", "--empty"])
            try fixture.git(["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid", "commit", "--allow-empty", "-m", "empty"])
        }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { _ in true } == .adopted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path) == [".git"])
    }

    @Test(arguments: ["gitlink", "blob", "total"])
    func refusedTreeMetadataNeverReportsAnIncompleteCheckoutAsAdopted(kind: String) async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await fixture.reserve(in: bindings)
        let object = String(repeating: "0", count: 40)
        // Inject bounded ls-tree records, without allocating oversized files.
        let records: [String]
        switch kind {
        case "gitlink": records = ["160000 commit \(object) -\tmodule"]
        case "blob": records = ["100644 blob \(object) \(64 * 1_024 * 1_024 + 1)\tlarge"]
        default: records = (0..<9).map { "100644 blob \(object) \(64 * 1_024 * 1_024)\tfile\($0)" }
        }
        let populationDispatches = Mutex(0)
        let calls = GitCommandSystemCalls(spawn: { executable, argv, directory in
            if argv.contains("ls-tree") {
                return GitCommand.spawn(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s\\0"] + records, directory: directory)
            }
            if argv.contains("-u") { populationDispatches.withLock { $0 += 1 } }
            return GitCommand.spawn(executable, arguments: argv, directory: directory)
        })
        let phases = Mutex<[AgentTaskReservedWorktreeCheckpoint.Phase]>([])
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings, systemCalls: calls)
        #expect(await owner.create { value in phases.withLock { $0.append(value.phase) }; return true } == .reconciliationRequired)
        #expect(phases.withLock { $0 } == [.creationIntent])
        #expect(populationDispatches.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        #expect(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent(".git").path))
    }

    @Test func populationCollisionPreservesUserArtifactsAndCannotBeRetried() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let durable = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        #expect(await owner.create { value in
            durable.withLock { $0 = value }
            if value.phase == .populationIntent {
                try await runOnBackground {
                    try Data("keep user contents".utf8).write(to: fixture.target.appendingPathComponent("tracked"))
                }
            }
            return true
        } == .reconciliationRequired)
        let loaded = try #require(durable.withLock { $0 })
        let restoredBindings = AgentTaskEnvironmentBindings()
        let restored = try await restoredBindings.restore(loaded.reservation)
        let recovered = AgentTaskReservedWorktreeSetup(lease: restored, bindings: restoredBindings, recovering: loaded)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await recovered.reconcile { _ in true } }
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("keep user contents".utf8))
    }

    @Test(arguments: ["locked", "index.lock"]) func initializingOrLockedTargetCannotBePopulatedOrAdopted(lock: String) async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
        let lockPath = Mutex<URL?>(nil)
        #expect(await owner.create { value in
            if value.phase == .populationIntent {
                try await runOnBackground {
                    let link = try String(contentsOf: fixture.target.appendingPathComponent(".git"), encoding: .utf8)
                    let directory = URL(fileURLWithPath: String(link.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines))
                    let path = directory.appendingPathComponent(lock)
                    try Data("preserve pending mutation".utf8).write(to: path, options: .withoutOverwriting)
                    lockPath.withLock { $0 = path }
                }
            }
            return true
        } == .reconciliationRequired)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await owner.reconcile { _ in true } }
        let path = try #require(lockPath.withLock { $0 })
        #expect(try Data(contentsOf: path) == Data("preserve pending mutation".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
    }

    @Test(arguments: [true, false]) func coldRestoreRefusesReplacedOriginalInstances(replaceParent: Bool) async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let snapshot = try await fixture.reserve(in: bindings).snapshot
        try await runOnBackground {
            let replaced = replaceParent ? fixture.target.deletingLastPathComponent() : fixture.project
            try FileManager.default.moveItem(at: replaced, to: fixture.root.appendingPathComponent("preserved"))
            try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
            if !replaceParent { try fixture.git(["init", "-b", "main"]) }
        }
        let restoredBindings = AgentTaskEnvironmentBindings()
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await restoredBindings.restore(snapshot) }
    }

    @Test func recoveryRehashesFilesRatherThanTrustingTheRealIndexStatCache() async throws {
        let fixture = try await runOnBackground { try ReservedSetupFixture() }
        defer { fixture.remove() }
        let durable = Mutex<AgentTaskReservedWorktreeCheckpoint?>(nil)
        do {
            let bindings = AgentTaskEnvironmentBindings()
            let owner = AgentTaskReservedWorktreeSetup(lease: try await fixture.reserve(in: bindings), bindings: bindings)
            #expect(await owner.create { value in durable.withLock { $0 = value }; return true } == .adopted)
        }
        try await runOnBackground {
            let tracked = fixture.target.appendingPathComponent("tracked")
            let date = try #require(FileManager.default.attributesOfItem(atPath: tracked.path)[.modificationDate] as? Date)
            try Data("changed".utf8).write(to: tracked)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tracked.path)
        }
        let loaded = try #require(durable.withLock { $0 })
        let bindings = AgentTaskEnvironmentBindings()
        let restored = try await bindings.restore(loaded.reservation)
        let recovered = AgentTaskReservedWorktreeSetup(lease: restored, bindings: bindings, recovering: loaded)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) { try await recovered.reconcile { _ in true } }
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("changed".utf8))
    }
}

@MainActor private final class ReservedSetupIntentGate {
    private var entered = false
    private var released = false

    func record() async -> Bool {
        entered = true
        return await waitUntilMainActor({ released }, ceiling: .seconds(45))
    }
    func waitForIntent() async -> Bool {
        await waitUntilMainActor({ entered }, ceiling: .seconds(45))
    }
    func release() { released = true }
}

nonisolated private struct ReservedSetupFixture: Sendable {
    let root: URL
    let project: URL
    let target: URL
    let marker: URL

    init(sha256: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PineReservedSetup-\(UUID())").resolvingSymlinksInPath()
        project = root.appendingPathComponent("project")
        target = root.appendingPathComponent("tasks/exact target ; not shell")
        marker = root.appendingPathComponent("script-executed")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
        try git(["init", "-b", "main"] + (sha256 ? ["--object-format=sha256"] : []))
        try Data("tracked".utf8).write(to: project.appendingPathComponent("tracked"))
        let executable = project.appendingPathComponent("executable")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("link").path, withDestinationPath: "tracked")
        try Data("* filter=pine-hostile text eol=crlf\n".utf8).write(to: project.appendingPathComponent(".gitattributes"))
        try git(["add", "--", "tracked", "executable", "link", ".gitattributes"])
        try git(["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid", "commit", "-m", "fixture"])
    }

    func reserve(in bindings: AgentTaskEnvironmentBindings) async throws -> AgentTaskEnvironmentSetupLease {
        try await bindings.reserve(taskID: UUID(), runID: UUID(), canonicalProject: project, expectedWorktree: target)
    }

    func git(_ argv: [String], at directory: URL? = nil) throws {
        _ = try output(argv, at: directory)
    }
    func output(_ argv: [String], at directory: URL? = nil) throws -> String {
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: AgentTaskReservedWorktreeSetup.arguments(argv), at: directory ?? project
        )
        guard result.succeeded, result.outputIsValidUTF8 else { throw ReservedSetupFixtureError.gitFailed }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum ReservedSetupFixtureError: Error { case gitFailed }
