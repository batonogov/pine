//
//  AgentEventProvenanceStoreTests.swift
//  PineTests
//
//  Security, durability, retention, and query coverage for epic #933's
//  owner-private provenance storage slice.
//

import CryptoKit
import Foundation
import Testing

@testable import Pine

struct AgentEventProvenanceStoreTests {
    private struct Fixture {
        let root: URL
        let storageRoot: URL
        let worktree: URL
        let scope: AgentEventStoreScope
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-provenance-\(UUID().uuidString)", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let storageRoot = root.appendingPathComponent("private-store", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: true
        )
        let scope = try AgentEventStoreScope(projectID: UUID(), worktreeURL: worktree)
        return Fixture(
            root: root,
            storageRoot: storageRoot,
            worktree: worktree,
            scope: scope
        )
    }

    private func envelope(
        _ fixture: Fixture,
        id: UUID = UUID(),
        projectID: UUID? = nil,
        sessionID: UUID = UUID(),
        terminalID: UUID = UUID(),
        generation: UInt64 = 1,
        worktreePath: String? = nil,
        cwd: String? = nil,
        cursor: UInt64,
        source: EventSource = .explicitAgentEvent,
        trust: TrustLevel = .verified,
        payload: AgentEventPayload = .none,
        agentTypeRaw: String = "claudeCode"
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            id: id,
            projectID: projectID ?? fixture.scope.projectID,
            sessionID: sessionID,
            agentTypeRaw: agentTypeRaw,
            process: AgentProcessIdentity(
                terminalID: terminalID,
                processGeneration: generation
            ),
            location: AgentEventLocation(
                worktreePath: worktreePath ?? fixture.scope.worktreePath,
                cwd: cwd ?? fixture.scope.worktreePath
            ),
            cursorValue: cursor,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(cursor)),
            source: source,
            trustLevel: trust,
            payload: payload
        )
    }

    private func mode(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            Issue.record("Missing POSIX permissions for \(url.path)")
            return 0
        }
        return permissions.uint16Value & 0o777
    }

    private func frameLength(in data: Data, at offset: Int) -> Int {
        guard data.count - offset >= 8 else { return 0 }
        let length = data[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        return 8 + Int(length) + 32
    }

    private func journalFrame(payload: Data) -> Data {
        var frame = SecureAgentEventJournal.frameMagic
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        frame.append(contentsOf: SHA256.hash(data: payload))
        return frame
    }

    private func recoveredReport(
        _ snapshot: AgentEventStoreSnapshot
    ) -> AgentEventCorruptionReport? {
        if case .recovered(let report) = snapshot.integrity {
            return report
        }
        return nil
    }

    // MARK: - Durable append and restart

    @Test func durableAppendSurvivesRestartAndProtocolAdapter() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let first = envelope(fixture, cursor: 1)
        let collector: AgentEventProvenanceCollector = store
        await collector.record(first)

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let snapshot = await restarted.snapshot()
        #expect(snapshot.integrity == .healthy)
        #expect(snapshot.lastSequence == 1)
        #expect(snapshot.records.map(\.envelope) == [first])
    }

    @Test func restartPreservesCursorAndDedupeCheckpointAfterRetention() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxRecords: 2,
            maxLogBytes: 32 * 1_024,
            maxRecordBytes: 4 * 1_024,
            maxDedupeEntries: 4
        )
        let session = UUID()
        let terminal = UUID()
        let ids = (0..<6).map { _ in UUID() }

        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        for cursor in 1...5 {
            let event = envelope(
                fixture,
                id: ids[cursor],
                sessionID: session,
                terminalID: terminal,
                cursor: UInt64(cursor)
            )
            #expect(await store.append(event) == .appended(sequence: UInt64(cursor)))
        }

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let retained = await restarted.snapshot()
        #expect(retained.records.map(\.sequence) == [4, 5])
        #expect(retained.lastSequence == 5)

        let retainedDuplicate = envelope(
            fixture,
            id: ids[5],
            sessionID: session,
            terminalID: terminal,
            cursor: 5
        )
        #expect(
            await restarted.append(retainedDuplicate)
                == .duplicate(existingSequence: 5)
        )

        let evictedCursor = envelope(
            fixture,
            id: ids[0],
            sessionID: session,
            terminalID: terminal,
            cursor: 1
        )
        #expect(
            await restarted.append(evictedCursor)
                == .rejected(.nonMonotonicCursor)
        )

        let next = envelope(
            fixture,
            id: ids[0],
            sessionID: session,
            terminalID: terminal,
            cursor: 6
        )
        #expect(await restarted.append(next) == .appended(sequence: 6))
    }

    // MARK: - Concurrency, dedupe, monotonicity

    @Test func concurrentStreamsReceiveUniqueGlobalMonotonicSequences() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let events = (0..<64).map { _ in
            envelope(fixture, cursor: 1)
        }

        let outcomes = await withTaskGroup(
            of: AgentEventAppendOutcome.self,
            returning: [AgentEventAppendOutcome].self
        ) { group in
            for event in events {
                group.addTask {
                    await store.append(event)
                }
            }
            var collected: [AgentEventAppendOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let sequences = outcomes.compactMap { outcome -> UInt64? in
            guard case .appended(let sequence) = outcome else { return nil }
            return sequence
        }.sorted()
        #expect(sequences == Array(1...64).map(UInt64.init))
        #expect(await store.snapshot().records.count == 64)
    }

    @Test func concurrentDuplicateHasExactlyOneDurableAppend() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let event = envelope(fixture, cursor: 1)

        let outcomes = await withTaskGroup(
            of: AgentEventAppendOutcome.self,
            returning: [AgentEventAppendOutcome].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    await store.append(event)
                }
            }
            var collected: [AgentEventAppendOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(outcomes.filter { $0 == .appended(sequence: 1) }.count == 1)
        #expect(outcomes.filter { $0 == .duplicate(existingSequence: 1) }.count == 31)
        #expect(await store.snapshot().records.count == 1)
    }

    @Test func cursorMustIncreaseWithinProcessStream() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let session = UUID()
        let terminal = UUID()

        #expect(
            await store.append(
                envelope(
                    fixture,
                    sessionID: session,
                    terminalID: terminal,
                    cursor: 2
                )
            ) == .appended(sequence: 1)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    sessionID: session,
                    terminalID: terminal,
                    cursor: 1
                )
            ) == .rejected(.nonMonotonicCursor)
        )
    }

    @Test func reusedEventIdentityWithDifferentContentIsRejected() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let id = UUID()
        let session = UUID()
        let terminal = UUID()
        let original = envelope(
            fixture,
            id: id,
            sessionID: session,
            terminalID: terminal,
            cursor: 1
        )
        let collision = envelope(
            fixture,
            id: id,
            sessionID: session,
            terminalID: terminal,
            cursor: 2,
            payload: .commandResult(
                AgentCommandResult(command: "git status", exitStatus: 0)
            )
        )

        #expect(await store.append(original) == .appended(sequence: 1))
        #expect(await store.append(collision) == .rejected(.identityCollision))
    }

    @Test func trackedStreamCountIsBounded() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(maxTrackedStreams: 2)
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )

        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 2))
        #expect(
            await store.append(envelope(fixture, cursor: 1))
                == .rejected(.streamLimitReached)
        )
    }

    // MARK: - Scope and fail-closed normalization

    @Test func wrongProjectAndWorktreeAreRejectedWithoutWriting() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherWorktree = fixture.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherWorktree, withIntermediateDirectories: true)
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )

        #expect(
            await store.append(
                envelope(fixture, projectID: UUID(), cursor: 1)
            ) == .rejected(.wrongProject)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    worktreePath: otherWorktree.path,
                    cwd: otherWorktree.path,
                    cursor: 1
                )
            ) == .rejected(.wrongWorktree)
        )
        #expect(await store.snapshot().records.isEmpty)
    }

    @Test func cwdOutsideWorktreeAndInvalidPayloadPathsFailClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )

        #expect(
            await store.append(
                envelope(fixture, cwd: fixture.root.path, cursor: 1)
            ) == .rejected(.invalidProvenance)
        )
        let invalidChange = AgentFileChange(
            relativePath: "../outside.swift",
            before: nil,
            after: .empty
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    cursor: 1,
                    payload: .fileChange(invalidChange)
                )
            ) == .rejected(.invalidPayload)
        )
    }

    @Test func canonicalPathsAreStoredAndTrustCannotBeUpgraded() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = fixture.worktree.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let event = envelope(
            fixture,
            worktreePath: fixture.worktree.appendingPathComponent(".").path,
            cwd: sourceDirectory.appendingPathComponent("..").appendingPathComponent("Sources").path,
            cursor: 1,
            source: .gitCorrelation,
            trust: .verified
        )

        #expect(await store.append(event) == .appended(sequence: 1))
        let stored = await store.snapshot().records.first?.envelope
        #expect(stored?.location.worktreePath == fixture.scope.worktreePath)
        #expect(stored?.location.cwd == sourceDirectory.resolvingSymlinksInPath().path)
        #expect(stored?.trustLevel == .inferred)
    }

    @Test func oversizedAgentTypeCommandPayloadAndFrameAreRejected() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxLogBytes: 8 * 1_024,
            maxRecordBytes: 512,
            maxAgentTypeBytes: 16,
            maxSourceBytes: 18,
            maxCommandBytes: 128
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )

        #expect(
            await store.append(
                envelope(
                    fixture,
                    cursor: 1,
                    agentTypeRaw: String(repeating: "a", count: 17)
                )
            ) == .rejected(.invalidProvenance)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    cursor: 1,
                    source: .unknown(raw: "   "),
                    trust: .inferred
                )
            ) == .rejected(.invalidProvenance)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    cursor: 1,
                    source: .unknown(raw: String(repeating: "s", count: 19)),
                    trust: .inferred
                )
            ) == .rejected(.invalidProvenance)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    cursor: 1,
                    payload: .commandResult(
                        AgentCommandResult(
                            command: String(repeating: "c", count: 129),
                            exitStatus: 0
                        )
                    )
                )
            ) == .rejected(.invalidPayload)
        )

        let frameLimitedStore = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.root.appendingPathComponent("frame-store"),
            limits: try AgentEventStoreLimits(
                maxLogBytes: 8 * 1_024,
                maxRecordBytes: 512,
                maxCommandBytes: 4 * 1_024
            )
        )
        #expect(
            await frameLimitedStore.append(
                envelope(
                    fixture,
                    cursor: 1,
                    payload: .commandResult(
                        AgentCommandResult(
                            command: String(repeating: "x", count: 1_024),
                            exitStatus: 0
                        )
                    )
                )
            ) == .rejected(.oversizedRecord)
        )
    }

    @Test func oversizedRelativePathAndInvalidLimitsAreRejected() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let longPath = String(repeating: "a", count: AgentEventStoreLimits.maximumPathBytes + 1)
        let change = AgentFileChange(relativePath: longPath, before: nil, after: .empty)
        #expect(
            await store.append(
                envelope(fixture, cursor: 1, payload: .fileChange(change))
            ) == .rejected(.invalidPayload)
        )
        #expect(
            await store.append(
                envelope(
                    fixture,
                    cwd: "/" + longPath,
                    cursor: 1
                )
            ) == .rejected(.invalidProvenance)
        )
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxRecords: 0)
        }
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxLogBytes: 1_024, maxRecordBytes: 2_048)
        }
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxRecords: Int.max)
        }
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxLogBytes: Int.max)
        }
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxCommandBytes: Int.max)
        }
        #expect(throws: AgentEventStoreError.invalidLimits) {
            _ = try AgentEventStoreLimits(maxQuarantineBytes: Int.max)
        }
    }

    // MARK: - Retention and read-only queries

    @Test func countRetentionKeepsNewestSuffixAndGlobalSequence() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxRecords: 3,
            maxDedupeEntries: 6
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let session = UUID()
        let terminal = UUID()
        for cursor in 1...10 {
            #expect(
                await store.append(
                    envelope(
                        fixture,
                        sessionID: session,
                        terminalID: terminal,
                        cursor: UInt64(cursor)
                    )
                ) == .appended(sequence: UInt64(cursor))
            )
        }

        let snapshot = await store.snapshot()
        #expect(snapshot.records.map(\.sequence) == [8, 9, 10])
        #expect(snapshot.lastSequence == 10)

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        #expect(await restarted.snapshot().records.map(\.sequence) == [8, 9, 10])
    }

    @Test func byteRetentionStaysBoundedAndKeepsLatestRecord() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxRecords: 100,
            maxLogBytes: 4 * 1_024,
            maxRecordBytes: 2 * 1_024,
            maxDedupeEntries: 5,
            maxTrackedStreams: 2,
            maxCommandBytes: 800
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let session = UUID()
        let terminal = UUID()
        for cursor in 1...12 {
            let outcome = await store.append(
                envelope(
                    fixture,
                    sessionID: session,
                    terminalID: terminal,
                    cursor: UInt64(cursor),
                    payload: .commandResult(
                        AgentCommandResult(
                            command: String(repeating: "x", count: 400),
                            exitStatus: 0
                        )
                    )
                )
            )
            #expect(outcome == .appended(sequence: UInt64(cursor)))
        }

        let locations = await store.storageLocations()
        let attributes = try FileManager.default.attributesOfItem(atPath: locations.journal.path)
        let size = (attributes[.size] as? NSNumber)?.intValue
        #expect(size != nil)
        #expect((size ?? Int.max) <= limits.maxLogBytes)
        #expect(await store.snapshot().records.last?.sequence == 12)
    }

    @Test func trustAndSequenceQueriesAreExplicitAndBounded() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(maxQueryResults: 2)
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )

        let verified = envelope(fixture, cursor: 1)
        let inferred = envelope(
            fixture,
            cursor: 1,
            source: .gitCorrelation,
            trust: .inferred
        )
        let observed = envelope(
            fixture,
            cursor: 1,
            source: .terminalProcess,
            trust: .observed
        )
        #expect(await store.append(verified) == .appended(sequence: 1))
        #expect(await store.append(inferred) == .appended(sequence: 2))
        #expect(await store.append(observed) == .appended(sequence: 3))

        let snapshot = await store.snapshot()
        #expect(snapshot.verified.map(\.sequence) == [1])
        #expect(snapshot.inferred.map(\.sequence) == [2])
        #expect(snapshot.observed.map(\.sequence) == [3])
        let inferredResult = await store.query(
            AgentEventQuery(trustLevel: .inferred)
        )
        #expect(inferredResult.integrity == .healthy)
        #expect(inferredResult.verified.isEmpty)
        #expect(inferredResult.inferred.map(\.sequence) == [2])
        #expect(inferredResult.observed.isEmpty)
        #expect(
            await store.query(
                AgentEventQuery(sequenceAfter: 1, limit: 99)
            ).records.map(\.sequence) == [2, 3]
        )
        #expect(
            await store.query(
                AgentEventQuery(sequenceThrough: 2)
            ).records.map(\.sequence) == [1, 2]
        )
    }

    // MARK: - Owner-private descriptor safety

    @Test func storageDirectoriesAndJournalAreOwnerPrivate() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let locations = await store.storageLocations()

        #expect(try mode(at: fixture.storageRoot) == 0o700)
        #expect(try mode(at: locations.scopeDirectory) == 0o700)
        #expect(try mode(at: locations.journal) == 0o600)
    }

    @Test func symlinkStorageRootAndScopeDirectoryAreRefused() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let realRoot = fixture.root.appendingPathComponent("real-root")
        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let linkedRoot = fixture.root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )
        #expect(throws: AgentEventStoreError.self) {
            _ = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: linkedRoot
            )
        }

        let storageRoot = fixture.root.appendingPathComponent("scope-root")
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let scopeDirectory = SecureAgentEventJournal.scopeDirectoryURL(
            storageRoot: storageRoot,
            scope: fixture.scope
        )
        try FileManager.default.createSymbolicLink(
            at: scopeDirectory,
            withDestinationURL: realRoot
        )
        #expect(throws: AgentEventStoreError.self) {
            _ = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: storageRoot
            )
        }
    }

    @Test func symlinkJournalIsRefusedWithoutTouchingTarget() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let scopeDirectory = SecureAgentEventJournal.scopeDirectoryURL(
            storageRoot: fixture.storageRoot,
            scope: fixture.scope
        )
        try FileManager.default.createDirectory(
            at: scopeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = fixture.root.appendingPathComponent("target")
        let marker = Data("do not touch".utf8)
        try marker.write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: target.path
        )
        let journal = scopeDirectory.appendingPathComponent(
            SecureAgentEventJournal.journalFileName
        )
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)

        #expect(throws: AgentEventStoreError.self) {
            _ = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: fixture.storageRoot
            )
        }
        #expect(try Data(contentsOf: target) == marker)
    }

    @Test func hardlinkedJournalIsRefused() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let scopeDirectory = SecureAgentEventJournal.scopeDirectoryURL(
            storageRoot: fixture.storageRoot,
            scope: fixture.scope
        )
        try FileManager.default.createDirectory(
            at: scopeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let external = fixture.root.appendingPathComponent("external-journal")
        try Data().write(to: external)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: external.path
        )
        let journal = scopeDirectory.appendingPathComponent(
            SecureAgentEventJournal.journalFileName
        )
        try FileManager.default.linkItem(at: external, to: journal)

        #expect(throws: AgentEventStoreError.self) {
            _ = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: fixture.storageRoot
            )
        }
    }

    @Test func directoryPathSwapFailsClosedBeforeNextAppend() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let locations = await store.storageLocations()
        let displaced = fixture.root.appendingPathComponent("displaced-scope")
        try FileManager.default.moveItem(at: locations.scopeDirectory, to: displaced)
        try FileManager.default.createDirectory(
            at: locations.scopeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let outcome = await store.append(envelope(fixture, cursor: 1))
        #expect(outcome == .rejected(.storage(.pathReplaced)))

        let replacement = fixture.root.appendingPathComponent("replacement-scope")
        try FileManager.default.moveItem(at: locations.scopeDirectory, to: replacement)
        try FileManager.default.moveItem(at: displaced, to: locations.scopeDirectory)
        #expect(
            await store.append(envelope(fixture, cursor: 1))
                == .rejected(.storage(.pathReplaced))
        )
        #expect(await store.snapshot().records.count == 1)
        #expect(await store.snapshot().integrity == .unavailable(.pathReplaced))
    }

    @Test func journalPathSwapToHardlinkFailsClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let locations = await store.storageLocations()
        let displaced = locations.scopeDirectory.appendingPathComponent("old-journal")
        try FileManager.default.moveItem(at: locations.journal, to: displaced)
        let external = fixture.root.appendingPathComponent("external")
        try Data("external".utf8).write(to: external)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: external.path
        )
        try FileManager.default.linkItem(at: external, to: locations.journal)

        let outcome = await store.append(envelope(fixture, cursor: 1))
        #expect(outcome == .rejected(.storage(.pathReplaced)))
        #expect(try Data(contentsOf: external) == Data("external".utf8))
    }

    @Test func addingASecondHardlinkToLiveJournalFailsClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let locations = await store.storageLocations()
        let secondLink = fixture.root.appendingPathComponent("journal-hardlink")
        try FileManager.default.linkItem(at: locations.journal, to: secondLink)

        let outcome = await store.append(envelope(fixture, cursor: 1))
        #expect(outcome == .rejected(.storage(.unsafeJournal)))
        #expect(await store.snapshot().records.count == 1)
        #expect(await store.snapshot().integrity == .unavailable(.unsafeJournal))
    }

    @Test func storageRootPathSwapFailsClosedBeforeNextAppend() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let displaced = fixture.root.appendingPathComponent("displaced-root")
        try FileManager.default.moveItem(at: fixture.storageRoot, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        #expect(
            await store.append(envelope(fixture, cursor: 1))
                == .rejected(.storage(.pathReplaced))
        )
    }

    @Test func groupReadablePreexistingJournalIsRefused() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let scopeDirectory = SecureAgentEventJournal.scopeDirectoryURL(
            storageRoot: fixture.storageRoot,
            scope: fixture.scope
        )
        try FileManager.default.createDirectory(
            at: scopeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let journal = scopeDirectory.appendingPathComponent(
            SecureAgentEventJournal.journalFileName
        )
        try Data().write(to: journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: journal.path
        )

        #expect(throws: AgentEventStoreError.self) {
            _ = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: fixture.storageRoot
            )
        }
    }

    // MARK: - Corruption quarantine and recovery

    @Test func truncatedTailIsQuarantinedThenValidPrefixLoads() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        let locations = await store.storageLocations()
        let suffix = Data([0x50, 0x4E, 0x45])
        let handle = try FileHandle(forWritingTo: locations.journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: suffix)
        try handle.close()

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let snapshot = await restarted.snapshot()
        let report = recoveredReport(snapshot)
        #expect(report?.kind == .truncatedFrame)
        #expect(report?.discardedByteCount == suffix.count)
        #expect(report?.quarantinedByteCount == suffix.count)
        #expect(snapshot.records.count == 1)
        #expect(await restarted.query().integrity == snapshot.integrity)

        guard let report else { return }
        let quarantine = locations.scopeDirectory
            .appendingPathComponent(report.quarantineFileName)
        #expect(try Data(contentsOf: quarantine) == suffix)
        #expect(try mode(at: quarantine) == 0o600)

        let cleanRestart = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await cleanRestart.snapshot().integrity == .healthy)
        #expect(await cleanRestart.snapshot().records.count == 1)
    }

    @Test func checksumCorruptionQuarantinesCorruptFrameAndFollowingSuffix() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        for cursor in 1...3 {
            #expect(
                await store.append(envelope(fixture, cursor: UInt64(cursor)))
                    == .appended(sequence: UInt64(cursor))
            )
        }
        let locations = await store.storageLocations()
        let bytes = try Data(contentsOf: locations.journal)
        let firstLength = frameLength(in: bytes, at: 0)
        #expect(firstLength > 8)
        let mutationOffset = firstLength + 12
        let handle = try FileHandle(forWritingTo: locations.journal)
        try handle.seek(toOffset: UInt64(mutationOffset))
        try handle.write(contentsOf: Data([bytes[mutationOffset] ^ 0x01]))
        try handle.close()

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let snapshot = await restarted.snapshot()
        let report = recoveredReport(snapshot)
        #expect(report?.kind == .checksumMismatch)
        #expect(report?.retainedRecordCount == 1)
        #expect(report?.discardedByteCount == bytes.count - firstLength)
        #expect(snapshot.records.map(\.sequence) == [1])
    }

    @Test func semanticCheckpointTamperIsQuarantinedWithValidChecksum() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxRecords: 2,
            maxDedupeEntries: 4
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        for cursor in 1...3 {
            #expect(
                await store.append(envelope(fixture, cursor: UInt64(cursor)))
                    == .appended(sequence: UInt64(cursor))
            )
        }

        let locations = await store.storageLocations()
        let bytes = try Data(contentsOf: locations.journal)
        let firstLength = frameLength(in: bytes, at: 0)
        let payloadLength = firstLength - 8 - 32
        guard firstLength > 8 + 32,
              firstLength <= bytes.count else {
            Issue.record("Expected a checkpoint frame")
            return
        }

        let payload = Data(bytes[8..<(8 + payloadLength)])
        guard var root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var checkpoint = root["checkpoint"] as? [String: Any],
              var identities = checkpoint["recentIdentities"] as? [[String: Any]],
              var finalIdentity = identities.last else {
            Issue.record("Expected checkpoint identity metadata")
            return
        }
        finalIdentity["digest"] = String(repeating: "0", count: 64)
        identities[identities.count - 1] = finalIdentity
        checkpoint["recentIdentities"] = identities
        root["checkpoint"] = checkpoint

        let tamperedPayload = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        var tamperedBytes = journalFrame(payload: tamperedPayload)
        tamperedBytes.append(bytes[firstLength...])
        try tamperedBytes.write(to: locations.journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: locations.journal.path
        )

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let snapshot = await restarted.snapshot()
        let report = recoveredReport(snapshot)
        #expect(report?.kind == .invalidCheckpoint)
        #expect(report?.discardedByteCount == tamperedBytes.count)
        #expect(report?.quarantinedByteCount == tamperedBytes.count)
        #expect(snapshot.records.isEmpty)
    }

    @Test func physicallyTruncatedLastFrameKeepsEarlierFrames() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 1))
        #expect(await store.append(envelope(fixture, cursor: 1)) == .appended(sequence: 2))
        let locations = await store.storageLocations()
        let bytes = try Data(contentsOf: locations.journal)
        let handle = try FileHandle(forWritingTo: locations.journal)
        try handle.truncate(atOffset: UInt64(bytes.count - 7))
        try handle.close()
        #expect(
            await store.append(envelope(fixture, cursor: 1))
                == .rejected(.storage(.unsafeJournal))
        )

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let snapshot = await restarted.snapshot()
        #expect(recoveredReport(snapshot)?.kind == .truncatedFrame)
        #expect(snapshot.records.map(\.sequence) == [1])
    }

    @Test func oversizedFrameHeaderIsQuarantinedWithoutAllocation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let locations = await store.storageLocations()
        var oversized = SecureAgentEventJournal.frameMagic
        var length = UInt32.max.bigEndian
        withUnsafeBytes(of: &length) { oversized.append(contentsOf: $0) }
        try oversized.write(to: locations.journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: locations.journal.path
        )

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        let snapshot = await restarted.snapshot()
        #expect(recoveredReport(snapshot)?.kind == .oversizedFrame)
        #expect(snapshot.records.isEmpty)
    }

    @Test func stricterRestartCountLimitQuarantinesOverflowFrames() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generous = try AgentEventStoreLimits(
            maxRecords: 4,
            maxDedupeEntries: 4
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: generous
        )
        for cursor in 1...3 {
            #expect(
                await store.append(envelope(fixture, cursor: UInt64(cursor)))
                    == .appended(sequence: UInt64(cursor))
            )
        }

        let strict = try AgentEventStoreLimits(
            maxRecords: 2,
            maxDedupeEntries: 2
        )
        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: strict
        )
        let snapshot = await restarted.snapshot()
        #expect(recoveredReport(snapshot)?.kind == .tooManyRecords)
        #expect(snapshot.records.map(\.sequence) == [1, 2])
    }

    @Test func oversizedJournalQuarantineCaptureIsBounded() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(
            maxLogBytes: 4 * 1_024,
            maxRecordBytes: 1_024,
            maxQuarantineBytes: 128
        )
        let store = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let locations = await store.storageLocations()
        let oversized = Data(repeating: 0xA5, count: 6 * 1_024)
        try oversized.write(to: locations.journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: locations.journal.path
        )

        let restarted = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot,
            limits: limits
        )
        let snapshot = await restarted.snapshot()
        let report = recoveredReport(snapshot)
        #expect(report?.kind == .oversizedJournal)
        #expect(report?.discardedByteCount == oversized.count)
        #expect(report?.quarantinedByteCount == limits.maxQuarantineBytes)
        guard let report else { return }
        let quarantine = locations.scopeDirectory
            .appendingPathComponent(report.quarantineFileName)
        #expect(try Data(contentsOf: quarantine).count == limits.maxQuarantineBytes)
    }

    @Test func copiedJournalFromWrongProjectOrWorktreeIsQuarantined() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalStore = try AgentEventProvenanceStore(
            scope: fixture.scope,
            storageRoot: fixture.storageRoot
        )
        #expect(
            await originalStore.append(envelope(fixture, cursor: 1))
                == .appended(sequence: 1)
        )
        let originalLocations = await originalStore.storageLocations()
        let originalBytes = try Data(contentsOf: originalLocations.journal)

        let otherProjectScope = try AgentEventStoreScope(
            projectID: UUID(),
            worktreeURL: fixture.worktree
        )
        let otherProjectStore = try AgentEventProvenanceStore(
            scope: otherProjectScope,
            storageRoot: fixture.storageRoot
        )
        let otherProjectLocations = await otherProjectStore.storageLocations()
        try originalBytes.write(to: otherProjectLocations.journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: otherProjectLocations.journal.path
        )
        let otherProjectRestart = try AgentEventProvenanceStore(
            scope: otherProjectScope,
            storageRoot: fixture.storageRoot
        )
        let projectSnapshot = await otherProjectRestart.snapshot()
        #expect(recoveredReport(projectSnapshot)?.kind == .scopeMismatch)
        #expect(projectSnapshot.records.isEmpty)

        let otherWorktree = fixture.root.appendingPathComponent("other-worktree")
        try FileManager.default.createDirectory(
            at: otherWorktree,
            withIntermediateDirectories: true
        )
        let otherWorktreeScope = try AgentEventStoreScope(
            projectID: fixture.scope.projectID,
            worktreeURL: otherWorktree
        )
        let otherWorktreeStore = try AgentEventProvenanceStore(
            scope: otherWorktreeScope,
            storageRoot: fixture.storageRoot
        )
        let otherWorktreeLocations = await otherWorktreeStore.storageLocations()
        try originalBytes.write(to: otherWorktreeLocations.journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: otherWorktreeLocations.journal.path
        )
        let otherWorktreeRestart = try AgentEventProvenanceStore(
            scope: otherWorktreeScope,
            storageRoot: fixture.storageRoot
        )
        let worktreeSnapshot = await otherWorktreeRestart.snapshot()
        #expect(recoveredReport(worktreeSnapshot)?.kind == .scopeMismatch)
        #expect(worktreeSnapshot.records.isEmpty)
    }

    @Test func quarantineFileRetentionIsBounded() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let limits = try AgentEventStoreLimits(maxQuarantineFiles: 2)

        var scopeDirectory: URL?
        for marker in 0..<5 {
            let store = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: fixture.storageRoot,
                limits: limits
            )
            let locations = await store.storageLocations()
            scopeDirectory = locations.scopeDirectory
            let handle = try FileHandle(forWritingTo: locations.journal)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([UInt8(marker)]))
            try handle.close()

            let recovered = try AgentEventProvenanceStore(
                scope: fixture.scope,
                storageRoot: fixture.storageRoot,
                limits: limits
            )
            #expect(recoveredReport(await recovered.snapshot()) != nil)
        }

        guard let scopeDirectory else {
            Issue.record("Missing scope directory")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: scopeDirectory.path
        ).filter {
            $0.hasPrefix("quarantine-") && $0.hasSuffix(".bin")
        }
        #expect(names.count == limits.maxQuarantineFiles)
    }
}
