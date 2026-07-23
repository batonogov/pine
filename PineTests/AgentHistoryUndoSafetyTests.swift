//
//  AgentHistoryUndoSafetyTests.swift
//  PineTests
//
//  Fail-closed containment tests for Agent History undo (#1183).
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent History Undo Safety")
@MainActor
struct AgentHistoryUndoSafetyTests {

    @Test("Persisted legacy entries decode as heuristic and cannot touch git")
    func persistedLegacyEntryIsReadOnly() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeToRepo(repo, file: "tracked.txt", contents: "committed\n")
        try gitInRepo(repo, ["add", "tracked.txt"])
        try gitInRepo(repo, ["commit", "-m", "initial"])
        let unrelatedWork = "committed\nhuman work that must survive\n"
        try writeToRepo(repo, file: "tracked.txt", contents: unrelatedWork)

        // This is the exact pre-#1183 shape: there is no `attribution` key.
        let legacyLog = Data("""
        [{
          "id": "00000000-0000-0000-0000-000000000101",
          "sessionID": "00000000-0000-0000-0000-000000000102",
          "agentTypeRaw": "codex",
          "startedAt": "2026-07-23T10:00:00Z",
          "endedAt": "2026-07-23T10:01:00Z",
          "affectedFiles": ["tracked.txt"],
          "summary": "1 file",
          "reverted": false
        }]
        """.utf8)
        try writeLog(in: repo, contents: legacyLog)

        let store = AgentHistoryStore(projectRoot: repo)
        let entry = try #require(store.entries.first)
        #expect(entry.attribution == .heuristic)
        #expect(entry.undoAvailability == .unavailable(.heuristicAttribution))

        let result = await store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.fileResults.isEmpty)
        #expect(result.blockedReason == .heuristicAttribution)
        #expect(store.entries.first?.reverted == false)
        #expect(try readFromRepo(repo, file: "tracked.txt") == unrelatedWork)
    }

    @Test("Unknown future attribution values fail closed")
    func unknownAttributionFailsClosed() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000111",
          "sessionID": "00000000-0000-0000-0000-000000000112",
          "agentTypeRaw": "generic:FutureAgent",
          "startedAt": 1000,
          "affectedFiles": ["tracked.txt"],
          "attribution": "future-provenance-v2",
          "summary": "1 file"
        }
        """.utf8)

        let entry = try JSONDecoder().decode(AgentHistoryEntry.self, from: data)

        #expect(entry.attribution == .heuristic)
        #expect(entry.undoAvailability == .unavailable(.heuristicAttribution))
    }

    @Test("Malformed attribution values fail closed")
    func malformedAttributionFailsClosed() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000121",
          "sessionID": "00000000-0000-0000-0000-000000000122",
          "agentTypeRaw": "codex",
          "startedAt": 1000,
          "affectedFiles": ["tracked.txt"],
          "attribution": 42,
          "summary": "1 file"
        }
        """.utf8)

        let entry = try JSONDecoder().decode(AgentHistoryEntry.self, from: data)

        #expect(entry.attribution == .heuristic)
        #expect(entry.undoAvailability == .unavailable(.heuristicAttribution))
    }

    @Test("Attribution round-trips without granting undo")
    func attributionRoundTripsFailClosed() throws {
        let expectations: [(AgentHistoryAttribution, AgentHistoryUndoUnavailableReason)] = [
            (.heuristic, .heuristicAttribution),
            (.ambiguous, .ambiguousAttribution),
            (.verified, .missingVerifiedReversibleChangeSet),
        ]

        for (attribution, reason) in expectations {
            let original = makeEntry(attribution: attribution)
            let data = try AgentHistoryStore.makeEncoder().encode(original)
            let decoded = try AgentHistoryStore.makeDecoder().decode(
                AgentHistoryEntry.self,
                from: data
            )

            #expect(decoded.attribution == attribution)
            #expect(decoded.undoAvailability == .unavailable(reason))
        }
    }

    @Test("New finalized entries are explicitly heuristic")
    func finalizedEntryIsHeuristic() throws {
        let store = AgentHistoryStore(projectRoot: nil)
        let session = AgentSession(agentType: .codex, state: .done)

        store.finalize(
            session: session,
            summary: "1 file",
            affectedRelativePaths: ["tracked.txt"]
        )

        let entry = try #require(store.entries.first)
        #expect(entry.attribution == .heuristic)
        #expect(entry.undoAvailability == .unavailable(.heuristicAttribution))
    }

    @Test("Ambiguous attribution is rejected before git")
    func ambiguousEntryCannotMutateWorkingTree() async throws {
        try await expectWorkingTreeUnchanged(
            attribution: .ambiguous,
            blockedReason: .ambiguousAttribution
        )
    }

    @Test("Verified attribution without an inverse change set is still rejected")
    func verifiedAttributionAloneCannotMutateWorkingTree() async throws {
        try await expectWorkingTreeUnchanged(
            attribution: .verified,
            blockedReason: .missingVerifiedReversibleChangeSet
        )
    }

    @Test("The mutation guard trusts the stored entry, not a caller copy")
    func staleCallerCannotBypassStoredAttribution() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeToRepo(repo, file: "tracked.txt", contents: "committed\n")
        try gitInRepo(repo, ["add", "tracked.txt"])
        try gitInRepo(repo, ["commit", "-m", "initial"])
        let unrelatedWork = "committed\nnew human edit\n"
        try writeToRepo(repo, file: "tracked.txt", contents: unrelatedWork)

        let storedEntry = makeEntry(attribution: .heuristic)
        let store = AgentHistoryStore(projectRoot: repo)
        store.append(storedEntry)
        store.flush()

        let callerCopy = AgentHistoryEntry(
            id: storedEntry.id,
            sessionID: storedEntry.sessionID,
            agentTypeRaw: storedEntry.agentTypeRaw,
            startedAt: storedEntry.startedAt,
            affectedFiles: storedEntry.affectedFiles,
            attribution: .verified,
            summary: storedEntry.summary
        )
        let result = await store.revert(entry: callerCopy)

        #expect(result.blockedReason == .heuristicAttribution)
        #expect(try readFromRepo(repo, file: "tracked.txt") == unrelatedWork)
    }

    @Test("An empty heuristic entry is not marked reverted")
    func emptyHeuristicEntryRemainsReadOnly() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentHistoryStore(projectRoot: root)
        let entry = AgentHistoryEntry(
            sessionID: UUID(),
            agentTypeRaw: "codex",
            startedAt: Date(),
            affectedFiles: [],
            summary: "0 files"
        )
        store.append(entry)
        store.flush()

        let result = await store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.blockedReason == .heuristicAttribution)
        #expect(store.entries.first?.reverted == false)
    }

    @Test("History rows expose read-only availability to the UI")
    func historyRowIsReadOnly() {
        let entry = makeEntry(attribution: .ambiguous)
        let row = AgentHistoryRow(from: entry)

        #expect(row.undoAvailability == .unavailable(.ambiguousAttribution))
        #expect(row.affectedFileCount == 1)
    }

    // MARK: - Helpers

    private func expectWorkingTreeUnchanged(
        attribution: AgentHistoryAttribution,
        blockedReason: AgentHistoryUndoUnavailableReason
    ) async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeToRepo(repo, file: "tracked.txt", contents: "committed\n")
        try gitInRepo(repo, ["add", "tracked.txt"])
        try gitInRepo(repo, ["commit", "-m", "initial"])
        let unrelatedWork = "committed\nshared work must survive\n"
        try writeToRepo(repo, file: "tracked.txt", contents: unrelatedWork)

        let store = AgentHistoryStore(projectRoot: repo)
        let entry = makeEntry(attribution: attribution)
        store.append(entry)
        store.flush()

        let result = await store.revert(entry: entry)

        #expect(!result.allSucceeded)
        #expect(result.fileResults.isEmpty)
        #expect(result.blockedReason == blockedReason)
        #expect(store.entries.first?.reverted == false)
        #expect(try readFromRepo(repo, file: "tracked.txt") == unrelatedWork)
    }

    private func makeEntry(
        attribution: AgentHistoryAttribution,
        affectedFiles: [String] = ["tracked.txt"]
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            sessionID: UUID(),
            agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 1_000),
            affectedFiles: affectedFiles,
            attribution: attribution,
            summary: "\(affectedFiles.count) files"
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-history-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTempGitRepo() throws -> URL {
        let url = try makeTempDirectory()
        try gitInRepo(url, ["init"])
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
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "AgentHistoryUndoSafetyTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: output, encoding: .utf8) ?? "git failed",
                ]
            )
        }
    }

    private func writeToRepo(_ repo: URL, file: String, contents: String) throws {
        let fileURL = repo.appendingPathComponent(file, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readFromRepo(_ repo: URL, file: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
    }

    private func writeLog(in root: URL, contents: Data) throws {
        let pineDirectory = root.appendingPathComponent(".pine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pineDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(
            to: pineDirectory.appendingPathComponent("agent-log.json"),
            options: .atomic
        )
    }
}
