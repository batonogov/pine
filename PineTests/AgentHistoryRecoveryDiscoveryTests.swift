//
//  AgentHistoryRecoveryDiscoveryTests.swift
//  PineTests
//
//  Restart and fail-closed coverage for owner-private checked-undo recovery.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent History Recovery Discovery", .serialized)
@MainActor
struct AgentHistoryRecoveryDiscoveryTests {
    @Test("Restart before authority consumption discovers a prepared backup")
    func restartBeforeConsumptionDiscoversPreparedBackup() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()

        let backupPath: String
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            backupPath = backup.path
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: identity,
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
        }
        let restartedStore = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let record = try #require(
            restartedStore.discoverRecoveryRecords().first
        )

        #expect(record.directoryPath == backupPath)
        #expect(record.transactionID == transactionID)
        #expect(record.authorityRecordID == authorityRecordID)
        #expect(record.state == .prepared)
        #expect(record.affectedPaths == ["Sources/App.swift"])
    }

    @Test("Restart after authority consumption surfaces the durable notice")
    func restartAfterConsumptionSurfacesNotice() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()

        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: identity,
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
            try backup.markPhase(
                .authorityConsumed,
                transactionID: transactionID
            )
        }
        let restartedStore = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let historyStore = AgentHistoryStore(
            projectRoot: environment.projectRoot,
            privateStore: restartedStore
        )
        // The initializer also schedules discovery. A second explicit refresh
        // makes this assertion independent of task scheduling order.
        await historyStore.refreshRecoveryNotices()
        await historyStore.refreshRecoveryNotices()
        let notice = try #require(historyStore.recoveryNotices.first)

        #expect(notice.transactionID == transactionID)
        #expect(notice.state == .authorityConsumed)
    }

    @Test("Corrupt manifests stay visible instead of being silently dropped")
    func corruptManifestStaysVisible() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let backupPath: String
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(recordID: UUID())
            backupPath = backup.path
            try backup.writeExclusive(
                Data("{not-json".utf8),
                named: "manifest.json"
            )
            try backup.synchronize()
        }
        let restartedStore = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let record = try #require(
            restartedStore.discoverRecoveryRecords().first
        )

        #expect(record.directoryPath == backupPath)
        #expect(record.manifest == nil)
        #expect(record.state == .corrupt(.invalidManifest))
    }

    @Test("A backup payload with the right size but wrong hash fails closed")
    func corruptBackupContentFailsClosed() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()
        let contentURL: URL
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: identity,
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
            contentURL = backup.url.appendingPathComponent("0.bin")
        }
        let handle = try FileHandle(forWritingTo: contentURL)
        try handle.write(contentsOf: Data("broken".utf8))
        try handle.close()

        let restartedStore = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let record = try #require(
            restartedStore.discoverRecoveryRecords().first
        )

        #expect(record.manifest == nil)
        #expect(record.state == .corrupt(.invalidManifest))
    }

    @Test(
        "Restart inventories original-stage and rollback quarantine crash windows"
    )
    func restartInventoriesWorkspaceCrashWindows() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let sources = environment.projectRoot.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: false
        )
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: identity,
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
        }

        let originalStage = sources.appendingPathComponent(
            ".pine-undo-original-\(transactionID.uuidString)-"
                + UUID().uuidString
        )
        let rollbackQuarantine = sources.appendingPathComponent(
            ".pine-undo-rollback-\(transactionID.uuidString)-"
                + UUID().uuidString
        )
        let initialQuarantine = sources.appendingPathComponent(
            ".pine-undo-\(transactionID.uuidString)-"
                + UUID().uuidString
        )
        let installStage = sources.appendingPathComponent(
            ".pine-undo-new-\(transactionID.uuidString)-"
                + UUID().uuidString
        )
        let unrelatedStage = sources.appendingPathComponent(
            ".pine-undo-original-\(UUID().uuidString)-"
                + UUID().uuidString
        )
        try Data("late original bytes".utf8).write(to: originalStage)
        try Data("late rollback bytes".utf8).write(to: rollbackQuarantine)
        try Data("initial quarantine bytes".utf8).write(
            to: initialQuarantine
        )
        try Data("install stage bytes".utf8).write(to: installStage)
        try Data("unrelated bytes".utf8).write(to: unrelatedStage)

        let restartedStore = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let record = try #require(
            restartedStore.discoverRecoveryRecords().first
        )

        #expect(record.state == .prepared)
        #expect(
            Set(record.workspaceArtifactPaths)
                == Set([
                    originalStage.path,
                    rollbackQuarantine.path,
                    initialQuarantine.path,
                    installStage.path
                ])
        )
        #expect(record.recoveryPaths.contains(originalStage.path))
        #expect(record.recoveryPaths.contains(rollbackQuarantine.path))
        #expect(record.recoveryPaths.contains(initialQuarantine.path))
        #expect(record.recoveryPaths.contains(installStage.path))
        #expect(!record.recoveryPaths.contains(unrelatedStage.path))
    }

    @Test("Workspace artifacts require the manifest root identity")
    func workspaceArtifactsRequireMatchingRootIdentity() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let sources = environment.projectRoot.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: false
        )
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: (
                    device: identity.device,
                    inode: identity.inode &+ 1
                ),
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
        }
        let matchingName = ".pine-undo-original-"
            + "\(transactionID.uuidString)-\(UUID().uuidString)"
        let artifact = sources.appendingPathComponent(matchingName)
        try Data("must not be trusted".utf8).write(to: artifact)

        let record = try #require(
            AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            ).discoverRecoveryRecords().first
        )

        #expect(record.state == .prepared)
        #expect(record.workspaceArtifactPaths.isEmpty)
        #expect(!record.validatedPaths.contains(artifact.path))
    }

    @Test("Finalized retained recovery is not reported as interrupted")
    func finalizedRetainedRecoveryKeepsFinalizedState() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let identity = try #require(
            AgentHistoryContentHash.rootIdentity(environment.projectRoot)
        )
        let transactionID = UUID()
        let authorityRecordID = UUID()
        let retainedPath: String
        do {
            let firstStore = AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            )
            let backup = try firstStore.createRecoveryBackup(
                recordID: authorityRecordID
            )
            try writePreparedRecord(
                to: backup,
                root: environment.projectRoot,
                identity: identity,
                transactionID: transactionID,
                authorityRecordID: authorityRecordID
            )
            let retainedName = "workspace-retained-\(UUID().uuidString).bin"
            try backup.writeExclusive(
                Data("retained bytes".utf8),
                named: retainedName
            )
            retainedPath = backup.url.appendingPathComponent(
                retainedName
            ).path
            let metadata = AgentHistoryRecoveryPathsManifest(
                formatVersion:
                    AgentHistoryRecoveryPathsManifest.currentFormatVersion,
                recoveryPaths: [retainedPath]
            )
            try backup.writeExclusive(
                AgentHistoryStore.makeEncoder().encode(metadata),
                named: "retained-quarantines.json"
            )
            try backup.synchronize()
            try backup.markPhase(
                .authorityConsumed,
                transactionID: transactionID
            )
            try backup.markPhase(
                .finalized,
                transactionID: transactionID
            )
        }

        let record = try #require(
            AgentHistoryPrivateStore(
                baseDirectory: environment.privateBase
            ).discoverRecoveryRecords().first
        )

        #expect(record.state == .finalized)
        #expect(record.recoveryPaths.contains(retainedPath))
        #expect(record.validatedPaths.contains(retainedPath))
    }

    @Test("A recovery-root symlink is never followed")
    func recoveryRootSymlinkFailsClosed() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let outside = environment.container.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)
        let recoveryLink = environment.privateBase.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: recoveryLink,
            withDestinationURL: outside
        )

        let store = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let record = try #require(store.discoverRecoveryRecords().first)

        #expect(record.state == .corrupt(.invalidRecoveryRoot))
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ) == [sentinel]
        )
    }

    @Test("Phase markers are append-only")
    func phaseMarkersCannotBeRewritten() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let store = AgentHistoryPrivateStore(
            baseDirectory: environment.privateBase
        )
        let backup = try store.createRecoveryBackup(recordID: UUID())
        let transactionID = UUID()
        let firstDate = Date(timeIntervalSince1970: 10)
        try backup.markPhase(
            .prepared,
            transactionID: transactionID,
            recordedAt: firstDate
        )

        #expect(throws: (any Error).self) {
            try backup.markPhase(
                .prepared,
                transactionID: transactionID,
                recordedAt: Date(timeIntervalSince1970: 20)
            )
        }
        let data = try Data(
            contentsOf: backup.url.appendingPathComponent(
                AgentHistoryRecoveryPhase.prepared.markerFileName
            )
        )
        let marker = try AgentHistoryStore.makeDecoder().decode(
            AgentHistoryRecoveryPhaseMarker.self,
            from: data
        )
        #expect(marker.recordedAt == firstDate)
    }

    private func writePreparedRecord(
        to backup: AgentHistoryRecoveryBackup,
        root: URL,
        identity: (device: UInt64, inode: UInt64),
        transactionID: UUID,
        authorityRecordID: UUID
    ) throws {
        let content = Data("after\n".utf8)
        try backup.writeExclusive(content, named: "0.bin")
        let manifest = AgentHistoryRecoveryManifest(
            formatVersion: AgentHistoryRecoveryManifest.currentFormatVersion,
            transactionID: transactionID,
            authorityRecordID: authorityRecordID,
            historyEntryID: UUID(),
            changeSetID: UUID(),
            resolvedRootPath: AgentHistoryContentHash.canonicalRootPath(root),
            rootDevice: identity.device,
            rootInode: identity.inode,
            createdAt: Date(timeIntervalSince1970: 1_000),
            entries: [
                AgentHistoryRecoveryManifestEntry(
                    relativePath: "Sources/App.swift",
                    existed: true,
                    permissions: 0o644,
                    contentFile: "0.bin",
                    byteCount: UInt64(content.count),
                    contentSHA256:
                        AgentHistoryContentHash.sha256Hex(content)
                )
            ]
        )
        try backup.writeExclusive(
            AgentHistoryStore.makeEncoder().encode(manifest),
            named: "manifest.json"
        )
        try backup.synchronize()
        try backup.markPhase(
            .prepared,
            transactionID: transactionID
        )
    }

    private func makeEnvironment() throws -> Environment {
        let requestedContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-recovery-discovery-\(UUID().uuidString)",
                isDirectory: true
            )
        let container = physicalTemporaryURL(requestedContainer)
        let projectRoot = container.appendingPathComponent(
            "project",
            isDirectory: true
        )
        let privateBase = container.appendingPathComponent(
            "private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: privateBase,
            withIntermediateDirectories: true
        )
        return Environment(
            container: container,
            projectRoot: projectRoot,
            privateBase: privateBase
        )
    }

    private func physicalTemporaryURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard path == "/var" || path.hasPrefix("/var/") else { return url }
        return URL(
            fileURLWithPath: "/private\(path)",
            isDirectory: true
        )
    }

    private struct Environment {
        let container: URL
        let projectRoot: URL
        let privateBase: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: container)
        }
    }
}
