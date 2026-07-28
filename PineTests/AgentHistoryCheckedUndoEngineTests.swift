//
//  AgentHistoryCheckedUndoEngineTests.swift
//  PineTests
//
//  Durable checked-undo tests for verified Agent History entries (#1183).
//  Every test uses a real temporary git repository and a temporary private
//  store, so nothing touches the user's Application Support.
//

import Darwin
import Foundation
import Testing

@testable import Pine

// Each case launches real Git subprocesses and owns temporary descriptor
// namespaces. Keep cases isolated; dedicated tests below create the intended
// replay and cross-store concurrency explicitly.
@Suite("Agent History Checked Undo Engine", .serialized)
@MainActor
struct AgentHistoryCheckedUndoEngineTests {

    // MARK: - Modify: success preserves pre-existing unrelated edits

    @Test("A verified modify restores the recorded before-state, preserving a pre-existing human edit")
    func verifiedModifyRestoresBeforeState() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // HEAD baseline.
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        // Pre-existing human edit (uncommitted) that undo MUST preserve.
        let beforeContent = "base\nhuman edit\n"
        try env.write(file: "App.swift", contents: beforeContent)

        // Agent appends a line.
        let afterContent = "base\nhuman edit\nagent change\n"
        try env.write(file: "App.swift", contents: afterContent)

        let entry = try await env.captureModify(path: "App.swift", before: beforeContent, after: afterContent)

        let result = await env.store.revert(entry: entry)

        #expect(result.allSucceeded)
        #expect(result.blockedReason == nil)
        let restored = try env.read(file: "App.swift")
        // The agent's line is gone; the human edit survives byte-for-byte.
        #expect(restored == beforeContent)
        #expect(!restored.contains("agent change"))
        #expect(env.store.entries.first?.reverted == true)
        let workspaceRecoveryFiles = try FileManager.default
            .contentsOfDirectory(
                at: env.repo,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasPrefix(".pine-undo-") }
        #expect(workspaceRecoveryFiles.isEmpty)
        let retainedPath = try #require(
            result.recoveryQuarantinePaths.first
        )
        #expect(
            URL(fileURLWithPath: retainedPath)
                .resolvingSymlinksInPath()
                .path
                .hasPrefix(
                    env.privateBase
                        .appendingPathComponent("recovery", isDirectory: true)
                        .resolvingSymlinksInPath()
                        .path + "/"
                )
        )
        #expect(try String(
            contentsOfFile: retainedPath,
            encoding: .utf8
        ) == afterContent)
    }

    @Test("A verified modify touches only recorded hunks: a sibling file is untouched")
    func verifiedModifyLeavesSiblingUntouched() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "a.swift", contents: "a1\n")
        try env.write(file: "b.swift", contents: "b1\n")
        try env.git(["add", "."])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "a.swift", contents: "a1\nagent\n")
        try env.write(file: "b.swift", contents: "b1\nunrelated human\n")

        let entry = try await env.captureModify(path: "a.swift", before: "a1\n", after: "a1\nagent\n")

        let result = await env.store.revert(entry: entry)

        #expect(result.allSucceeded)
        #expect(try env.read(file: "a.swift") == "a1\n")
        // b.swift is not part of the change set → byte-for-byte intact.
        #expect(try env.read(file: "b.swift") == "b1\nunrelated human\n")
    }

    // MARK: - Divergence refusal

    @Test("A human edit after the agent blocks undo and preserves the human edit")
    func postAgentEditBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        let beforeContent = "base\n"
        let afterContent = "base\nagent\n"
        try env.write(file: "App.swift", contents: afterContent)

        let entry = try await env.captureModify(path: "App.swift", before: beforeContent, after: afterContent)

        // Human edits the same file after the agent wrote.
        let divergedContent = "base\nagent\nmore human\n"
        try env.write(file: "App.swift", contents: divergedContent)

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .currentContentDiverged)
        // Nothing mutated; diverged content survives.
        #expect(try env.read(file: "App.swift") == divergedContent)
        #expect(env.store.entries.first?.reverted == false)
    }

    @Test("A second agent editing the same file blocks the first agent's undo")
    func twoAgentEditBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent1\n")
        let entry1 = try await env.captureModify(
            path: "App.swift", before: "base\n", after: "base\nagent1\n"
        )

        // Second agent overwrites the file.
        try env.write(file: "App.swift", contents: "base\nagent2\n")

        let result = await env.store.revert(entry: entry1)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .currentContentDiverged)
        #expect(try env.read(file: "App.swift") == "base\nagent2\n")
    }

    // MARK: - Create / delete

    @Test("A verified create is undone by removing the created file")
    func verifiedCreateIsUndoneByRemoval() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "keep.swift", contents: "k\n")
        try env.git(["add", "keep.swift"])
        try env.git(["commit", "-m", "initial"])

        // Agent creates a new file.
        let createdContent = "new file by agent\n"
        try env.write(file: "generated.swift", contents: createdContent)

        let entry = try await env.captureCreate(path: "generated.swift", after: createdContent)

        let result = await env.store.revert(entry: entry)

        #expect(result.allSucceeded)
        #expect(result.blockedReason == nil)
        #expect(!FileManager.default.fileExists(atPath: env.url("generated.swift").path))
    }

    @Test("A verified delete is undone by recreating the deleted file")
    func verifiedDeleteIsUndoneByRecreate() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let original = "important content\n"
        try env.write(file: "victim.swift", contents: original)
        try env.git(["add", "victim.swift"])
        try env.git(["commit", "-m", "initial"])

        // Agent deletes the file.
        try FileManager.default.removeItem(at: env.url("victim.swift"))

        let entry = try await env.captureDelete(path: "victim.swift", before: original)

        let result = await env.store.revert(entry: entry)

        #expect(result.allSucceeded)
        #expect(result.blockedReason == nil)
        #expect(try env.read(file: "victim.swift") == original)
    }

    @Test("A recreated-then-edited deleted file blocks undo (divergence)")
    func divergedDeleteBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "victim.swift", contents: "original\n")
        try env.git(["add", "victim.swift"])
        try env.git(["commit", "-m", "initial"])

        try FileManager.default.removeItem(at: env.url("victim.swift"))
        let entry = try await env.captureDelete(path: "victim.swift", before: "original\n")

        // Someone recreates the file → after-state (absent) no longer holds.
        try env.write(file: "victim.swift", contents: "recreated by someone\n")

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .currentContentDiverged)
        #expect(try env.read(file: "victim.swift") == "recreated by someone\n")
    }

    // MARK: - Staged changes / moved HEAD

    @Test("A staged change after capture blocks undo")
    func stagedChangeBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.write(file: "other.swift", contents: "o1\n")
        try env.git(["add", "."])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        // Stage an unrelated change → index diverges from capture.
        try env.write(file: "other.swift", contents: "o1\nstaged\n")
        try env.git(["add", "other.swift"])

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .workspaceChanged)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
    }

    @Test("A new commit after capture blocks undo")
    func movedHeadBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        // A new commit moves HEAD.
        try env.git(["commit", "-am", "new commit"])

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .workspaceChanged)
    }

    @Test("A linked worktree uses its own index and supports checked undo")
    func linkedWorktreeUsesWorktreeIndex() async throws {
        let primary = try makeEnv()
        defer { primary.cleanup() }

        try primary.write(file: "App.swift", contents: "base\n")
        try primary.git(["add", "App.swift"])
        try primary.git(["commit", "-m", "initial"])

        let linkedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-checked-linked-\(UUID().uuidString)",
                isDirectory: true
            )
        let branch = "checked-undo-\(UUID().uuidString)"
        try primary.git(["worktree", "add", "-b", branch, linkedRoot.path])

        let requestedPrivateBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-checked-linked-private-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: requestedPrivateBase,
            withIntermediateDirectories: true
        )
        let privateBase = physicalTemporaryURL(requestedPrivateBase)
        let privateStore = AgentHistoryPrivateStore(baseDirectory: privateBase)
        let linked = Env(
            repo: linkedRoot,
            privateBase: privateBase,
            privateStore: privateStore,
            store: AgentHistoryStore(
                projectRoot: linkedRoot,
                privateStore: privateStore
            ),
            sessionID: UUID()
        )
        defer { linked.cleanup() }

        #expect(AgentHistoryContentHash.indexSHA256(in: linkedRoot).count == 64)
        try linked.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await linked.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        let result = await linked.store.revert(entry: entry)

        #expect(result.allSucceeded)
        #expect(try linked.read(file: "App.swift") == "base\n")
    }

    // MARK: - Replay / tamper / authority guards

    @Test("A consumed authority cannot authorize a second undo")
    func replayIsBlocked() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        let first = await env.store.revert(entry: entry)
        #expect(first.allSucceeded)

        // Re-capture an identical change to get a fresh after-state, then try
        // to revert the already-consumed entry again.
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let second = await env.store.revert(entry: entry)

        #expect(!second.allSucceeded)
        // Already reverted OR consumed → blocked.
        #expect(
            second.blockedReason == .authorityConsumed
                || env.store.entries.first?.reverted == true
        )
    }

    @Test("Concurrent replay attempts consume one authority exactly once")
    func concurrentReplayConsumesExactlyOnce() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        async let first = env.store.revert(entry: entry)
        async let second = env.store.revert(entry: entry)
        let results = await [first, second]

        #expect(results.filter(\.allSucceeded).count == 1)
        #expect(try env.read(file: "App.swift") == "base\n")
        #expect(env.privateStore.loadAuthority(
            recordID: entry.verifiedChangeSet?.authority.recordID ?? UUID()
        )?.consumed == true)
    }

    @Test("Two store instances keep one authority lock if a legacy lock directory is replaced")
    func authorityLockDoesNotSplitAcrossStoreInstances() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let legacyLocks = env.privateBase.appendingPathComponent(
            "locks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyLocks,
            withIntermediateDirectories: false
        )
        let firstStore = AgentHistoryPrivateStore(
            baseDirectory: env.privateBase
        )
        let secondStore = AgentHistoryPrivateStore(
            baseDirectory: env.privateBase
        )
        let recordID = UUID()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            _ = firstFinished.wait(timeout: .now() + 2)
            _ = secondFinished.wait(timeout: .now() + 2)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { firstFinished.signal() }
            _ = try? firstStore.withAuthorityLock(recordID: recordID) {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        #expect(firstEntered.wait(timeout: .now() + 2) == .success)

        let movedLocks = env.privateBase.appendingPathComponent(
            "locks-old",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: legacyLocks, to: movedLocks)
        try FileManager.default.createDirectory(
            at: legacyLocks,
            withIntermediateDirectories: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            defer { secondFinished.signal() }
            _ = try? secondStore.withAuthorityLock(recordID: recordID) {
                secondEntered.signal()
            }
        }

        #expect(
            secondEntered.wait(timeout: .now() + 0.25) == .timedOut,
            "Replacing a child lock directory must not split the authority lock"
        )
        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 2) == .success)
    }

    @Test("A tampered project-log projection is refused")
    func tamperedProjectionIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        // Tamper: alter the recorded after-content hash in memory so the
        // projection no longer matches the authority digest.
        guard var changeSet = entry.verifiedChangeSet else {
            Issue.record("change set missing")
            return
        }
        let tamperedChange = AgentHistoryRecordedFileChange(
            relativePath: changeSet.changes[0].relativePath,
            operation: changeSet.changes[0].operation,
            before: changeSet.changes[0].before,
            after: AgentHistoryRecordedFileState(
                kind: .regularFile,
                contentSHA256: String(repeating: "f", count: 64),
                byteCount: 999,
                permissions: 0o600
            )
        )
        changeSet = VerifiedAgentChangeSet(
            id: changeSet.id,
            historyEntryID: changeSet.historyEntryID,
            schemaVersion: changeSet.schemaVersion,
            capturedAt: changeSet.capturedAt,
            provenance: changeSet.provenance,
            workspace: changeSet.workspace,
            changes: [tamperedChange],
            authority: changeSet.authority,
            inversePayload: changeSet.inversePayload
        )
        let tamperedEntry = AgentHistoryEntry(
            id: entry.id,
            sessionID: entry.sessionID,
            agentTypeRaw: entry.agentTypeRaw,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            affectedFiles: entry.affectedFiles,
            attribution: entry.attribution,
            verifiedChangeSet: changeSet,
            summary: entry.summary,
            reverted: entry.reverted
        )
        // Replace the in-store entry with the tampered projection.
        env.store.replaceEntryForTesting(tamperedEntry)

        let result = await env.store.revert(entry: tamperedEntry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .invalidVerifiedReversibleChangeSet)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
    }

    @Test("A verified entry with no authority record reports the engine as unavailable")
    func missingAuthorityBlocksUndo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        // Remove the authority → engine data is gone.
        env.privateStore.removeAuthority(
            recordID: entry.verifiedChangeSet?.authority.recordID ?? UUID()
        )
        await env.store.refreshCheckedUndoAvailability()

        let availability = env.store.effectiveUndoAvailability(for: entry)
        #expect(availability == .unavailable(.authorityRecordMissing))

        let result = await env.store.revert(entry: entry)
        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .authorityRecordMissing)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
    }

    // MARK: - Atomic rollback

    @Test("A partial apply failure rolls back every prior change")
    func partialFailureRollsBack() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "a.swift", contents: "a1\n")
        try env.write(file: "b.swift", contents: "b1\n")
        try env.git(["add", "."])
        try env.git(["commit", "-m", "initial"])

        // Agent modifies both files.
        try env.write(file: "a.swift", contents: "a1\nagent\n")
        try env.write(file: "b.swift", contents: "b1\nagent\n")

        let entry = try await env.captureMultiModify(
            pathsAndBefore: ["a.swift": "a1\n", "b.swift": "b1\n"],
            after: ["a.swift": "a1\nagent\n", "b.swift": "b1\nagent\n"]
        )
        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let secondFile = env.url("b.swift")
        let privateStore = env.privateStore
        let root = env.repo

        // `a.swift` is fully inverse-installed first. Immediately before the
        // second mutation, simulate a concurrent human replacement of b.swift.
        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(beforeMutation: { path in
                        guard path == "b.swift" else { return }
                        try? Data("b1\nhuman replacement\n".utf8).write(
                            to: secondFile,
                            options: [.atomic]
                        )
                    })
                )
            }
        }

        #expect(result?.allSucceeded == false)
        // The completed first mutation was rolled back to its exact after-state.
        #expect(try env.read(file: "a.swift") == "a1\nagent\n")
        // The concurrently replaced second file was never overwritten.
        #expect(try env.read(file: "b.swift") == "b1\nhuman replacement\n")
        #expect(env.store.entries.first?.reverted == false)
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    // MARK: - Filesystem confinement and recoverability

    @Test("A symlink ancestor is refused without touching its target")
    func symlinkAncestorIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let nested = env.url("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try env.write(file: "Sources/App.swift", contents: "base\n")
        try env.git(["add", "."])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "Sources/App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "Sources/App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        let realDirectory = env.url("Sources-real")
        try FileManager.default.moveItem(at: nested, to: realDirectory)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pine-undo-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideFile = outside.appendingPathComponent("App.swift")
        try Data("base\nagent\n".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "base\nagent\n")
        #expect(try String(
            contentsOf: realDirectory.appendingPathComponent("App.swift"),
            encoding: .utf8
        ) == "base\nagent\n")
    }

    @Test("A hard-linked after-state is refused")
    func hardLinkIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        try FileManager.default.linkItem(
            at: env.url("App.swift"),
            to: env.url("alias.swift")
        )

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
        #expect(try env.read(file: "alias.swift") == "base\nagent\n")
    }

    @Test("A consumption failure rolls back and preserves an owner-only recovery backup")
    func consumptionFailureIsRecoverable() async throws {
        let probe = ThreadProbe()
        let env = try makeEnv(beforeConsume: {
            probe.recordMainThread(pthread_main_np() != 0)
            throw InjectedFailure.consume
        })
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
        #expect(env.store.entries.first?.reverted == false)
        #expect(probe.values == [false])

        let recoveryRoot = env.privateBase.appendingPathComponent("recovery")
        let backups = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )
        let backup = try #require(backups.first)
        #expect(
            result.recoveryBackupPath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            } == backup.resolvingSymlinksInPath().path
        )
        #expect(FileManager.default.fileExists(
            atPath: backup.appendingPathComponent("manifest.json").path
        ))
        #expect(try String(
            contentsOf: backup.appendingPathComponent("0.bin"),
            encoding: .utf8
        ) == "base\nagent\n")
        #expect(posixPermissions(of: backup) == 0o700)
        #expect(posixPermissions(of: backup.appendingPathComponent("0.bin")) == 0o600)
    }

    @Test("Rollback refuses a quarantine changed through an old file descriptor")
    func changedQuarantineIsNotRestoredAsOriginal() async throws {
        let mutator = OpenFileMutator()
        let env = try makeEnv(beforeConsume: {
            try mutator.overwriteAndFail()
        })
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        try mutator.openFile(at: env.url("App.swift"))

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.recoveryBackupPath != nil)
        // The tampered quarantine is never misreported/restored as the original
        // after-state. The inverse remains visible and the durable backup is
        // surfaced for recovery instead.
        #expect(try env.read(file: "App.swift") == "base\n")
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: env.repo,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".pine-undo-") }
        #expect(quarantines.contains {
            (try? String(contentsOf: $0, encoding: .utf8))
                == "human through old descriptor\n"
        })
        #expect(env.privateStore.loadAuthority(
            recordID: entry.verifiedChangeSet?.authority.recordID ?? UUID()
        )?.consumed == false)
    }

    @Test("Rollback retains a late write to the installed inverse inode")
    func rollbackRetainsLateInstalledInverseWrite() async throws {
        let mutator = OpenFileMutator()
        let target = LockedFileURL()
        let env = try makeEnv(beforeConsume: {
            try mutator.openFile(at: target.requiredURL())
            throw InjectedFailure.consume
        })
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        target.set(env.url("App.swift"))

        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let privateStore = env.privateStore
        let root = env.repo

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(
                        afterRollbackInstalledValidation: { path in
                            guard path == "App.swift" else { return }
                            try? mutator.overwrite()
                        }
                    )
                )
            }
        }

        let checked = try #require(result)
        #expect(!checked.allSucceeded)
        #expect(try env.read(file: "App.swift") == "base\nagent\n")
        let retainedPath = try #require(
            checked.recoveryQuarantinePaths.first
        )
        #expect(try String(
            contentsOfFile: retainedPath,
            encoding: .utf8
        ) == "human through old descriptor\n")
        let backupPath = try #require(checked.recoveryBackupPath)
        let metadata = try String(
            contentsOf: URL(fileURLWithPath: backupPath)
                .appendingPathComponent("retained-quarantines.json"),
            encoding: .utf8
        )
        #expect(metadata.contains(
            URL(fileURLWithPath: retainedPath).lastPathComponent
        ))
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    @Test("Cleanup changed through an old descriptor is reported and retained")
    func changedQuarantineDuringCleanupIsRecoverable() async throws {
        let mutator = OpenFileMutator()
        let env = try makeEnv(beforeConsume: {
            try mutator.overwrite()
        })
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        try mutator.openFile(at: env.url("App.swift"))

        let result = await env.store.revert(entry: entry)

        #expect(!result.allSucceeded)
        let backupPath = try #require(result.recoveryBackupPath)
        #expect(try env.read(file: "App.swift") == "base\n")
        let metadataURL = URL(fileURLWithPath: backupPath)
            .appendingPathComponent("retained-quarantines.json")
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        let retainedPath = try #require(
            result.recoveryQuarantinePaths.first
        )
        #expect(metadata.contains(
            URL(fileURLWithPath: retainedPath).lastPathComponent
        ))
        #expect(
            URL(fileURLWithPath: retainedPath)
                .resolvingSymlinksInPath()
                .path
                .hasPrefix(
                    env.privateBase
                        .appendingPathComponent("recovery", isDirectory: true)
                        .resolvingSymlinksInPath()
                        .path + "/"
                )
        )
        #expect(try String(
            contentsOfFile: retainedPath,
            encoding: .utf8
        ) == "human through old descriptor\n")
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: env.repo,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".pine-undo-") }
        #expect(quarantines.isEmpty)
        #expect(env.privateStore.loadAuthority(
            recordID: entry.verifiedChangeSet?.authority.recordID ?? UUID()
        )?.consumed == true)
    }

    @Test("A write after quarantine validation reports a retained conflict")
    func oldDescriptorWriteAfterValidationIsRetained() async throws {
        let mutator = OpenFileMutator()
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        try mutator.openFile(at: env.url("App.swift"))
        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let privateStore = env.privateStore
        let root = env.repo

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(
                        afterQuarantineValidation: { path in
                            guard path == "App.swift" else { return }
                            try? mutator.overwrite()
                        }
                    )
                )
            }
        }

        let checked = try #require(result)
        #expect(!checked.allSucceeded)
        #expect(try env.read(file: "App.swift") == "base\n")
        let retainedPath = try #require(
            checked.recoveryQuarantinePaths.first
        )
        #expect(try String(
            contentsOfFile: retainedPath,
            encoding: .utf8
        ) == "human through old descriptor\n")
        let backupPath = try #require(checked.recoveryBackupPath)
        let metadata = try String(
            contentsOf: URL(fileURLWithPath: backupPath)
                .appendingPathComponent("retained-quarantines.json"),
            encoding: .utf8
        )
        #expect(metadata.contains(
            URL(fileURLWithPath: retainedPath).lastPathComponent
        ))
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == true)
    }

    @Test("Finalization detects a late write to the installed inverse")
    func finalizationDetectsLateInstalledInverseWrite() async throws {
        let mutator = OpenFileMutator()
        let target = LockedFileURL()
        let env = try makeEnv(beforeConsume: {
            try mutator.openFile(at: target.requiredURL())
        })
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        target.set(env.url("App.swift"))

        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let privateStore = env.privateStore
        let root = env.repo

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(
                        afterQuarantineValidation: { path in
                            guard path == "App.swift" else { return }
                            try? mutator.overwrite()
                        }
                    )
                )
            }
        }

        let checked = try #require(result)
        #expect(!checked.allSucceeded)
        #expect(try env.read(file: "App.swift")
            == "human through old descriptor\n")
        #expect(checked.recoveryBackupPath != nil)
        #expect(checked.recoveryQuarantinePaths.contains { path in
            (try? String(contentsOfFile: path, encoding: .utf8))
                == "base\nagent\n"
        })
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == true)
    }

    @Test("A swap immediately before mutation is refused and preserved")
    func lastMomentSwapIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let fileURL = env.url("App.swift")
        let privateStore = env.privateStore
        let root = env.repo

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(beforeMutation: { _ in
                        try? Data("human replacement\n".utf8).write(
                            to: fileURL,
                            options: [.atomic]
                        )
                    })
                )
            }
        }

        #expect(result?.allSucceeded == false)
        #expect(try env.read(file: "App.swift") == "human replacement\n")
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    @Test("A failed quarantine restore surfaces late descriptor bytes")
    func failedQuarantineRestoreSurfacesLateBytes() async throws {
        let mutator = OpenFileMutator()
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        try mutator.openFile(at: env.url("App.swift"))

        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let privateStore = env.privateStore
        let root = env.repo
        let appURL = env.url("App.swift")

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(
                        afterWorkspaceQuarantineRename: { path in
                            guard path == "App.swift" else { return }
                            try? mutator.overwrite()
                            try? Data("human replacement\n".utf8).write(
                                to: appURL,
                                options: [.atomic]
                            )
                        }
                    )
                )
            }
        }

        let checked = try #require(result)
        #expect(!checked.allSucceeded)
        #expect(try env.read(file: "App.swift") == "human replacement\n")
        let retainedPath = try #require(
            checked.recoveryQuarantinePaths.first
        )
        #expect(try String(
            contentsOfFile: retainedPath,
            encoding: .utf8
        ) == "human through old descriptor\n")
        let backupPath = try #require(checked.recoveryBackupPath)
        let metadata = try String(
            contentsOf: URL(fileURLWithPath: backupPath)
                .appendingPathComponent("retained-quarantines.json"),
            encoding: .utf8
        )
        #expect(metadata.contains(
            URL(fileURLWithPath: retainedPath).lastPathComponent
        ))
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    @Test("Renaming and replacing the workspace root before mutation is refused")
    func replacedWorkspaceRootIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        let changeSet = try #require(entry.verifiedChangeSet)
        let manifest = try #require(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        ))
        let payload = try #require(env.privateStore.loadPayload(
            blobID: changeSet.inversePayload.blobID,
            expectedSHA256: changeSet.inversePayload.sha256,
            expectedByteCount: changeSet.inversePayload.byteCount,
            expectedFormatVersion: changeSet.inversePayload.formatVersion
        ))
        let backup = try env.privateStore.createRecoveryBackup(
            recordID: changeSet.authority.recordID
        )
        let movedRoot = env.repo.deletingLastPathComponent()
            .appendingPathComponent(
                "pine-checked-moved-\(UUID().uuidString)",
                isDirectory: true
            )
        let replacementRoot = env.repo.deletingLastPathComponent()
            .appendingPathComponent(
                "pine-checked-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: movedRoot) }
        try FileManager.default.copyItem(at: env.repo, to: replacementRoot)
        let root = env.repo
        let privateStore = env.privateStore

        let result = await runOnBackground {
            try? privateStore.withAuthorityLock(recordID: manifest.recordID) {
                AgentHistoryCheckedUndoEngine.apply(
                    changeSet: changeSet,
                    payload: payload,
                    context: AgentHistoryCheckedUndoContext(
                        root: root,
                        backup: backup,
                        manifest: manifest,
                        privateStore: privateStore
                    ),
                    hooks: AgentHistoryCheckedUndoHooks(beforeMutation: { _ in
                        try? FileManager.default.moveItem(
                            at: root,
                            to: movedRoot
                        )
                        try? FileManager.default.moveItem(
                            at: replacementRoot,
                            to: root
                        )
                    })
                )
            }
        }

        #expect(result?.allSucceeded == false)
        #expect(try String(
            contentsOf: root.appendingPathComponent("App.swift"),
            encoding: .utf8
        ) == "base\nagent\n")
        #expect(try String(
            contentsOf: movedRoot.appendingPathComponent("App.swift"),
            encoding: .utf8
        ) == "base\nagent\n")
        #expect(privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    @Test("Private authority and payload artifacts are owner-only")
    func privateArtifactsAreOwnerOnly() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        _ = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        for directoryName in ["authorities", "payloads"] {
            let directory = env.privateBase.appendingPathComponent(directoryName)
            #expect(posixPermissions(of: directory) == 0o700)
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            #expect(files.count == 1)
            #expect(posixPermissions(of: try #require(files.first)) == 0o600)
        }
    }

    @Test("A symlinked private authority directory is refused without escaping storage")
    func symlinkedPrivateDirectoryIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-checked-private-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: env.privateBase.appendingPathComponent("authorities"),
            withDestinationURL: outside
        )

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")

        do {
            _ = try await env.captureModify(
                path: "App.swift",
                before: "base\n",
                after: "base\nagent\n"
            )
            Issue.record("Capture unexpectedly trusted a symlinked private directory")
        } catch {
            #expect(env.store.entries.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: outside,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test("An intermediate private-store symlink cannot redirect artifacts into a workspace")
    func intermediatePrivateStoreSymlinkIsRefused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-private-parent-\(UUID().uuidString)",
                isDirectory: true
            )
        let physicalParent = physicalTemporaryURL(parent)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-private-redirect-\(UUID().uuidString)",
                isDirectory: true
            )
        let physicalOutside = physicalTemporaryURL(outside)
        try FileManager.default.createDirectory(
            at: physicalParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: physicalOutside,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: physicalParent)
            try? FileManager.default.removeItem(at: physicalOutside)
        }
        let redirect = physicalParent.appendingPathComponent(
            "redirect",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: redirect,
            withDestinationURL: physicalOutside
        )
        let redirectedBase = redirect.appendingPathComponent(
            "AgentHistory",
            isDirectory: true
        )
        let privateStore = AgentHistoryPrivateStore(
            baseDirectory: redirectedBase
        )
        let redirected = Env(
            repo: env.repo,
            privateBase: redirectedBase,
            privateStore: privateStore,
            store: AgentHistoryStore(
                projectRoot: env.repo,
                privateStore: privateStore
            ),
            sessionID: UUID()
        )

        do {
            _ = try await redirected.captureModify(
                path: "App.swift",
                before: "base\n",
                after: "base\nagent\n"
            )
            Issue.record("Capture unexpectedly followed an intermediate symlink")
        } catch {
            #expect(redirected.store.entries.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: physicalOutside,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    // MARK: - Effective availability

    @Test("Review preparation, immediate revalidation, and apply complete successfully")
    func reviewedUndoCompletes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        let preview = await env.store.prepareVerifiedUndoPreview(
            for: entry
        )
        guard case .available(let model) = preview else {
            Issue.record("Verified review preview was unavailable")
            return
        }
        #expect(model.operations.count == 1)
        #expect(
            model.operations[0].contentRepresentation == .textual
        )

        let validation = await env.store.revalidateVerifiedUndoPreview(
            for: entry,
            expectedPreview: model
        )
        guard case .available = validation else {
            Issue.record("Verified review became stale without a mutation")
            return
        }
        let result = await env.store.revert(entry: entry)
        #expect(result.allSucceeded)
        #expect(result.checkedConflict == nil)
        #expect(try env.read(file: "App.swift") == "base\n")
    }

    @Test("Closing a prepared review performs no mutation or authority consumption")
    func preparedReviewCancellationIsReadOnly() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )
        let changeSet = try #require(entry.verifiedChangeSet)

        let preview = await env.store.prepareVerifiedUndoPreview(
            for: entry
        )
        guard case .available = preview else {
            Issue.record("Verified review preview was unavailable")
            return
        }

        #expect(try env.read(file: "App.swift") == "base\nagent\n")
        #expect(env.store.entries.first?.reverted == false)
        #expect(env.privateStore.loadAuthority(
            recordID: changeSet.authority.recordID
        )?.consumed == false)
    }

    @Test("Revalidation rejects content and same-content inode drift")
    func reviewedUndoRejectsPreviewDrift() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(
            path: "App.swift",
            before: "base\n",
            after: "base\nagent\n"
        )

        let firstPreview = await env.store.prepareVerifiedUndoPreview(
            for: entry
        )
        guard case .available(let firstModel) = firstPreview else {
            Issue.record("Verified review preview was unavailable")
            return
        }
        try FileManager.default.removeItem(at: env.url("App.swift"))
        try env.write(file: "App.swift", contents: "base\nagent\n")
        let identityDrift =
            await env.store.revalidateVerifiedUndoPreview(
                for: entry,
                expectedPreview: firstModel
            )
        #expect(
            identityDrift
                == .unavailable(
                    .currentContentDiverged(path: "App.swift")
                )
        )

        let secondPreview = await env.store.prepareVerifiedUndoPreview(
            for: entry
        )
        guard case .available(let secondModel) = secondPreview else {
            Issue.record("Replacement preview was unavailable")
            return
        }
        try env.write(
            file: "App.swift",
            contents: "base\nagent\nhuman\n"
        )
        let contentDrift =
            await env.store.revalidateVerifiedUndoPreview(
                for: entry,
                expectedPreview: secondModel
            )
        #expect(
            contentDrift
                == .unavailable(
                    .currentContentDiverged(path: "App.swift")
                )
        )
        #expect(try env.read(file: "App.swift") == "base\nagent\nhuman\n")
    }

    @Test("effectiveUndoAvailability reports available for a captured, unconsumed entry")
    func effectiveAvailabilityAvailable() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try env.write(file: "App.swift", contents: "base\n")
        try env.git(["add", "App.swift"])
        try env.git(["commit", "-m", "initial"])

        try env.write(file: "App.swift", contents: "base\nagent\n")
        let entry = try await env.captureModify(path: "App.swift", before: "base\n", after: "base\nagent\n")

        #expect(env.store.effectiveUndoAvailability(for: entry) == .available)
    }

    @Test("effectiveUndoAvailability reports unavailable for a heuristic entry")
    func effectiveAvailabilityHeuristic() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        env.store.append(
            AgentHistoryEntry(
                sessionID: UUID(),
                agentTypeRaw: "codex",
                startedAt: Date(),
                affectedFiles: ["App.swift"],
                summary: "1 file"
            )
        )
        let entry = try #require(env.store.entries.first)
        #expect(
            env.store.effectiveUndoAvailability(for: entry)
                == .unavailable(.heuristicAttribution)
        )
    }

    // MARK: - Test environment

    private struct Env {
        let repo: URL
        let privateBase: URL
        let privateStore: AgentHistoryPrivateStore
        let store: AgentHistoryStore
        let sessionID: UUID

        func cleanup() {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: privateBase)
        }

        func url(_ file: String) -> URL {
            repo.appendingPathComponent(file, isDirectory: false)
        }

        func write(file: String, contents: String) throws {
            try contents.write(to: url(file), atomically: true, encoding: .utf8)
        }

        func read(file: String) throws -> String {
            try String(contentsOf: url(file), encoding: .utf8)
        }

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: out, encoding: .utf8) ?? ""
                Issue.record("git \(args.joined(separator: " ")) failed: \(detail)")
            }
        }

        private func workspace() throws -> AgentHistoryWorkspaceIdentity {
            AgentHistoryWorkspaceIdentity(
                privateWorkspaceID: UUID(),
                headOID: AgentHistoryContentHash.headOID(in: repo),
                indexSHA256: AgentHistoryContentHash.indexSHA256(in: repo)
            )
        }

        private func provenance() -> AgentHistoryWriterProvenance {
            AgentHistoryWriterProvenance(
                sessionID: sessionID,
                writerInstanceID: UUID(),
                processIdentifier: 1234,
                processGeneration: 1,
                firstEventSequence: 100,
                lastEventSequence: 200
            )
        }

        func captureModify(
            path: String,
            before: String,
            after: String
        ) async throws -> AgentHistoryEntry {
            try await captureMultiModify(
                pathsAndBefore: [path: before],
                after: [path: after]
            )
        }

        func captureMultiModify(
            pathsAndBefore: [String: String],
            after: [String: String]
        ) async throws -> AgentHistoryEntry {
            let changes = pathsAndBefore.keys.sorted().map { path -> AgentHistoryRecordedFileChange in
                let beforeString = pathsAndBefore[path]
                let afterString = after[path]
                return AgentHistoryRecordedFileChange(
                    relativePath: path,
                    operation: .modify,
                    before: stateFor(contents: beforeString ?? ""),
                    after: stateFor(contents: afterString ?? "")
                )
            }
            return try await store.recordVerifiedChangeSet(
                agentType: .codex,
                changes: changes,
                beforeContents: pathsAndBefore.mapValues { Data($0.utf8) },
                provenance: provenance(),
                workspace: try workspace()
            )
        }

        func captureCreate(path: String, after: String) async throws -> AgentHistoryEntry {
            let change = AgentHistoryRecordedFileChange(
                relativePath: path,
                operation: .create,
                before: nil,
                after: stateFor(contents: after)
            )
            return try await store.recordVerifiedChangeSet(
                agentType: .codex,
                changes: [change],
                beforeContents: [:],
                provenance: provenance(),
                workspace: try workspace()
            )
        }

        func captureDelete(path: String, before: String) async throws -> AgentHistoryEntry {
            let change = AgentHistoryRecordedFileChange(
                relativePath: path,
                operation: .delete,
                before: stateFor(contents: before),
                after: nil
            )
            return try await store.recordVerifiedChangeSet(
                agentType: .codex,
                changes: [change],
                beforeContents: [path: Data(before.utf8)],
                provenance: provenance(),
                workspace: try workspace()
            )
        }

        private func stateFor(contents: String) -> AgentHistoryRecordedFileState {
            let data = Data(contents.utf8)
            return AgentHistoryRecordedFileState(
                kind: .regularFile,
                contentSHA256: AgentHistoryContentHash.sha256Hex(data),
                byteCount: UInt64(data.count),
                permissions: 0o644
            )
        }
    }

    private func makeEnv(
        beforeConsume: (@Sendable () throws -> Void)? = nil
    ) throws -> Env {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-checked-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let requestedPrivateBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-checked-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: requestedPrivateBase,
            withIntermediateDirectories: true
        )
        let privateBase = physicalTemporaryURL(requestedPrivateBase)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "init"]
        try process.run()
        process.waitUntilExit()
        try runGit(repo, ["config", "user.email", "test@pine.local"])
        try runGit(repo, ["config", "user.name", "Pine Test"])

        let privateStore = AgentHistoryPrivateStore(
            baseDirectory: privateBase,
            beforeConsume: beforeConsume
        )
        let store = AgentHistoryStore(projectRoot: repo, privateStore: privateStore)
        return Env(
            repo: repo,
            privateBase: privateBase,
            privateStore: privateStore,
            store: store,
            sessionID: UUID()
        )
    }

    private func runGit(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        try process.run()
        process.waitUntilExit()
    }

    private func posixPermissions(of url: URL) -> UInt16? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let value = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return value.uint16Value
    }

    /// `/var` is a macOS compatibility symlink to `/private/var`, but
    /// Foundation deliberately preserves its spelling. Private-store tests use
    /// the physical path so component-wise O_NOFOLLOW traversal rejects only
    /// the symlinks each test intentionally creates.
    private func physicalTemporaryURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard path == "/var" || path.hasPrefix("/var/") else { return url }
        return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
    }

    nonisolated private enum InjectedFailure: Error {
        case consume
    }

    nonisolated private final class OpenFileMutator: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32 = -1

        deinit {
            lock.withLock {
                if descriptor >= 0 {
                    close(descriptor)
                }
            }
        }

        func openFile(at url: URL) throws {
            let opened = open(
                url.path,
                O_WRONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard opened >= 0 else {
                throw InjectedFailure.consume
            }
            lock.withLock {
                if descriptor >= 0 {
                    close(descriptor)
                }
                descriptor = opened
            }
        }

        func overwrite() throws {
            try lock.withLock {
                guard descriptor >= 0,
                      ftruncate(descriptor, 0) == 0,
                      lseek(descriptor, 0, SEEK_SET) == 0 else {
                    throw InjectedFailure.consume
                }
                let data = Data("human through old descriptor\n".utf8)
                try data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress,
                          Darwin.write(
                            descriptor,
                            baseAddress,
                            bytes.count
                          ) == bytes.count,
                          fsync(descriptor) == 0 else {
                        throw InjectedFailure.consume
                    }
                }
            }
        }

        func overwriteAndFail() throws {
            try overwrite()
            throw InjectedFailure.consume
        }
    }

    nonisolated private final class LockedFileURL: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: URL?

        func set(_ url: URL) {
            lock.withLock { storage = url }
        }

        func requiredURL() throws -> URL {
            try lock.withLock {
                guard let storage else {
                    throw InjectedFailure.consume
                }
                return storage
            }
        }
    }

    nonisolated private final class ThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []

        var values: [Bool] {
            lock.withLock { storage }
        }

        func recordMainThread(_ value: Bool) {
            lock.withLock { storage.append(value) }
        }
    }
}
