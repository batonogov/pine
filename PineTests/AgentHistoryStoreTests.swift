//
//  AgentHistoryStoreTests.swift
//  PineTests
//
//  Unit tests for AgentHistoryStore (issue #1073): round-trip encode/decode,
//  corrupt-file tolerance, forward-compatible agent types, path validation,
//  fail-closed undo semantics, and atomic-write no-clobber under finalize.
//

import Testing
import Foundation
@testable import Pine

@Suite("AgentHistoryStore")
@MainActor
struct AgentHistoryStoreTests {

    // MARK: - Codable round-trip

    @Test func roundTripPreservesEntry() throws {
        let entry = AgentHistoryEntry(
            sessionID: UUID(),
            agentTypeRaw: "claudeCode",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            affectedFiles: ["src/a.swift", "README.md"],
            summary: "2 files, +10/-3 lines",
            reverted: false
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode([entry])
        let decoded = try decoder.decode([AgentHistoryEntry].self, from: data)

        #expect(decoded == [entry])
        #expect(decoded.first?.agentTypeRaw == "claudeCode")
        #expect(decoded.first?.affectedFiles == ["src/a.swift", "README.md"])
        #expect(decoded.first?.attribution == .heuristic)
    }

    @Test func unknownAgentTypeDecodesWithoutThrowing() throws {
        // A future/unknown agent type stored on disk must decode into a generic
        // entry rather than throwing — the log outlives individual app versions.
        let json = Data("""
        [{
            "id": "00000000-0000-0000-0000-000000000002",
            "sessionID": "00000000-0000-0000-0000-000000000003",
            "agentTypeRaw": "generic:FutureAgent",
            "startedAt": 1000,
            "endedAt": 2000,
            "affectedFiles": ["x.swift"],
            "summary": "1 file",
            "reverted": false
        }]
        """.utf8)

        let decoded = try JSONDecoder().decode([AgentHistoryEntry].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded.first?.agentTypeRaw == "generic:FutureAgent")
    }

    // MARK: - Corrupt-file tolerance

    @Test func corruptFileLoadsEmptyAndDoesNotCrash() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        try writeLog(in: temp, contents: Data("{ this is not valid json".utf8))

        let store = AgentHistoryStore(projectRoot: temp)
        #expect(store.entries.isEmpty)
    }

    @Test func missingFileLoadsEmpty() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        // No .pine/agent-log.json present.
        let store = AgentHistoryStore(projectRoot: temp)
        #expect(store.entries.isEmpty)
    }

    @Test func emptyFileLoadsEmpty() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }
        try writeLog(in: temp, contents: Data())
        let store = AgentHistoryStore(projectRoot: temp)
        #expect(store.entries.isEmpty)
    }

    @Test func validFileLoadsEntries() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let entry = AgentHistoryEntry(
            sessionID: UUID(),
            agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 500),
            affectedFiles: ["a.swift"],
            summary: "1 file"
        )
        try writeLog(in: temp, contents: try AgentHistoryStore.makeEncoder().encode([entry]))

        let store = AgentHistoryStore(projectRoot: temp)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.agentTypeRaw == "codex")
    }

    // MARK: - Path validation

    @Test func isValidRelativePath_rejectsAbsolute() {
        #expect(!AgentHistoryStore.isValidRelativePath("/etc/passwd"))
    }

    @Test func isValidRelativePath_rejectsTraversal() {
        #expect(!AgentHistoryStore.isValidRelativePath("../secret"))
        #expect(!AgentHistoryStore.isValidRelativePath("a/../../b"))
        #expect(!AgentHistoryStore.isValidRelativePath("src/../../etc/passwd"))
    }

    @Test func isValidRelativePath_rejectsEmpty() {
        #expect(!AgentHistoryStore.isValidRelativePath(""))
        #expect(!AgentHistoryStore.isValidRelativePath("   "))
    }

    @Test func isValidRelativePath_acceptsGenuineRelative() {
        #expect(AgentHistoryStore.isValidRelativePath("src/a.swift"))
        #expect(AgentHistoryStore.isValidRelativePath("README.md"))
        #expect(AgentHistoryStore.isValidRelativePath("a/b/c.swift"))
    }

    // MARK: - finalize dedupe

    @Test func finalizeLogsDoneSessionOnce() {
        let store = AgentHistoryStore(projectRoot: nil)
        let session = AgentSession(agentType: .claudeCode, state: .done)
        store.finalize(session: session, summary: "1 file", affectedRelativePaths: ["a.swift"])
        store.finalize(session: session, summary: "1 file", affectedRelativePaths: ["a.swift"])
        #expect(store.entries.count == 1)
    }

    @Test func finalizeDropsInvalidPaths() {
        let store = AgentHistoryStore(projectRoot: nil)
        let session = AgentSession(agentType: .claudeCode, state: .done)
        store.finalize(
            session: session,
            summary: "",
            affectedRelativePaths: ["a.swift", "../escape", "/abs/path", ""]
        )
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.affectedFiles == ["a.swift"])
    }

    @Test func finalizeUsesDefaultSummaryWhenEmpty() {
        let store = AgentHistoryStore(projectRoot: nil)
        let session = AgentSession(agentType: .claudeCode, state: .done)
        store.finalize(session: session, summary: "", affectedRelativePaths: ["a.swift", "b.swift"])
        #expect(store.entries.first?.summary == "2 files")
    }

    // MARK: - Revert (no git repo: graceful failure)

    @Test func revertWithoutProjectRootFails() async throws {
        let store = AgentHistoryStore(projectRoot: nil)
        let session = AgentSession(agentType: .claudeCode, state: .done)
        store.finalize(session: session, summary: "", affectedRelativePaths: ["a.swift"])
        let entry = try #require(store.entries.first)

        let result = await store.revert(entry: entry)
        #expect(result.allSucceeded == false)
        // Entry stays non-reverted because nothing succeeded.
        #expect(store.entries.first?.reverted == false)
    }

    @Test func revertAlreadyRevertedIsNoOp() async throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = AgentHistoryStore(projectRoot: temp)
        let entry = AgentHistoryEntry(
            sessionID: UUID(),
            agentTypeRaw: "claudeCode",
            startedAt: Date(),
            affectedFiles: [],
            summary: "0 files",
            reverted: true
        )
        store.append(entry)

        let result = await store.revert(entry: entry)
        #expect(result.allSucceeded == false)
        #expect(result.fileResults.isEmpty)
        #expect(store.entries.first?.reverted == true)
    }

    // MARK: - Atomic write + flush

    @Test("Rapid sequential appends all land on disk after flush")
    func atomicWriteFlushesToDisk() async throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = AgentHistoryStore(projectRoot: temp)
        // Append several entries in quick succession (each schedules an async
        // write). `flush()` is the same barrier `applicationWillTerminate`
        // uses, so this also exercises the durability path.
        let count = 20
        for index in 0..<count {
            store.append(
                AgentHistoryEntry(
                    sessionID: UUID(),
                    agentTypeRaw: "claudeCode",
                    startedAt: Date(),
                    affectedFiles: ["file\(index).swift"],
                    summary: "entry \(index)"
                )
            )
        }

        // Block until every queued write has completed.
        store.flush()

        // Reload from disk to confirm the final state survived.
        let reloaded = AgentHistoryStore(projectRoot: temp)
        #expect(reloaded.entries.count == count)
        #expect(reloaded.entries.last?.summary == "entry \(count - 1)")
    }

    // MARK: - Revert integration (store → GitFileRevert → real git repo)

    @Test("store.revert refuses heuristic entries in a real git repo")
    func revertRefusesHeuristicEntryInTempGitRepo() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeToRepo(repo, file: "src/a.swift", contents: "v1\n")
        try gitInRepo(repo, ["add", "src/a.swift"])
        try gitInRepo(repo, ["commit", "-m", "initial"])

        // Simulate an agent modifying the file.
        try writeToRepo(repo, file: "src/a.swift", contents: "v1\nagent change\n")

        // Log the session via the store, then revert through the store.
        let store = AgentHistoryStore(projectRoot: repo)
        store.append(
            AgentHistoryEntry(
                sessionID: UUID(),
                agentTypeRaw: "claudeCode",
                startedAt: Date(),
                affectedFiles: ["src/a.swift"],
                summary: "1 file"
            )
        )
        let entry = try #require(store.entries.first)

        let result = await store.revert(entry: entry)
        #expect(!result.allSucceeded)
        #expect(result.fileResults.isEmpty)
        #expect(result.blockedReason == .heuristicAttribution)
        #expect(store.entries.first?.reverted == false)
        // The safety guard runs before GitFileRevert: unrelated working-tree
        // content remains byte-for-byte intact.
        let unchanged = try readFromRepo(repo, file: "src/a.swift")
        #expect(unchanged == "v1\nagent change\n")
    }

    // MARK: - Capacity trim

    @Test func appendsBeyondMaxAreTrimmedOldestFirst() {
        let store = AgentHistoryStore(projectRoot: nil)
        for index in 0..<550 {
            store.append(
                AgentHistoryEntry(
                    sessionID: UUID(),
                    agentTypeRaw: "claudeCode",
                    startedAt: Date(),
                    affectedFiles: [],
                    summary: "entry \(index)"
                )
            )
        }
        // maxEntries = 500; oldest 50 dropped.
        #expect(store.entries.count == 500)
        #expect(store.entries.first?.summary == "entry 50")
    }

    // MARK: - Helpers

    private func makeTempProject() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func writeLog(in root: URL, contents: Data) throws {
        let pineDir = root.appendingPathComponent(".pine", isDirectory: true)
        try FileManager.default.createDirectory(at: pineDir, withIntermediateDirectories: true)
        let logURL = pineDir.appendingPathComponent("agent-log.json", isDirectory: false)
        try contents.write(to: logURL)
    }

    // MARK: - Temp git repo helpers (for revert integration)

    private func makeTempGitRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-history-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try gitInRepo(url, ["init"])
        // Stable identity so commits work on CI runners without git config.
        try gitInRepo(url, ["config", "user.email", "test@pine.local"])
        try gitInRepo(url, ["config", "user.name", "Pine Test"])
        try gitInRepo(url, ["symbolic-ref", "HEAD", "refs/heads/main"])
        return url
    }

    private func gitInRepo(_ repo: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentHistoryStoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }

    private func writeToRepo(_ repo: URL, file: String, contents: String) throws {
        let fileURL = repo.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readFromRepo(_ repo: URL, file: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
    }
}
