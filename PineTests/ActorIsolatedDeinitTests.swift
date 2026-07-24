//
//  ActorIsolatedDeinitTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Actor-Isolated Deinit Tests", .serialized)
struct ActorIsolatedDeinitTests {

    @Test("WorkspaceManager safely releases from a detached task")
    @MainActor
    func workspaceManagerDetachedLastRelease() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: directory)
        await manager.waitForLoadingComplete()

        let isReleased = { [weak manager] in manager == nil }
        await Self.releaseFromDetachedTask(consume manager)

        for _ in 0..<100 where !isReleased() {
            await Task.yield()
        }
        #expect(isReleased())
    }

    @Test("ProjectManager safely releases recovery state from a detached task")
    @MainActor
    func projectManagerDetachedLastRelease() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ProjectManager()
        manager.setupRecovery(projectURL: directory)
        #expect(manager.recoveryManager != nil)

        let isReleased = { [weak manager] in manager == nil }
        await Self.releaseFromDetachedTask(consume manager)

        for _ in 0..<100 where !isReleased() {
            await Task.yield()
        }
        #expect(isReleased())
    }

    nonisolated private static func releaseFromDetachedTask<T>(
        _ object: consuming T
    ) async where T: AnyObject & Sendable {
        await Task.detached { [object = consume object] in
            var detachedReference: T? = consume object
            precondition(detachedReference != nil)
            detachedReference = nil
        }.value
    }

    @MainActor
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineIsolatedDeinitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
