//
//  ProcessTreeCaptureSchedulingTests.swift
//  Pine
//

import Darwin
import Foundation
import Testing

@testable import Pine

/// Regression coverage for the shared capture wave introduced for #1718.
///
/// The wave must keep delivering per-terminal captures on its 25 ms cadence,
/// a bounded TERM-to-KILL teardown of one terminal must not starve the
/// captures of the others, and teardown discovery must still catch
/// short-lived descendants that left the shell's process group.
@Suite("Process Tree Capture Scheduling", .serialized)
struct ProcessTreeCaptureSchedulingTests {
    nonisolated private enum FixtureError: Error {
        case spawnFailed(Int32)
        case controllerUnavailable
    }

    nonisolated private struct WorkloadTerminal {
        let directory: URL
        let rootProcessID: pid_t
        let retention: TerminalWorkingDirectoryRetention
        let controller: TerminalProcessTreeController
    }

    @Test("the shared wave captures every registered controller")
    func sharedWaveCapturesEveryRegisteredController() async throws {
        let first = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(first) }
        let second = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(second) }

        // The wave period is 25 ms; at least two captures per controller in
        // 500 ms keeps the check robust on a loaded machine.
        try await Task.sleep(for: .milliseconds(500))
        let firstCount = await captureCount(first.controller)
        let secondCount = await captureCount(second.controller)
        #expect(firstCount >= 2, "first controller was captured \(firstCount) times in 500 ms")
        #expect(secondCount >= 2, "second controller was captured \(secondCount) times in 500 ms")

        #expect(await terminate(first))
        #expect(await terminate(second))
    }

    @Test("terminating one terminal does not starve the shared wave")
    func teardownDoesNotStarveOtherTerminals() async throws {
        let active = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(active) }
        // A TERM-ignoring root forces the bounded cleanup through the KILL
        // escalation, keeping this controller's teardown queue busy for well
        // over a second while the other terminal must keep being captured.
        let stubborn = try makeWorkloadController(
            script: "trap \"\" TERM; while :; do sleep 1; done"
        )
        defer { cleanup(stubborn) }

        try await Task.sleep(for: .milliseconds(300))
        let baseline = await captureCount(active.controller)

        // The TERM-ignoring root cannot leave the bounded sequence before the
        // fixed 250 ms TERM grace period, so a sample 150 ms into teardown is
        // guaranteed to land inside it.
        stubborn.controller.requestTermination()
        try await Task.sleep(for: .milliseconds(150))
        let duringTeardown = await captureCount(active.controller)
        #expect(
            duringTeardown - baseline >= 2,
            "active controller only captured \(duringTeardown) times (baseline \(baseline)) while stubborn teardown was running"
        )

        let finished = await Task.detached(priority: .utility) {
            stubborn.controller.waitForTermination(timeout: 8)
        }.value
        #expect(finished, "stubborn teardown did not finish within 8 s")
        try await Task.sleep(for: .milliseconds(300))
        let afterTeardown = await captureCount(active.controller)
        #expect(afterTeardown - duringTeardown >= 2, "active controller capture count stopped at \(afterTeardown)")

        #expect(await terminate(active))
    }

    @Test("bounded teardown still kills a late off-group descendant")
    func teardownCatchesLateOffGroupDescendant() async throws {
        let pidFileURL = FileManager.default.temporaryDirectory.appending(
            path: "pine-process-tree-scheduling-\(UUID().uuidString).pid"
        )
        let terminal = try makeWorkloadController(
            script: """
            /usr/bin/perl -MPOSIX -e 'POSIX::setpgid(0, 0) or die; exec "/bin/sleep", 60' &
            printf '%s\\n' "$!" > "$1"
            exec /bin/sleep 60
            """,
            extraArguments: [pidFileURL.path]
        )
        defer { cleanup(terminal) }
        let descendantProcessID = try #require(
            await readProcessID(from: pidFileURL)
        )
        let descendant = try #require(
            UserTaskProcessInspector.identity(for: descendantProcessID)
        )
        // Pins the off-group cleanup contract: a descendant that left the
        // shell's process group is still terminated by the bounded teardown
        // (process-group signalling alone would not reach it). Wave/final-
        // capture ordering is pinned separately by
        // noScheduledCapturesAfterTermination.
        try await Task.sleep(for: .milliseconds(200))
        let rootStillLive = UserTaskProcessInspector.identity(
            for: terminal.rootProcessID
        ) != nil
        let descendantStillLive = UserTaskProcessInspector.identity(
            for: descendantProcessID
        ) == descendant
        #expect(
            await terminate(terminal),
            "off-group teardown failed; rootLive=\(rootStillLive) descendantLive=\(descendantStillLive)"
        )
        #expect(UserTaskProcessInspector.identity(
            for: descendantProcessID
        ) != descendant)
    }

    @Test("no scheduled captures run after termination completes")
    func noScheduledCapturesAfterTermination() async throws {
        let terminal = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(terminal) }
        try await Task.sleep(for: .milliseconds(300))

        #expect(await terminate(terminal))
        let settled = await captureCount(terminal.controller)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await captureCount(terminal.controller) == settled)
    }

    @Test("the shared wave stops when the registry empties and resumes on re-registration")
    func waveStopsWhenIdleAndResumesOnRegistration() async throws {
        #if DEBUG
        let terminal = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(terminal) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(TerminalProcessTreeCaptureScheduler.waveCountForTesting > 0)

        #expect(await terminate(terminal))
        // The teardown prologue removes the last controller and stops the
        // wave timer. A concurrent suite may register its own controller, in
        // which case ticks are legitimate and the stop half is not
        // observable; only assert when the scheduler is demonstrably idle.
        try await Task.sleep(for: .milliseconds(100))
        guard TerminalProcessTreeCaptureScheduler.isIdleForTesting else {
            print("1718: wave-stop half skipped: concurrent registration active")
            return
        }
        let idleCount = TerminalProcessTreeCaptureScheduler.waveCountForTesting
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            TerminalProcessTreeCaptureScheduler.waveCountForTesting == idleCount,
            "wave kept ticking after the registry emptied"
        )

        // Re-registration must re-arm the wave timer.
        let resumed = try makeWorkloadController(
            script: "sleep 60 & sleep 60 & wait"
        )
        defer { cleanup(resumed) }
        let resumedCount = TerminalProcessTreeCaptureScheduler.waveCountForTesting
        try await Task.sleep(for: .milliseconds(500))
        #expect(
            TerminalProcessTreeCaptureScheduler.waveCountForTesting > resumedCount,
            "wave did not resume after re-registration"
        )
        #expect(await captureCount(resumed.controller) >= 2)
        #expect(await terminate(resumed))
        #endif
    }

    private var terminalPIDFileURL: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "pine-process-tree-scheduling-\(UUID().uuidString).pid"
        )
    }

    private func cleanup(_ terminal: WorkloadTerminal) {
        // Best-effort and idempotent (guarded by `terminationRequested`): an
        // aborted test must not leak its workload shell to launchd.
        terminal.controller.requestTermination()
        terminal.retention.finishCleanup(succeeded: true)
        try? FileManager.default.removeItem(at: terminal.directory)
    }

    private func terminate(
        _ terminal: WorkloadTerminal,
        timeout: TimeInterval = 5
    ) async -> Bool {
        terminal.controller.requestTermination()
        return await Task.detached(priority: .utility) {
            terminal.controller.waitForTermination(timeout: timeout)
        }.value
    }

    private func captureCount(
        _ controller: TerminalProcessTreeController
    ) async -> UInt64 {
        #if DEBUG
        await Task.detached(priority: .utility) {
            controller.scheduledCaptureCountForTesting
        }.value
        #else
        0
        #endif
    }

    private func makeWorkloadController(
        script: String,
        extraArguments: [String] = []
    ) throws -> WorkloadTerminal {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pine-process-tree-scheduling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let scriptURL = directory.appending(path: "workload.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let pid = try Self.spawnShell(
            arguments: [scriptURL.path] + extraArguments
        )
        let retention = TerminalWorkingDirectoryRetention(
            canonicalDirectory: directory
        )
        guard let controller = TerminalProcessTreeController(
            rootProcessID: pid,
            retention: retention
        ) else {
            Self.reapOrKill(pid)
            throw FixtureError.controllerUnavailable
        }
        return WorkloadTerminal(
            directory: directory,
            rootProcessID: pid,
            retention: retention,
            controller: controller
        )
    }

    private func readProcessID(
        from url: URL,
        timeout: TimeInterval = 2
    ) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = pid_t(trimmed), value > 1 {
                    return value
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    nonisolated private static func spawnShell(
        arguments: [String]
    ) throws -> pid_t {
        let devnull = open("/dev/null", O_RDWR)
        guard devnull >= 0 else {
            throw FixtureError.spawnFailed(Int32(errno))
        }
        defer { close(devnull) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw FixtureError.spawnFailed(Int32(errno))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // The controller requires its root to lead its own process group,
        // matching the `forkpty` session/group-leader invariant. On macOS the
        // SETPGROUP flag must be set explicitly; `setpgroup` alone leaves
        // the child in the parent's group.
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw FixtureError.spawnFailed(Int32(errno))
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw FixtureError.spawnFailed(Int32(errno))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(&fileActions, 0, devnull) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, 1, devnull) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, 2, devnull) == 0
        else {
            throw FixtureError.spawnFailed(Int32(errno))
        }

        let command = ["/bin/sh"] + arguments
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in argumentPointers {
                free(pointer)
            }
        }
        for argument in command {
            guard let pointer = argument.withCString({ strdup($0) }) else {
                throw FixtureError.spawnFailed(Int32(ENOMEM))
            }
            argumentPointers.append(pointer)
        }
        argumentPointers.append(nil)
        var pid: pid_t = 0
        let result = argumentPointers.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &pid,
                "/bin/sh",
                &fileActions,
                &attributes,
                buffer.baseAddress,
                nil
            )
        }
        guard result == 0 else {
            throw FixtureError.spawnFailed(Int32(result))
        }
        return pid
    }

    nonisolated private static func reapOrKill(_ pid: pid_t) {
        var status: Int32 = 0
        let reaped = Darwin.waitpid(pid, &status, WNOHANG)
        if reaped != pid {
            Darwin.kill(pid, SIGKILL)
            _ = Darwin.waitpid(pid, &status, 0)
        }
    }
}
