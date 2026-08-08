//
//  ProjectRegistryTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectRegistry Tests")
@MainActor
struct ProjectRegistryTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Project creation

    @Test func projectManagerCreatesNewInstance() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm = registry.projectManager(for: tempDir)

        #expect(pm != nil)
        #expect(registry.openProjects.count >= 1)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] != nil)
    }

    @Test func projectManagerReturnsSameInstanceForSameURL() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        let pm2 = registry.projectManager(for: tempDir)

        #expect(pm1 != nil)
        #expect(pm1 === pm2)
    }

    @Test func projectManagerDeduplicatesSymlinks() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let symlinkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: tempDir)
        defer { cleanup(symlinkDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        let pm2 = registry.projectManager(for: symlinkDir)

        #expect(pm1 != nil)
        #expect(pm1 === pm2)

        // Only one entry in openProjects despite two different URLs
        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] === pm1)
    }

    @Test func projectManagerReturnsNilForDeletedDirectory() throws {
        let tempDir = try makeTempDirectory()
        let canonical = tempDir.resolvingSymlinksInPath()

        let registry = ProjectRegistry()

        // Open and close so it's in recent but not open
        let pm = registry.projectManager(for: tempDir)
        #expect(pm != nil)
        registry.closeProject(tempDir)
        #expect(registry.recentProjects.contains(canonical))

        // Delete directory, then try to open — must return nil
        cleanup(tempDir)
        let pm2 = registry.projectManager(for: tempDir)
        #expect(pm2 == nil)
    }

    @Test func terminationFreezeBlocksNewProjectAdmissionUntilRollback() async throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }
        let registry = ProjectRegistry()

        registry.freezeAgentTasksForTermination()

        #expect(registry.isProjectAdmissionFrozenForTermination)
        #expect(registry.projectManager(for: tempDir) == nil)
        #expect(registry.openProjects.isEmpty)

        #expect(await registry.cancelAgentTaskTermination())
        #expect(!registry.isProjectAdmissionFrozenForTermination)
        #expect(registry.projectManager(for: tempDir) != nil)
    }

    // MARK: - Close

    @Test func closeProjectKeepsInOpenProjectsAsBackground() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] != nil)

        registry.closeProject(tempDir)
        // PM stays in openProjects but is marked as background
        #expect(registry.openProjects[canonical] != nil)
        #expect(registry.backgroundProjects.contains(canonical))
    }

    @Test func closeWindowAndReopenReturnsSameInstance() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        registry.closeProjectWindow(tempDir)
        let pm2 = registry.projectManager(for: tempDir)

        #expect(pm1 != nil)
        #expect(pm2 != nil)
        #expect(pm1 === pm2)
    }

    @Test func taskHistoryIsProjectIsolatedAcrossCloseAndReopen() throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }

        let registry = ProjectRegistry()
        let first = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let second = try #require(
            registry.projectManager(for: secondDirectory)
        )
        let firstRun = first.taskRunStore.start(makeTaskRun(id: "first"))
        let secondRun = second.taskRunStore.start(makeTaskRun(id: "second"))

        first.taskRunStore.finishRun(
            id: firstRun.id,
            outcome: makeTaskOutcome(id: "first"),
            cancelled: false
        )
        #expect(firstRun.state == .succeeded)
        #expect(secondRun.state == .pending)
        #expect(first.taskRunStore.runs.map(\.taskID) == ["first"])
        #expect(second.taskRunStore.runs.map(\.taskID) == ["second"])

        registry.closeProjectWindow(firstDirectory)
        #expect(!registry.isWindowOpen(firstDirectory))
        #expect(first.taskRunStore.run(forID: firstRun.id) === firstRun)

        let reopened = try #require(
            registry.projectManager(for: firstDirectory)
        )
        #expect(reopened === first)
        #expect(reopened.taskRunStore.run(forID: firstRun.id) === firstRun)
        #expect(second.taskRunStore.run(forID: secondRun.id) === secondRun)
    }

    @Test func deletedBackgroundProjectCompletesTaskCleanup() async throws {
        let tempDir = try makeTempDirectory()
        let canonicalBeforeDeletion =
            ProjectRegistry.canonicalProjectURL(tempDir)
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: tempDir))
        let run = project.taskRunStore.start(makeTaskRun(id: "deleted"))
        let probe = ProjectTaskCancellationProbe()
        project.taskRunStore.registerCancellation(
            UserTaskCancellation(
                terminate: {
                    probe.recordCancellation()
                    return true
                },
                waitForCompletion: { _ in
                    probe.recordWait()
                    return true
                }
            ),
            forRunID: run.id
        )

        registry.closeProjectWindow(tempDir)
        cleanup(tempDir)
        #expect(
            ProjectRegistry.canonicalProjectURL(tempDir)
                == canonicalBeforeDeletion
        )
        #expect(registry.projectManager(for: tempDir) == nil)
        #expect(registry.detachedUserTaskCleanupCount == 1)

        for _ in 0..<200 where project.hasOutstandingUserTaskExecution {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(!project.hasOutstandingUserTaskExecution)
        #expect(project.taskRunStore.runs.isEmpty)
        #expect(!registry.isProjectOpen(tempDir))
        #expect(registry.detachedUserTaskCleanupCount == 0)
    }

    @Test func deletedProjectTimeoutRetainsCleanupOwnerForQuit() async throws {
        let tempDir = try makeTempDirectory()
        let canonicalBeforeDeletion =
            ProjectRegistry.canonicalProjectURL(tempDir)
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: tempDir))
        let run = project.taskRunStore.start(makeTaskRun(id: "slow-delete"))
        let probe = ProjectTaskCancellationProbe(waitResult: false)
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )

        registry.closeProjectWindow(tempDir)
        cleanup(tempDir)
        #expect(
            ProjectRegistry.canonicalProjectURL(tempDir)
                == canonicalBeforeDeletion
        )
        #expect(registry.projectManager(for: tempDir) == nil)
        for _ in 0..<200 where probe.waitCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(project.hasOutstandingUserTaskExecution)
        #expect(registry.detachedUserTaskCleanupCount == 1)
        let didShutdown = await registry.shutdownUserTasks(until: .now())
        #expect(!didShutdown)
        #expect(!registry.destroyAllProjects())

        project.taskRunStore.finishRun(
            id: run.id,
            outcome: makeTaskOutcome(id: "slow-delete"),
            cancelled: true
        )
        #expect(registry.destroyAllProjects())
    }

    // MARK: - Recent projects

    @Test func recentProjectsAddedOnOpen() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.recentProjects.contains(canonical))
        #expect(registry.recentProjects.first == canonical)
    }

    @Test func recentProjectsLimitedToMax() throws {
        var dirs: [URL] = []
        for _ in 0..<12 {
            dirs.append(try makeTempDirectory())
        }
        defer { dirs.forEach { cleanup($0) } }

        let registry = ProjectRegistry()
        for dir in dirs {
            _ = registry.projectManager(for: dir)
        }

        #expect(registry.recentProjects.count <= 10)

        // Most recent should be last opened
        let lastCanonical = try #require(dirs.last).resolvingSymlinksInPath()
        #expect(registry.recentProjects.first == lastCanonical)

        // First two should have been pushed out
        let firstCanonical = dirs[0].resolvingSymlinksInPath()
        let secondCanonical = dirs[1].resolvingSymlinksInPath()
        #expect(!registry.recentProjects.contains(firstCanonical))
        #expect(!registry.recentProjects.contains(secondCanonical))
    }

    @Test func recentProjectsNotRemovedOnClose() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        registry.closeProject(tempDir)

        // Close keeps PM in openProjects (as background) and in recentProjects
        #expect(registry.openProjects[canonical] != nil)
        #expect(registry.recentProjects.contains(canonical))
    }

    // MARK: - isProjectOpen

    @Test func closeWindowPreservesProjectManager() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm = registry.projectManager(for: tempDir)
        let canonical = tempDir.resolvingSymlinksInPath()

        registry.closeProjectWindow(tempDir)

        // PM is still in openProjects
        #expect(registry.openProjects[canonical] === pm)
    }

    @Test func closeWindowMarksAsBackground() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)
        let canonical = tempDir.resolvingSymlinksInPath()

        #expect(!registry.backgroundProjects.contains(canonical))

        registry.closeProjectWindow(tempDir)
        #expect(registry.backgroundProjects.contains(canonical))
    }

    @Test func reopenRemovesFromBackground() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)
        let canonical = tempDir.resolvingSymlinksInPath()

        registry.closeProjectWindow(tempDir)
        #expect(registry.backgroundProjects.contains(canonical))

        _ = registry.projectManager(for: tempDir)
        #expect(!registry.backgroundProjects.contains(canonical))
    }

    @Test func isWindowOpenReflectsState() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        #expect(!registry.isWindowOpen(tempDir))

        _ = registry.projectManager(for: tempDir)
        #expect(registry.isWindowOpen(tempDir))

        registry.closeProjectWindow(tempDir)
        #expect(!registry.isWindowOpen(tempDir))

        // Reopen — window open again
        _ = registry.projectManager(for: tempDir)
        #expect(registry.isWindowOpen(tempDir))
    }

    // MARK: - isProjectOpen

    @Test func isProjectOpenReflectsState() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        #expect(!registry.isProjectOpen(tempDir))

        _ = registry.projectManager(for: tempDir)
        #expect(registry.isProjectOpen(tempDir))

        // After closing, project is still "open" (background), use isWindowOpen for window state
        registry.closeProject(tempDir)
        #expect(registry.isProjectOpen(tempDir))
        #expect(!registry.isWindowOpen(tempDir))
    }

    private func makeTaskRun(id: String) -> UserTaskRun {
        UserTaskRun(
            taskID: id,
            taskLabel: id,
            command: "printf done",
            replacesFileContent: false
        )
    }

    private func makeTaskOutcome(id: String) -> UserTaskOutcome {
        UserTaskOutcome(
            taskID: id,
            stdout: "done",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }
}

nonisolated private final class ProjectTaskCancellationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private let waitResult: Bool
    private var cancellations = 0
    private var waits = 0

    init(waitResult: Bool = true) {
        self.waitResult = waitResult
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    var waitCount: Int {
        lock.withLock { waits }
    }

    func recordCancellation() {
        lock.withLock {
            cancellations += 1
        }
    }

    func recordWait() {
        lock.withLock {
            waits += 1
        }
    }

    func makeCancellation() -> UserTaskCancellation {
        UserTaskCancellation(
            terminate: { [self] in
                recordCancellation()
                return true
            },
            waitForCompletion: { [self] _ in
                recordWait()
                return waitResult
            }
        )
    }
}
