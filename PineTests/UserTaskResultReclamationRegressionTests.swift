import Foundation
import Testing

@testable import Pine

/// Runtime scenario uses base APIs; the identity-derivation helper is candidate-only cleanup support.
@Suite("Command result reclamation regression", .serialized)
@MainActor
struct UserTaskResultReclamationRegressionTests {
    @Test("completed result survives actual manager reclamation without a shell")
    func completedResultIsNotJustManagerMemory() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Pine-1784-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resultFiles = defaultResultFiles(forRoot: root)
        defer { resultFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let registry = ProjectRegistry(
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionInitialPollDelay: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        try #require(await original.taskRunStore.flushResultPersistence())
        let run = original.taskRunStore.start(UserTaskRun(
            taskID: "controlled-result", taskLabel: "Controlled result",
            command: "printf controlled-result", replacesFileContent: false
        ))
        registry.closeProjectWindow(root)
        original.taskRunStore.finishRun(
            id: run.id,
            outcome: UserTaskOutcome(
                taskID: run.taskID, stdout: "not-retained-by-default", stderr: "",
                exitCode: 3, timedOut: false
            ),
            cancelled: false
        )
        let canonical = registry.canonicalProjectURL(root)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects[canonical] == nil
        })
        #expect(original.presentationLifecycle == .destroyed)
        #expect(original.paneManager.allTerminalTabs.isEmpty)
        let reopened = try #require(registry.projectManager(for: root))
        #expect(reopened !== original)
        #expect(await waitUntilMainActor { reopened.taskRunStore.run(forID: run.id) != nil })
        #expect(reopened.taskRunStore.run(forID: run.id)?.state == .failed)
        #expect(reopened.taskRunStore.run(forID: run.id)?.exitCode == 3)
        #expect(reopened.taskRunStore.run(forID: run.id)?.stdout.isEmpty == true)
    }

    /// The default-persistence result file and lock for this root, keyed the
    /// same way production derives the workspace identity (path+device+inode).
    private func defaultResultFiles(forRoot root: URL) -> [URL] {
        let canonical = root.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(canonical.path, &info) == 0 else { return [] }
        let identity = UserTaskResultRecord.identity(
            "\(canonical.path)\0\(info.st_dev)\0\(info.st_ino)"
        )
        let file = PineStorageContext.applicationSupportDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Pine/CommandResults")
            .appendingPathComponent(identity + ".json")
        return [file, file.deletingPathExtension().appendingPathExtension("lock")]
    }
}
