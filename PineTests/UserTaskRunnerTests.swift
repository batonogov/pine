//
//  UserTaskRunnerTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("User task runner", .serialized, .timeLimit(.minutes(1)))
nonisolated struct UserTaskRunnerTests {
    @Test("Execution arbiter accepts pre-spawn cancel and rejects late cancel")
    func executionStateLifecycle() {
        let preSpawn = UserTaskExecutionState()
        #expect(preSpawn.requestCancellation())
        #expect(preSpawn.terminalCause == .cancelled)
        #expect(!preSpawn.requestCancellation())
        preSpawn.complete()
        #expect(preSpawn.waitForCompletion(until: .now() + 1))

        let completed = UserTaskExecutionState()
        #expect(completed.claimNaturalExit())
        completed.complete(cleanupSucceeded: false)
        #expect(!completed.requestCancellation())
        #expect(completed.terminalCause == .naturalExit)
        #expect(!completed.waitForCompletion(until: .now() + 1))
    }

    @Test("Concurrent cancel and natural exit select one lifecycle winner")
    func executionStateRace() {
        for _ in 0..<250 {
            let state = UserTaskExecutionState()
            let result = CancellationRaceResult()

            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    result.recordCancel(state.requestCancellation())
                } else {
                    result.recordFinish(state.claimNaturalExit())
                }
            }

            #expect(result.cancelAccepted != result.finishAccepted)
            let expectedCause: UserTaskTerminalCause =
                result.cancelAccepted == true ? .cancelled : .naturalExit
            #expect(state.terminalCause == expectedCause)
            state.complete()
        }
    }

    @Test("Subprocess owns its process group and reaps the direct shell")
    func subprocessGroupAndReaping() throws {
        let subprocess = try UserTaskSubprocess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            command: "while :; do :; done",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let processID = subprocess.processGroup.identifier
        #expect(Darwin.getpgid(processID) == processID)

        subprocess.standardInput.closeFile()
        subprocess.processGroup.requestTermination()
        let exitCode = subprocess.waitForExit()
        #expect(exitCode == SIGTERM || exitCode == SIGKILL)
        #expect(subprocess.processGroup.waitForRequestedTermination())

        var status: Int32 = 0
        errno = 0
        #expect(Darwin.waitpid(processID, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("Pipe reader stop is bounded while a writer remains open")
    func pipeReaderStopIsBounded() {
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        defer { writeHandle.closeFile() }
        let stopState = UserTaskIOStopState()
        let capture = UserTaskOutputCapture()
        let finished = DispatchGroup()

        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.leave() }
            capture.setStdout(
                UserTaskPipeReader.read(
                    from: readHandle,
                    stopState: stopState
                )
            )
        }
        stopState.stop()

        #expect(finished.wait(timeout: .now() + 0.5) == .success)
        #expect(!capture.snapshot().stdout.reachedEndOfFile)
    }

    @Test("Successful replacement task receives stdin and captures stdout")
    func successfulRun() async {
        let runner = UserTaskRunner(timeout: 2)
        let task = UserTask(
            id: "success",
            label: "Success",
            command: "printf 'formatted:'; cat",
            replacesFileContent: true
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("input.txt")
        let probe = start(
            runner: runner,
            task: task,
            fileURL: fileURL,
            fileContent: "source"
        )

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome == UserTaskOutcome(
            taskID: "success",
            stdout: "formatted:source",
            stderr: "",
            exitCode: 0,
            timedOut: false
        ))
        #expect(!completion.cancelled)
        #expect(probe.didStart)
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Non-zero exit preserves partial stdout and stderr")
    func nonZeroExit() async {
        let runner = UserTaskRunner(timeout: 2)
        let task = UserTask(
            id: "nonzero",
            label: "Non-zero",
            command: "printf 'partial'; printf 'failure' >&2; exit 7"
        )
        let probe = start(runner: runner, task: task)

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.taskID == "nonzero")
        #expect(completion.outcome.stdout == "partial")
        #expect(completion.outcome.stderr == "failure")
        #expect(completion.outcome.exitCode == 7)
        #expect(!completion.outcome.timedOut)
        #expect(!completion.outcome.succeeded)
        #expect(!completion.cancelled)
        #expect(probe.didStart)
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Invalid UTF-8 output fails closed")
    func invalidUTF8Output() async {
        let runner = UserTaskRunner(timeout: 2)
        let task = UserTask(
            id: "invalid-utf8",
            label: "Invalid UTF-8",
            command: "/usr/bin/printf '\\377'"
        )
        let probe = start(runner: runner, task: task)

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.stdout.isEmpty)
        #expect(completion.outcome.exitCode == -1)
        #expect(
            completion.outcome.stderr.contains(
                Strings.userTaskDiagnosticInvalidUTF8
            )
        )
        #expect(!completion.outcome.succeeded)
    }

    @Test("Timeout terminates the process and is distinct from cancellation")
    func timeout() async {
        let runner = UserTaskRunner(timeout: 0.05)
        let task = UserTask(
            id: "timeout",
            label: "Timeout",
            command: "while :; do :; done"
        )
        let probe = start(runner: runner, task: task)

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.taskID == "timeout")
        #expect(completion.outcome.timedOut)
        #expect(completion.outcome.exitCode != 0)
        #expect(!completion.outcome.succeeded)
        #expect(!completion.cancelled)
        #expect(probe.didStart)
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Spawn failure reports exit -1 without a start callback")
    func spawnFailure() async {
        let missingShell = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-pine-shell-\(UUID().uuidString)")
        let runner = UserTaskRunner(
            timeout: 2,
            shellExecutableURL: missingShell
        )
        let task = UserTask(
            id: "spawn",
            label: "Spawn",
            command: "printf 'unreachable'"
        )
        let probe = start(runner: runner, task: task)

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.taskID == "spawn")
        #expect(completion.outcome.stdout.isEmpty)
        #expect(!completion.outcome.stderr.isEmpty)
        #expect(completion.outcome.exitCode == -1)
        #expect(!completion.outcome.timedOut)
        #expect(!completion.cancelled)
        #expect(!probe.didStart)
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Validator rejection publishes ready then finish exactly once")
    func validatorCallbackOrdering() async {
        let task = UserTask(
            id: "blocked",
            label: "Blocked",
            command: "rm -rf /"
        )
        let probe = start(
            runner: UserTaskRunner(timeout: 2),
            task: task
        )

        let completion = await probe.waitForCompletion()

        #expect(!completion.outcome.succeeded)
        #expect(!probe.didStart)
        #expect(probe.callbackEvents == ["cancellation", "finish"])
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Cancellation terminates an active process without reporting timeout")
    func cancellation() async {
        let runner = UserTaskRunner(timeout: 5)
        let task = UserTask(
            id: "cancel",
            label: "Cancel",
            command: "while :; do :; done"
        )
        let probe = start(runner: runner, task: task)

        let cancellation = await probe.waitForCancellation()
        await probe.waitForStart()
        cancellation.cancel()
        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.taskID == "cancel")
        #expect(cancellation.wait(until: .now() + 1))
        #expect(completion.outcome.exitCode != 0)
        #expect(!completion.outcome.timedOut)
        #expect(!completion.outcome.succeeded)
        #expect(completion.cancelled)
        #expect(probe.didStart)
        #expect(probe.callbacksWereOnMainThread)
    }

    @Test("Cancellation wins before timeout even when TERM is ignored")
    func cancellationWinsBeforeTimeout() async {
        let runner = UserTaskRunner(timeout: 0.5)
        let task = UserTask(
            id: "cancel-before-timeout",
            label: "Cancel Before Timeout",
            command: "trap '' TERM; while :; do :; done"
        )
        let probe = start(runner: runner, task: task)
        let cancellation = await probe.waitForCancellation()
        await probe.waitForStart()

        #expect(cancellation.cancel())
        #expect(!cancellation.cancel())
        let completion = await probe.waitForCompletion()

        #expect(completion.cancelled)
        #expect(!completion.outcome.timedOut)
    }

    @Test("Timeout wins before a late cancellation")
    func timeoutWinsBeforeCancellation() async {
        let runner = UserTaskRunner(timeout: 0.05)
        let task = UserTask(
            id: "timeout-before-cancel",
            label: "Timeout Before Cancel",
            command: "trap '' TERM; while :; do :; done"
        )
        let probe = start(runner: runner, task: task)
        let cancellation = await probe.waitForCancellation()
        await probe.waitForStart()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(!cancellation.cancel())
        let completion = await probe.waitForCompletion()

        #expect(!completion.cancelled)
        #expect(completion.outcome.timedOut)
    }

    @Test("Natural, cancelled, and timed-out shells are reaped")
    func directShellsAreReaped() async {
        let cases: [(id: String, timeout: TimeInterval, cancel: Bool)] = [
            ("natural-reap", 2, false),
            ("cancel-reap", 2, true),
            ("timeout-reap", 0.05, false),
        ]

        for testCase in cases {
            let processIDURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "pine-task-\(testCase.id)-\(UUID().uuidString)"
                )
            let body = testCase.id == "natural-reap"
                ? "/bin/sleep 0.1"
                : "trap '' TERM; while :; do :; done"
            let command = """
            /usr/bin/printf '%s' "$$" > \(shellQuote(processIDURL.path))
            \(body)
            """
            let probe = start(
                runner: UserTaskRunner(timeout: testCase.timeout),
                task: UserTask(
                    id: testCase.id,
                    label: testCase.id,
                    command: command
                )
            )
            let cancellation = await probe.waitForCancellation()
            await probe.waitForStart()
            guard let processID = await waitForProcessID(
                at: processIDURL
            ), let identity = UserTaskProcessInspector.identity(
                for: processID
            ) else {
                Issue.record("Task did not publish a live direct-shell pid")
                try? FileManager.default.removeItem(at: processIDURL)
                continue
            }
            if testCase.cancel {
                #expect(cancellation.cancel())
            }

            _ = await probe.waitForCompletion()

            #expect(
                UserTaskProcessInspector.identity(for: processID) != identity
            )
            terminateIfStillCurrent(identity)
            try? FileManager.default.removeItem(at: processIDURL)
        }
    }

    @Test("CLOEXEC default rejects an ambient descriptor")
    func ambientDescriptorIsNotInherited() async {
        let sentinel = Pipe()
        let descriptor = sentinel.fileHandleForReading.fileDescriptor
        defer {
            sentinel.fileHandleForReading.closeFile()
            sentinel.fileHandleForWriting.closeFile()
        }
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        #expect(descriptorFlags != -1)
        #expect(
            Darwin.fcntl(
                descriptor,
                F_SETFD,
                descriptorFlags & ~FD_CLOEXEC
            ) != -1
        )
        let task = UserTask(
            id: "fd-inheritance",
            label: "FD Inheritance",
            command: """
            if [ -e /dev/fd/\(descriptor) ]; then exit 91; else exit 0; fi
            """
        )
        let probe = start(
            runner: UserTaskRunner(timeout: 2),
            task: task
        )

        let completion = await probe.waitForCompletion()

        #expect(completion.outcome.succeeded)
    }

    @Test("Concurrent task spawn does not delay another task's pipe EOF")
    func concurrentRunsDoNotCrossInheritPipes() async {
        let runner = UserTaskRunner(timeout: 3)
        let quick = UserTask(
            id: "quick",
            label: "Quick",
            command: "printf quick; /bin/sleep 0.1"
        )
        let slow = UserTask(
            id: "slow",
            label: "Slow",
            command: "/bin/sleep 1"
        )
        let clock = ContinuousClock()
        let startTime = clock.now
        let quickProbe = start(runner: runner, task: quick)
        let slowProbe = start(runner: runner, task: slow)

        let quickCompletion = await quickProbe.waitForCompletion()
        let quickElapsed = startTime.duration(to: clock.now)
        let slowCompletion = await slowProbe.waitForCompletion()

        #expect(quickCompletion.outcome.succeeded)
        #expect(quickCompletion.outcome.stdout == "quick")
        #expect(quickElapsed < .milliseconds(700))
        #expect(slowCompletion.outcome.succeeded)
    }

    @Test("Output capture accepts the exact limit and rejects one byte more")
    func outputCaptureBoundaries() async {
        let limit = UserTaskPipeReader.maximumCapturedBytes
        let exactTask = UserTask(
            id: "exact-output",
            label: "Exact Output",
            command: "/usr/bin/perl -e 'print \"x\" x \(limit)'"
        )
        let overflowTask = UserTask(
            id: "overflow-output",
            label: "Overflow Output",
            command: "/usr/bin/perl -e 'print \"x\" x \(limit + 1)'"
        )

        let exact = await start(
            runner: UserTaskRunner(timeout: 5),
            task: exactTask
        ).waitForCompletion()
        let overflow = await start(
            runner: UserTaskRunner(timeout: 5),
            task: overflowTask
        ).waitForCompletion()

        #expect(exact.outcome.succeeded)
        #expect(exact.outcome.stdout.utf8.count == limit)
        #expect(!overflow.outcome.succeeded)
        #expect(overflow.outcome.exitCode == -1)
        #expect(overflow.outcome.stdout.utf8.count == limit)
    }

    @Test("Large stdout and stderr drain concurrently")
    func largeOutputOnBothStreams() async {
        let byteCount = 1_024 * 1_024
        let task = UserTask(
            id: "dual-output",
            label: "Dual Output",
            command: """
            /usr/bin/perl -e \
            'print STDOUT "o" x \(byteCount); print STDERR "e" x \(byteCount)'
            """
        )
        let completion = await start(
            runner: UserTaskRunner(timeout: 5),
            task: task
        ).waitForCompletion()

        #expect(completion.outcome.succeeded)
        #expect(completion.outcome.stdout.utf8.count == byteCount)
        #expect(completion.outcome.stderr.utf8.count == byteCount)
    }

    @Test("Replacement fails when child closes stdin early")
    func incompleteStandardInputFailsClosed() async {
        let task = UserTask(
            id: "stdin-epipe",
            label: "Stdin EPIPE",
            command: "exit 0",
            replacesFileContent: true
        )
        let completion = await start(
            runner: UserTaskRunner(timeout: 3),
            task: task,
            fileURL: URL(fileURLWithPath: "/tmp/input.txt"),
            fileContent: String(repeating: "x", count: 2 * 1_024 * 1_024)
        ).waitForCompletion()

        #expect(!completion.outcome.standardInputCompleted)
        #expect(!completion.outcome.succeeded)
        #expect(completion.outcome.exitCode == -1)
    }

    @Test("libproc empty and saturated snapshots require fallback")
    func libprocUnknownAndSaturation() {
        #expect(!UserTaskProcessInspector.groupCountsAreComplete(
            requestedCount: 0,
            returnedCount: 0,
            capacity: 16
        ))
        #expect(!UserTaskProcessInspector.groupCountsAreComplete(
            requestedCount: 16,
            returnedCount: 16,
            capacity: 16
        ))
        #expect(!UserTaskProcessInspector.groupCountsAreComplete(
            requestedCount: 1,
            returnedCount: 16,
            capacity: 16
        ))
        #expect(UserTaskProcessInspector.groupCountsAreComplete(
            requestedCount: 1,
            returnedCount: 1,
            capacity: 16
        ))
    }

    @Test("Cancellation terminates a shell descendant before completion")
    func cancellationTerminatesDescendant() async {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-task-child-\(UUID().uuidString)")
        var childIdentity: UserTaskProcessIdentity?
        defer {
            terminateIfStillCurrent(childIdentity)
            try? FileManager.default.removeItem(at: childPIDURL)
        }
        let command = """
        /bin/sh -c 'trap "" HUP TERM; exec /bin/sleep 30' &
        child=$!
        /usr/bin/printf '%s' "$child" > \(shellQuote(childPIDURL.path))
        wait "$child"
        """
        let runner = UserTaskRunner(timeout: 5)
        let task = UserTask(
            id: "cancel-child",
            label: "Cancel Child",
            command: command
        )
        let probe = start(runner: runner, task: task)

        let cancellation = await probe.waitForCancellation()
        await probe.waitForStart()
        let childProcessID = await waitForProcessID(at: childPIDURL)
        childIdentity = childProcessID.flatMap {
            UserTaskProcessInspector.identity(for: $0)
        }
        cancellation.cancel()
        let completion = await probe.waitForCompletion()

        #expect(completion.cancelled)
        #expect(!completion.outcome.timedOut)
        if let childProcessID {
            #expect(await waitForProcessExit(childProcessID))
        } else {
            Issue.record("Task did not publish its descendant pid")
        }
    }

    @Test("Successful shell exit cleans a background descendant")
    func successfulExitCleansBackgroundDescendant() async {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-task-background-\(UUID().uuidString)")
        var childIdentity: UserTaskProcessIdentity?
        defer {
            terminateIfStillCurrent(childIdentity)
            try? FileManager.default.removeItem(at: childPIDURL)
        }
        let command = """
        /bin/sh -c 'trap "" HUP TERM; exec /bin/sleep 30' &
        child=$!
        /usr/bin/printf '%s' "$child" > \(shellQuote(childPIDURL.path))
        """
        let runner = UserTaskRunner(timeout: 5)
        let task = UserTask(
            id: "background-child",
            label: "Background Child",
            command: command
        )
        let probe = start(runner: runner, task: task)

        let completion = await probe.waitForCompletion()
        let childProcessID = await waitForProcessID(at: childPIDURL)
        childIdentity = childProcessID.flatMap {
            UserTaskProcessInspector.identity(for: $0)
        }

        #expect(completion.outcome.succeeded)
        #expect(!completion.cancelled)
        if let childProcessID {
            #expect(await waitForProcessExit(childProcessID))
        } else {
            Issue.record("Task did not publish its background child pid")
        }
    }

    @Test("Escaped descendant cannot hold output pipes open indefinitely")
    func escapedDescendantHasBoundedCleanup() async {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-task-escaped-\(UUID().uuidString)")
        var childProcessID: pid_t?
        var childIdentity: UserTaskProcessIdentity?
        defer {
            terminateIfStillCurrent(childIdentity)
            try? FileManager.default.removeItem(at: childPIDURL)
        }
        let command = """
        /usr/bin/perl -MPOSIX=setsid -e '
            my $path = shift;
            setsid() >= 0 or die "setsid";
            open my $file, ">", $path or die "pid file";
            print {$file} $$;
            close $file;
            $SIG{HUP} = "IGNORE";
            $SIG{TERM} = "IGNORE";
            exec "/bin/sleep", "30";
        ' \(shellQuote(childPIDURL.path)) &
        /bin/sleep 0.3
        """
        let runner = UserTaskRunner(timeout: 5)
        let task = UserTask(
            id: "escaped-child",
            label: "Escaped Child",
            command: command
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let probe = start(runner: runner, task: task)

        childProcessID = await waitForProcessID(at: childPIDURL)
        childIdentity = childProcessID.flatMap {
            UserTaskProcessInspector.identity(for: $0)
        }
        if let childProcessID {
            #expect(Darwin.getpgid(childProcessID) == childProcessID)
        } else {
            Issue.record("Task did not publish its escaped descendant pid")
        }

        let completion = await probe.waitForCompletion()
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(3))
        #expect(completion.outcome.succeeded)
        #expect(!completion.cancelled)
        if let childProcessID {
            #expect(await waitForProcessExit(childProcessID))
        }
    }

    @Test("Immediate double-fork escape follows the documented best-effort contract")
    func immediateDoubleForkIsBounded() async {
        let childPIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-task-double-fork-\(UUID().uuidString)")
        var escapedIdentity: UserTaskProcessIdentity?
        defer {
            terminateIfStillCurrent(escapedIdentity)
            try? FileManager.default.removeItem(at: childPIDURL)
        }
        let command = """
        /usr/bin/perl -MPOSIX=setsid -e '
            my $path = shift;
            my $first = fork();
            exit 0 if $first;
            setsid() >= 0 or exit 1;
            my $second = fork();
            exit 0 if $second;
            open STDIN, "<", "/dev/null";
            open STDOUT, ">", "/dev/null";
            open STDERR, ">", "/dev/null";
            open my $file, ">", $path or exit 1;
            print {$file} $$;
            close $file;
            sleep 30;
        ' \(shellQuote(childPIDURL.path))
        """
        let clock = ContinuousClock()
        let startedAt = clock.now
        let completion = await start(
            runner: UserTaskRunner(timeout: 3),
            task: UserTask(
                id: "double-fork",
                label: "Double Fork",
                command: command
            )
        ).waitForCompletion()
        let elapsed = startedAt.duration(to: clock.now)

        // Darwin has no public kill-process-tree primitive. A daemon that
        // double-forks and calls setsid between 25 ms identity snapshots can
        // escape; the supported guarantee is bounded return plus cleanup of
        // every identity Pine actually observed.
        #expect(elapsed < .seconds(3))
        #expect(!completion.outcome.timedOut)

        if let childProcessID = await waitForProcessID(at: childPIDURL) {
            escapedIdentity = UserTaskProcessInspector.identity(
                for: childProcessID
            )
            if let escapedIdentity,
               UserTaskProcessInspector.identity(
                   for: escapedIdentity.processID
               ) == escapedIdentity {
                _ = Darwin.kill(escapedIdentity.processID, SIGKILL)
                #expect(await waitForProcessExit(escapedIdentity.processID))
            }
        }
    }

    private func start(
        runner: UserTaskRunner,
        task: UserTask,
        fileURL: URL? = nil,
        fileContent: String? = nil
    ) -> UserTaskRunnerProbe {
        let probe = UserTaskRunnerProbe()
        runner.run(
            task: task,
            fileURL: fileURL,
            projectRootURL: FileManager.default.temporaryDirectory,
            fileContent: fileContent,
            progress: UserTaskProgress(
                onStart: {
                    probe.recordStart(
                        callbackWasOnMainThread: Thread.isMainThread
                    )
                },
                onFinish: { outcome, cancelled in
                    probe.recordFinish(
                        outcome: outcome,
                        cancelled: cancelled,
                        callbackWasOnMainThread: Thread.isMainThread
                    )
                },
                onCancellationReady: { cancellation in
                    probe.recordCancellation(
                        cancellation,
                        callbackWasOnMainThread: Thread.isMainThread
                    )
                }
            )
        )
        return probe
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitForProcessID(at url: URL) async -> pid_t? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let processID = pid_t(text) {
                return processID
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitForProcessExit(_ processID: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while isProcessAlive(processID), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !isProcessAlive(processID)
    }

    private func isProcessAlive(_ processID: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        ) == expectedSize,
           info.pbi_status == UInt32(SZOMB) {
            return false
        }
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func terminateIfStillCurrent(
        _ identity: UserTaskProcessIdentity?
    ) {
        guard let identity,
              UserTaskProcessInspector.identity(
                  for: identity.processID
              ) == identity else {
            return
        }
        _ = Darwin.kill(identity.processID, SIGKILL)
        let deadline = DispatchTime.now() + 1
        while UserTaskProcessInspector.identity(
            for: identity.processID
        ) == identity,
              DispatchTime.now() < deadline {
            Darwin.usleep(10_000)
        }
    }
}

nonisolated private struct UserTaskRunnerCompletion: Sendable {
    let outcome: UserTaskOutcome
    let cancelled: Bool
}

nonisolated private final class CancellationRaceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelStorage: Bool?
    private var finishStorage: Bool?

    var cancelAccepted: Bool? {
        lock.withLock { cancelStorage }
    }

    var finishAccepted: Bool? {
        lock.withLock { finishStorage }
    }

    func recordCancel(_ accepted: Bool) {
        lock.withLock {
            cancelStorage = accepted
        }
    }

    func recordFinish(_ cancelled: Bool) {
        lock.withLock {
            finishStorage = cancelled
        }
    }
}

nonisolated private final class UserTaskRunnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var completion: UserTaskRunnerCompletion?
    private var cancellation: UserTaskCancellation?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [
        CheckedContinuation<UserTaskRunnerCompletion, Never>
    ] = []
    private var cancellationWaiters: [
        CheckedContinuation<UserTaskCancellation, Never>
    ] = []
    private var callbackThreadChecks: [Bool] = []
    private var events: [String] = []

    var didStart: Bool {
        lock.withLock { started }
    }

    var callbacksWereOnMainThread: Bool {
        lock.withLock {
            !callbackThreadChecks.isEmpty
                && callbackThreadChecks.allSatisfy { $0 }
        }
    }

    var callbackEvents: [String] {
        lock.withLock { events }
    }

    func recordStart(callbackWasOnMainThread: Bool) {
        let waiters = lock.withLock {
            started = true
            callbackThreadChecks.append(callbackWasOnMainThread)
            events.append("start")
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func recordFinish(
        outcome: UserTaskOutcome,
        cancelled: Bool,
        callbackWasOnMainThread: Bool
    ) {
        let value = UserTaskRunnerCompletion(
            outcome: outcome,
            cancelled: cancelled
        )
        let waiters = lock.withLock {
            completion = value
            callbackThreadChecks.append(callbackWasOnMainThread)
            events.append("finish")
            let waiters = completionWaiters
            completionWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(returning: value) }
    }

    func recordCancellation(
        _ cancellation: UserTaskCancellation,
        callbackWasOnMainThread: Bool
    ) {
        let waiters = lock.withLock {
            self.cancellation = cancellation
            callbackThreadChecks.append(callbackWasOnMainThread)
            events.append("cancellation")
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(returning: cancellation) }
    }

    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func waitForCompletion() async -> UserTaskRunnerCompletion {
        await withCheckedContinuation { continuation in
            let completed: UserTaskRunnerCompletion? = lock.withLock {
                guard let completion else {
                    completionWaiters.append(continuation)
                    return nil
                }
                return completion
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }
    }

    func waitForCancellation() async -> UserTaskCancellation {
        await withCheckedContinuation { continuation in
            let ready: UserTaskCancellation? = lock.withLock {
                guard let cancellation else {
                    cancellationWaiters.append(continuation)
                    return nil
                }
                return cancellation
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
}
