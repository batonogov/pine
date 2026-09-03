//
//  AgentWorktreeDiscoveryTests.swift
//  PineTests
//
//  #1563. Closing a project drops its agent worktrees from the window's
//  record while their directories and branches stay on disk. Discovery reads
//  the repository back when the manager opens, so those orphans remain
//  listable, mergeable and removable through the #1524 paths.
//

import CryptoKit
import Foundation
import Testing

@testable import Pine

@Suite("Agent worktree discovery", .serialized)
struct AgentWorktreeDiscoveryTests {
    // MARK: - Porcelain parsing

    @Test("Porcelain parsing reads paths, branches, and detachment")
    func porcelainParsingReadsPathsBranchesAndDetachment() {
        let output = [
            "worktree /repos/primary",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /managed/00000000-0000-0000-0000-000000000021",
            "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/pine/agent/codex/11111111",
            "locked some reason",
            "",
            "worktree /managed/00000000-0000-0000-0000-000000000022",
            "HEAD 3333333333333333333333333333333333333333",
            "detached",
            "",
            "worktree /repos/bare",
            "bare",
            "",
        ].joined(separator: "\0")

        let entries = AgentWorktreeListParser.entries(inPorcelainOutput: output)

        #expect(entries == [
            AgentWorktreeListEntry(
                path: "/repos/primary",
                branch: "main"
            ),
            AgentWorktreeListEntry(
                path: "/managed/00000000-0000-0000-0000-000000000021",
                branch: "pine/agent/codex/11111111"
            ),
            AgentWorktreeListEntry(
                path: "/managed/00000000-0000-0000-0000-000000000022",
                branch: nil
            ),
            AgentWorktreeListEntry(path: "/repos/bare", branch: nil),
        ])
    }

    @Test("A branch record before any worktree record is dropped")
    func orphanedBranchRecordIsDropped() {
        let malformed = [
            "branch refs/heads/stray",
            "",
            "worktree /managed/00000000-0000-0000-0000-000000000023",
            "HEAD 4444444444444444444444444444444444444444",
            "branch refs/heads/pine/agent/codex/22222222",
            "",
        ].joined(separator: "\0")

        let entries = AgentWorktreeListParser.entries(
            inPorcelainOutput: malformed
        )

        #expect(entries == [
            AgentWorktreeListEntry(
                path: "/managed/00000000-0000-0000-0000-000000000023",
                branch: "pine/agent/codex/22222222"
            )
        ])
    }

    @Test("Only a canonical lowercase UUID names a task directory")
    func onlyLowercaseUUIDNamesATaskDirectory() {
        #expect(
            AgentWorktreeListParser.taskID(
                forLowercaseUUIDName: "00000000-0000-0000-0000-000000000021"
            ) == id(0x21)
        )
        #expect(
            AgentWorktreeListParser.taskID(forLowercaseUUIDName: "notes") == nil
        )
        // Uppercase spelling is not what `AgentWorktreeService.create` writes.
        #expect(
            AgentWorktreeListParser.taskID(
                forLowercaseUUIDName: "00000000-0000-0000-0000-00000000000A"
            ) == nil
        )
        #expect(
            AgentWorktreeListParser.taskID(
                forLowercaseUUIDName: "00000000000000000000000000000021"
            ) == nil
        )
        #expect(AgentWorktreeListParser.taskID(forLowercaseUUIDName: "") == nil)
    }

    // MARK: - Managed-root derivation

    @Test("The managed root is the SHA-derived path under Application Support")
    func managedRootIsTheShaDerivedPath() {
        let repository = URL(
            fileURLWithPath: "/Users/tester/Projects/pine",
            isDirectory: true
        )
        let digest = SHA256.hash(data: Data(repository.path.utf8))
        let expected = digest.prefix(12).map {
            String(format: "%02x", $0)
        }.joined()

        let root = ProjectWindowSession.managedRoot(for: repository)

        #expect(
            Array(root.pathComponents.suffix(3))
                == ["Pine", "AgentWorktrees", expected]
        )
        #expect(
            root.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                == FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0]
        )
        // Pure derivation: the directory is not created.
        #expect(
            !FileManager.default.fileExists(atPath: root.path)
        )
    }

    // MARK: - Merge with the live record

    @Test("The merged listing keeps each worktree once and prefers the record")
    func mergedListingKeepsEachWorktreeOnce() {
        let live = makeDiscoveredWorktree(
            taskID: id(0x31),
            branch: "pine/agent/codex/aaaabbbb",
            baseCommit: String(repeating: "a", count: 40)
        )
        // What discovery would rebuild for the same checkout: same root, but
        // without the creation-time base commit.
        let twin = makeDiscoveredWorktree(
            taskID: id(0x31),
            branch: "pine/agent/codex/aaaabbbb",
            baseCommit: nil
        )
        let orphan = makeDiscoveredWorktree(
            taskID: id(0x32),
            branch: "pine/agent/codex/ccccdddd",
            baseCommit: nil
        )

        let merged = ProjectWindowSession.mergedWorktreeListing(
            live: [live],
            discovered: [twin, orphan]
        )

        #expect(merged.count == 2)
        // The live entry — the one carrying the creation-time facts — wins.
        #expect(merged.first { $0.taskID == live.taskID } == live)
        #expect(merged.contains(orphan))
    }

    // MARK: - Service discovery

    @Test("Discovery finds an orphan a project close left behind")
    func discoveryFindsAnOrphanAProjectCloseLeftBehind() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        let live = try await fixture.createWorktree(
            service, taskID: id(0x41), branch: "pine/agent/codex/aaaabbbb"
        )
        let orphan = try await fixture.createWorktree(
            service, taskID: id(0x42), branch: "pine/agent/codex/ccccdddd"
        )

        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.managedRoot
        )

        #expect(discovered.map(\.taskID) == [id(0x41), id(0x42)])
        for worktree in [live, orphan] {
            let rebuilt = try #require(
                discovered.first { $0.taskID == worktree.taskID }
            )
            #expect(rebuilt.branchName == worktree.branchName)
            #expect(rebuilt.worktreeRoot == worktree.worktreeRoot)
            #expect(rebuilt.managedRoot == worktree.managedRoot)
            #expect(
                rebuilt.repositoryRoot.resolvingSymlinksInPath()
                    == worktree.repositoryRoot.resolvingSymlinksInPath()
            )
            // baseCommit is not recoverable from disk and nothing downstream
            // reads it; discovery must not invent one.
            #expect(rebuilt.baseCommit == nil)
            #expect(rebuilt.repositoryProof?.hasExactWorktreeInstance == true)
        }

        // The #1524 merge path runs on the rebuilt record alone: a close
        // survivor must be integratable without the creation-time base
        // commit ever existing.
        try Data("agent result\n".utf8).write(
            to: orphan.worktreeRoot.appendingPathComponent("tracked.txt")
        )
        try fixture.git(["add", "--", "tracked.txt"], at: orphan.worktreeRoot)
        try fixture.git(
            ["commit", "-m", "agent result"],
            at: orphan.worktreeRoot
        )
        let rebuiltOrphan = try #require(
            discovered.first { $0.taskID == id(0x42) }
        )
        let preview = await service.previewIntegration(
            rebuiltOrphan,
            previewID: id(0x43)
        )
        guard case .ready(let ready) = preview else {
            Issue.record("Expected a merge preview from a discovered record")
            return
        }
        #expect(ready.changedPaths == ["tracked.txt"])
        #expect(!ready.hasConflicts)
    }

    @Test("Discovery ignores worktrees outside the managed root")
    func discoveryIgnoresWorktreesOutsideTheManagedRoot() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        _ = try await fixture.createWorktree(
            service, taskID: id(0x51), branch: "pine/agent/codex/aaaabbbb"
        )
        // A worktree with a task-UUID name, but rooted outside the managed
        // directory: not Pine's for this repository.
        try fixture.git([
            "worktree", "add", "--no-track", "-b", "elsewhere/one", "--",
            fixture.outside.appendingPathComponent(
                id(0x52).uuidString.lowercased(),
                isDirectory: true
            ).path, "HEAD",
        ])

        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.managedRoot
        )

        // The primary checkout and the outside worktree are both registered
        // with the repository; neither may be listed.
        #expect(discovered.map(\.taskID) == [id(0x51)])
    }

    @Test("Discovery ignores directories that are not task UUIDs")
    func discoveryIgnoresDirectoriesThatAreNotTaskUUIDs() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        _ = try await fixture.createWorktree(
            service, taskID: id(0x61), branch: "pine/agent/codex/aaaabbbb"
        )
        // Registered with git and under the managed root, but not named by a
        // task UUID.
        try fixture.git([
            "worktree", "add", "--no-track", "-b", "stray/one", "--",
            fixture.managedRoot.appendingPathComponent(
                "notes",
                isDirectory: true
            ).path, "HEAD",
        ])
        try FileManager.default.createDirectory(
            at: fixture.managedRoot.appendingPathComponent(
                "leftovers",
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )
        try Data("junk".utf8).write(
            to: fixture.managedRoot.appendingPathComponent(".DS_Store")
        )

        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.managedRoot
        )

        #expect(discovered.map(\.taskID) == [id(0x61)])
    }

    @Test("Directories git does not recognise are reported, not hidden")
    func directoriesGitDoesNotRecognizeAreReported() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        _ = try await fixture.createWorktree(
            service, taskID: id(0x71), branch: "pine/agent/codex/aaaabbbb"
        )
        // A task directory with no worktree behind it: an interrupted or
        // manually broken checkout.
        let leftover = fixture.managedRoot.appendingPathComponent(
            id(0x72).uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: leftover,
            withIntermediateDirectories: false
        )
        try Data("work\n".utf8).write(to: leftover.appendingPathComponent("draft.txt"))
        // A registered worktree the agent detached: the branch is gone from
        // git's records, the directory is still Pine's.
        let detached = try await fixture.createWorktree(
            service, taskID: id(0x73), branch: "pine/agent/codex/bbbbcccc"
        )
        try fixture.git(["checkout", "--detach"], at: detached.worktreeRoot)

        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.managedRoot
        )

        #expect(discovered.count == 3)
        #expect(
            Set(discovered.map(\.taskID))
                == Set([id(0x71), id(0x72), id(0x73)])
        )
        // A detached checkout git recognises is labelled for what it is —
        // never the task UUID, which the removal confirmation would quote
        // back as a branch name — and keeps its live proof.
        let detachedEntry = try #require(
            discovered.first { $0.taskID == id(0x73) }
        )
        #expect(detachedEntry.branchName == "detached")
        #expect(detachedEntry.baseCommit == nil)
        #expect(detachedEntry.repositoryProof?.hasExactWorktreeInstance == true)
        // A directory git says nothing about keeps the task UUID as its
        // identity and claims no proof.
        let leftoverEntry = try #require(
            discovered.first { $0.taskID == id(0x72) }
        )
        #expect(leftoverEntry.branchName == id(0x72).uuidString.lowercased())
        #expect(leftoverEntry.baseCommit == nil)
        #expect(leftoverEntry.repositoryProof == nil)
        #expect(
            leftoverEntry.worktreeRoot
                == fixture.managedRoot.appendingPathComponent(
                    id(0x72).uuidString.lowercased(),
                    isDirectory: true
                ).standardizedFileURL
        )
    }

    @Test("A repository with no managed root discovers nothing")
    func repositoryWithNoManagedRootDiscoversNothing() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        _ = try await fixture.createWorktree(
            service, taskID: id(0x81), branch: "pine/agent/codex/aaaabbbb"
        )

        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.root.appendingPathComponent(
                "absent",
                isDirectory: true
            )
        )

        #expect(discovered.isEmpty)
    }

    @Test("Discovery refuses a managed root inside the repository")
    func discoveryRefusesARootInsideTheRepository() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let inner = fixture.repository.appendingPathComponent(
            "inner-managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inner,
            withIntermediateDirectories: false
        )

        let discovered = await AgentWorktreeService()
            .discoverManagedWorktrees(
                repositoryRoot: fixture.repository,
                managedRoot: inner
            )

        #expect(discovered.isEmpty)
    }

    // MARK: - Manager rows

    @Test("A directory git does not recognise is shown as unavailable")
    @MainActor
    func unrecognizedDirectoryIsUnavailableInTheManager() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        _ = try await fixture.createWorktree(
            service, taskID: id(0x91), branch: "pine/agent/codex/aaaabbbb"
        )
        let leftover = fixture.managedRoot.appendingPathComponent(
            id(0x92).uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: leftover,
            withIntermediateDirectories: false
        )
        let discovered = await service.discoverManagedWorktrees(
            repositoryRoot: fixture.repository,
            managedRoot: fixture.managedRoot
        )
        let model = AgentWorktreeManagerModel(service: service)

        // While the listing loads the sheet must not claim the list is empty.
        model.beginListing()
        #expect(model.isListing)
        await model.refresh(discovered)
        #expect(!model.isListing)

        #expect(
            model.rows.first { $0.worktree.taskID == id(0x91) }?.status
                == .clean
        )
        #expect(
            model.rows.first { $0.worktree.taskID == id(0x92) }?.status
                == .unavailable
        )
    }

    // MARK: - Session listing

    @Test("The manager listing merges the live record with disk discovery")
    @MainActor
    func managerListingMergesRecordWithDiscovery() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        let live = try await fixture.createWorktree(
            service, taskID: id(0xA1), branch: "pine/agent/codex/aaaabbbb"
        )
        // What a project close left behind: on disk and registered, absent
        // from this window's record.
        let orphan = try await fixture.createWorktree(
            service, taskID: id(0xA2), branch: "pine/agent/codex/ccccdddd"
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.repository,
            defaults: fixture.defaults,
            worktreeService: service,
            managedRootResolver: { _ in fixture.managedRoot }
        )
        session.adoptWorktreeForTesting(live)

        let listing = await session.worktreeManagerListing()

        #expect(listing.map(\.taskID) == [id(0xA1), id(0xA2)])
        // Discovery lists the orphan without re-adopting it into the window's
        // record: the switcher keeps showing only what the user opened.
        #expect(session.allManagedWorktrees.map(\.taskID) == [id(0xA1)])
        // Persisted-state invariant: a discovered entry must never enter the
        // record — a persisted worktree with a nil base commit or proof would
        // not decode in older builds.
        #expect(
            session.managedWorktrees[
                orphan.worktreeRoot.standardizedFileURL
            ] == nil
        )

        // Once the orphan is part of the record again, it is listed once and
        // the record's entry — the one with the base commit — is the one shown.
        session.adoptWorktreeForTesting(orphan)
        let merged = await session.worktreeManagerListing()
        #expect(merged.count == 2)
        let shownOrphan = try #require(
            merged.first { $0.taskID == id(0xA2) }
        )
        #expect(shownOrphan == orphan)
    }

    @Test("Listing uses the active worktree record's managed root")
    @MainActor
    func managerListingUsesTheActiveWorktreeRecordRoot() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        // A window sitting inside a worktree: the record's managed root is
        // the only spelling guaranteed to match what `launchAgent` used. The
        // resolver here deliberately answers with a wrong, non-existent root.
        let live = try await fixture.createWorktree(
            service, taskID: id(0xC1), branch: "pine/agent/codex/aaaabbbb"
        )
        _ = try await fixture.createWorktree(
            service, taskID: id(0xC2), branch: "pine/agent/codex/ccccdddd"
        )
        let session = ProjectWindowSession(
            initialProjectURL: live.worktreeRoot,
            defaults: fixture.defaults,
            worktreeService: service,
            managedRootResolver: { _ in
                fixture.root.appendingPathComponent(
                    "wrong-root",
                    isDirectory: true
                )
            }
        )
        session.adoptWorktreeForTesting(live)

        let listing = await session.worktreeManagerListing()

        // Hashing the resolver's answer would discover nothing; the record's
        // root finds the orphan.
        #expect(
            Set(listing.map(\.taskID)) == Set([id(0xC1), id(0xC2)])
        )
    }

    @Test("A repository with no managed root lists only the live record")
    @MainActor
    func managerListingWithoutAManagedRoot() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.cleanup() }
        let service = AgentWorktreeService()
        let live = try await fixture.createWorktree(
            service, taskID: id(0xB1), branch: "pine/agent/codex/aaaabbbb"
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.repository,
            defaults: fixture.defaults,
            worktreeService: service,
            managedRootResolver: { _ in
                fixture.root.appendingPathComponent(
                    "absent",
                    isDirectory: true
                )
            }
        )
        session.adoptWorktreeForTesting(live)

        let listing = await session.worktreeManagerListing()

        #expect(listing.map(\.taskID) == [id(0xB1)])
    }
}

// MARK: - Fixtures

private func id(_ value: UInt8) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, value
    ))
}

private func makeDiscoveredWorktree(
    taskID: UUID,
    branch: String,
    baseCommit: String?
) -> AgentManagedWorktree {
    let managedRoot = URL(
        fileURLWithPath: "/tmp/pine-discovery-managed",
        isDirectory: true
    )
    return AgentManagedWorktree(
        taskID: taskID,
        repositoryRoot: URL(
            fileURLWithPath: "/tmp/pine-discovery-repository",
            isDirectory: true
        ),
        managedRoot: managedRoot,
        worktreeRoot: managedRoot.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        ),
        branchName: branch,
        baseCommit: baseCommit,
        repositoryProof: RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: 1,
            commonDirectoryInode: 2,
            commonDirectoryGeneration: 3,
            commonDirectoryBirthSeconds: 4,
            commonDirectoryBirthNanoseconds: 5
        )
    )
}

private enum DiscoveryFixtureError: Error {
    case commandFailed
}

private final class DiscoveryFixture {
    let root: URL
    let repository: URL
    let managedRoot: URL
    let outside: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PineAgentWorktreeDiscovery-\(UUID().uuidString)",
            isDirectory: true
        )
        repository = root.appendingPathComponent("repository", isDirectory: true)
        managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        suiteName = "AgentWorktreeDiscoveryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        _ = try git(["init", "-b", "main"], at: repository)
        _ = try git(["config", "user.email", "pine-tests@example.invalid"])
        _ = try git(["config", "user.name", "Pine Tests"])
        try Data("base\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        _ = try git(["add", "--", "tracked.txt"])
        _ = try git(["commit", "-m", "base"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func createWorktree(
        _ service: AgentWorktreeService,
        taskID: UUID,
        branch: String
    ) async throws -> AgentManagedWorktree {
        let result = await service.create(AgentWorktreeCreateRequest(
            taskID: taskID,
            repositoryRoot: repository,
            managedRoot: managedRoot,
            branchName: branch,
            startPoint: "HEAD"
        ))
        guard case .created(let worktree) = result else {
            throw DiscoveryFixtureError.commandFailed
        }
        return worktree
    }

    @discardableResult
    func git(
        _ arguments: [String],
        at directory: URL? = nil
    ) throws -> String {
        let result = GitCommand.run(arguments, at: directory ?? repository)
        guard result.succeeded else {
            throw DiscoveryFixtureError.commandFailed
        }
        return result.output
    }
}
