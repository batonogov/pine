//
//  AgentHistoryBoundedFileReaderTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Agent History bounded file reads", .serialized)
struct AgentHistoryBoundedFileReaderTests {
    private static let sparseAttackSize: off_t = 8 * 1_024 * 1_024 * 1_024

    @Test("Oversized sparse replacements fail before snapshot allocation")
    func sparseReplacementFailsClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("App.swift")
        try Data("agent\n".utf8).write(to: target)

        let descriptor = open(
            target.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, Self.sparseAttackSize) == 0)

        let workspace = try AgentHistorySafeWorkspace(root: root)
        #expect(throws: AgentHistoryBoundedFileReadError.byteCountMismatch(
            expected: 6,
            actualAtMost: UInt64(Self.sparseAttackSize)
        )) {
            try workspace.snapshot(
                relativePath: "App.swift",
                expectedByteCount: 6
            )
        }
    }

    @Test("An unexpected delete target is detected without reading its bytes")
    func unexpectedDeleteTargetIsMetadataOnly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Deleted.swift")
        let descriptor = open(
            target.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        try #require(descriptor >= 0)
        try #require(ftruncate(descriptor, Self.sparseAttackSize) == 0)
        close(descriptor)

        let workspace = try AgentHistorySafeWorkspace(root: root)
        let snapshot = try workspace.snapshot(
            relativePath: "Deleted.swift",
            expectedByteCount: nil
        )

        #expect(snapshot.exists)
        #expect(snapshot.data == Data())
        #expect(snapshot.permissions == 0o600)
    }

    @Test("A late append reads only the expected byte count plus one")
    func lateAppendStopsAtSentinelByte() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("App.swift")
        let expected = Data("agent\n".utf8)
        try expected.write(to: target)

        let reader = open(
            target.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        try #require(reader >= 0)
        defer { close(reader) }
        let writer = open(
            target.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        try #require(writer >= 0)
        defer { close(writer) }

        #expect(throws: AgentHistoryBoundedFileReadError.byteCountMismatch(
            expected: UInt64(expected.count),
            actualAtMost: UInt64(Self.sparseAttackSize)
        )) {
            try AgentHistoryBoundedFileReader.readExact(
                descriptor: reader,
                expectedByteCount: UInt64(expected.count),
                afterInitialStat: {
                    guard ftruncate(writer, Self.sparseAttackSize) == 0 else {
                        throw AgentHistoryBoundedFileReadError.posixFailure(
                            errno
                        )
                    }
                }
            )
        }
        #expect(lseek(reader, 0, SEEK_CUR) == off_t(expected.count + 1))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-bounded-read-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
