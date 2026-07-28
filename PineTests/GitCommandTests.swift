//
//  GitCommandTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("GitCommand Process Lifecycle Tests", .serialized)
struct GitCommandTests {
    private let shellURL = URL(fileURLWithPath: "/bin/sh")
    private let workingDirectory = FileManager.default.temporaryDirectory

    @Test("stdout and stderr are drained concurrently")
    func drainsLargeStdoutAndStderr() {
        let lineCount = 12_000
        let script = """
        i=0
        while [ "$i" -lt \(lineCount) ]; do
          printf 'out-%05d-xxxxxxxxxxxxxxxx\\n' "$i"
          printf 'err-%05d-yyyyyyyyyyyyyyyy\\n' "$i" >&2
          i=$((i + 1))
        done
        """

        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", script],
            at: workingDirectory,
            timeout: 5
        )

        #expect(result.succeeded)
        #expect(result.outputTruncated == false)
        #expect(result.errorOutputTruncated == false)
        #expect(result.output.split(separator: "\n").count == lineCount)
        #expect(result.errorOutput.split(separator: "\n").count == lineCount)
        #expect(result.output.hasSuffix("out-11999-xxxxxxxxxxxxxxxx\n"))
        #expect(result.errorOutput.hasSuffix("err-11999-yyyyyyyyyyyyyyyy\n"))
    }

    @Test("output is bounded while both pipes continue draining")
    func boundsCapturedOutput() {
        let captureLimit = 1_024
        let lineCount = 12_000
        let script = """
        i=0
        while [ "$i" -lt \(lineCount) ]; do
          printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'
          printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\\n' >&2
          i=$((i + 1))
        done
        """

        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", script],
            at: workingDirectory,
            timeout: 5,
            captureLimit: captureLimit
        )

        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
        #expect(result.completedSuccessfully)
        #expect(result.succeeded == false)
        #expect(result.output.utf8.count == captureLimit)
        #expect(result.errorOutput.utf8.count == captureLimit)
        #expect(result.outputTruncated)
        #expect(result.errorOutputTruncated)
    }

    @Test("truncation of either stream prevents success")
    func eitherTruncatedStreamIsUnsuccessful() {
        let truncatedOutput = GitCommandResult(
            output: "partial",
            errorOutput: "",
            exitCode: 0,
            timedOut: false,
            cancelled: false,
            outputTruncated: true,
            errorOutputTruncated: false,
            outputCaptureComplete: false,
            errorOutputCaptureComplete: true,
            outputReadError: nil,
            errorOutputReadError: nil
        )
        let truncatedError = GitCommandResult(
            output: "",
            errorOutput: "partial",
            exitCode: 0,
            timedOut: false,
            cancelled: false,
            outputTruncated: false,
            errorOutputTruncated: true,
            outputCaptureComplete: true,
            errorOutputCaptureComplete: false,
            outputReadError: nil,
            errorOutputReadError: nil
        )

        #expect(truncatedOutput.succeeded == false)
        #expect(truncatedError.succeeded == false)
        #expect(truncatedOutput.completedSuccessfully)
        #expect(truncatedError.completedSuccessfully)
    }

    @Test("an unexpected stdout read error fails closed")
    func stdoutReadErrorFailsClosed() {
        let injector = GitCommandReadInjector(
            stream: .standardOutput,
            error: EIO
        )
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", ":"],
            at: workingDirectory,
            timeout: 1,
            systemCalls: GitCommandSystemCalls(
                read: { stream, descriptor, buffer, count in
                    injector.read(
                        stream: stream,
                        descriptor: descriptor,
                        buffer: buffer,
                        count: count
                    )
                }
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.outputReadError == EIO)
        #expect(result.outputCaptureComplete == false)
        #expect(result.errorOutputCaptureComplete)
        #expect(result.succeeded == false)
    }

    @Test("an unexpected stderr read error fails closed")
    func stderrReadErrorFailsClosed() {
        let injector = GitCommandReadInjector(
            stream: .standardError,
            error: EIO
        )
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", ":"],
            at: workingDirectory,
            timeout: 1,
            systemCalls: GitCommandSystemCalls(
                read: { stream, descriptor, buffer, count in
                    injector.read(
                        stream: stream,
                        descriptor: descriptor,
                        buffer: buffer,
                        count: count
                    )
                }
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.errorOutputReadError == EIO)
        #expect(result.errorOutputCaptureComplete == false)
        #expect(result.outputCaptureComplete)
        #expect(result.succeeded == false)
    }

    @Test("an interrupted read retries without losing output")
    func interruptedReadRetries() {
        let injector = GitCommandReadInjector(
            stream: .standardOutput,
            error: EINTR
        )
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", "printf complete"],
            at: workingDirectory,
            timeout: 1,
            systemCalls: GitCommandSystemCalls(
                read: { stream, descriptor, buffer, count in
                    injector.read(
                        stream: stream,
                        descriptor: descriptor,
                        buffer: buffer,
                        count: count
                    )
                }
            )
        )

        #expect(result.succeeded)
        #expect(result.output == "complete")
        #expect(result.outputReadError == nil)
        #expect(result.outputCaptureComplete)
    }

    @Test("an inherited pipe descriptor cannot outlive the timeout")
    func inheritedDescriptorIsBounded() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: [
                "-c",
                "(sleep 3) & child=$!; printf '%s\\n' \"$child\"; exit 0"
            ],
            at: workingDirectory,
            timeout: 0.2
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let descendant = pid_t(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(result.timedOut)
        #expect(result.exitCode != 0)
        #expect(result.succeeded == false)
        #expect(elapsed < 2)
        #expect(descendant != nil)
        if let descendant {
            #expect(waitUntilProcessDisappears(descendant))
        }
    }

    @Test("SIGKILL fallback removes a TERM-ignoring descendant")
    func timeoutKillsTermIgnoringProcessGroup() {
        let script = """
        trap '' TERM
        (
          trap '' TERM
          sleep 3
        ) &
        child=$!
        printf '%s\\n' "$child"
        wait "$child"
        """
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", script],
            at: workingDirectory,
            timeout: 0.2
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let descendant = pid_t(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(result.timedOut)
        #expect(result.exitCode != 0)
        #expect(result.succeeded == false)
        #expect(elapsed >= 0.4)
        #expect(elapsed < 2)
        #expect(descendant != nil)
        if let descendant {
            #expect(waitUntilProcessDisappears(descendant))
        }
    }

    @Test("a TERM-respecting process receives the full grace period")
    func timeoutAllowsTermHandlerToExit() {
        let signals = GitCommandSignalRecorder()
        let systemCalls = GitCommandSystemCalls(
            kill: { processIdentifier, signal in
                signals.kill(
                    processIdentifier: processIdentifier,
                    signal: signal
                )
            }
        )
        let script = """
        trap 'printf "term-handled\\n"; exit 0' TERM
        while :; do sleep 1; done
        """
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", script],
            at: workingDirectory,
            timeout: 0.2,
            systemCalls: systemCalls
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(result.timedOut)
        #expect(result.cancelled == false)
        #expect(result.output.contains("term-handled"))
        #expect(signals.recordedSignals == [SIGTERM])
        #expect(elapsed >= 0.18)
        #expect(elapsed < 2)
    }

    @Test("cancellation before spawn never launches the executable")
    func cancellationBeforeSpawn() async {
        let sentinel = workingDirectory.appendingPathComponent(
            "pine-git-command-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let gate = GitCommandBlockingGate()
        let executableURL = shellURL
        let directoryURL = workingDirectory
        let task = Task.detached {
            gate.wait()
            return await GitCommand.runExecutableAsync(
                executableURL,
                arguments: [
                    "-c",
                    "printf launched > \"$1\"",
                    "pine-test",
                    sentinel.path
                ],
                at: directoryURL,
                timeout: 5
            )
        }

        task.cancel()
        gate.open()
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.timedOut == false)
        #expect(result.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: sentinel.path) == false)
    }

    @Test("cancellation after spawn sends TERM and reaps the process group")
    func cancellationAfterSpawn() async {
        let started = workingDirectory.appendingPathComponent(
            "pine-git-command-started-\(UUID().uuidString)"
        )
        let signals = GitCommandSignalRecorder()
        let systemCalls = GitCommandSystemCalls(
            kill: { processIdentifier, signal in
                signals.kill(
                    processIdentifier: processIdentifier,
                    signal: signal
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: started) }
        let executableURL = shellURL
        let directoryURL = workingDirectory
        let task = Task.detached {
            await GitCommand.runExecutableAsync(
                executableURL,
                arguments: [
                    "-c",
                    """
                    printf started > "$1"
                    printf '%s\\n' "$$"
                    while :; do :; done
                    """,
                    "pine-test",
                    started.path
                ],
                at: directoryURL,
                timeout: 10,
                systemCalls: systemCalls
            )
        }

        #expect(await waitUntilFileExists(started))
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        let elapsed = ProcessInfo.processInfo.systemUptime - cancelledAt
        let processIdentifier = pid_t(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(result.cancelled)
        #expect(result.timedOut == false)
        #expect(result.succeeded == false)
        #expect(signals.recordedSignals == [SIGTERM])
        #expect(elapsed < 2)
        #expect(processIdentifier != nil)
        if let processIdentifier {
            #expect(waitUntilProcessDisappears(processIdentifier))
        }
    }

    @Test("natural completion wins over a later cancellation")
    func completionBeforeCancellation() async {
        let completionGate = GitCommandCompletionGate()
        let cancellationToken = GitCommandCancellationToken()
        // Other suites deliberately saturate the shared utility pool. Use a
        // private higher-QoS queue so this test controls the lifecycle race
        // itself instead of racing unrelated worker scheduling.
        let workerQueue = DispatchQueue(
            label: "com.pine.tests.git-command-completion",
            qos: .userInitiated
        )
        defer { completionGate.allowWaitpidToReturn() }
        let executableURL = shellURL
        let directoryURL = workingDirectory
        let task = Task<GitCommandResult, Never> {
            await withCheckedContinuation { continuation in
                workerQueue.async {
                    continuation.resume(
                        returning: GitCommand.runExecutable(
                            executableURL,
                            arguments: ["-c", ":"],
                            at: directoryURL,
                            timeout: 5,
                            cancellationToken: cancellationToken,
                            systemCalls: GitCommandSystemCalls(
                                waitpid: { processIdentifier, status, options in
                                    completionGate.waitpid(
                                        processIdentifier: processIdentifier,
                                        status: status,
                                        options: options
                                    )
                                }
                            )
                        )
                    )
                }
            }
        }

        guard await completionGate.waitUntilProcessIsReaped() else {
            cancellationToken.cancel()
            completionGate.allowWaitpidToReturn()
            _ = await task.value
            Issue.record(
                "GitCommand did not reach its natural-reap boundary"
            )
            return
        }
        // The child is already naturally complete and reaped. Hold the
        // injected waitpid return just long enough to flip the same token that
        // runExecutableAsync's cancellation handler owns, proving the loop
        // commits the observed exit status before consulting later
        // cancellation.
        cancellationToken.cancel()
        completionGate.allowWaitpidToReturn()
        let result = await task.value

        #expect(result.succeeded)
        #expect(result.cancelled == false)
        #expect(result.timedOut == false)
    }

    @Test("cancellation kills a TERM-ignoring process group")
    func cancellationKillsTermIgnoringProcessGroup() async {
        let started = workingDirectory.appendingPathComponent(
            "pine-git-command-ignore-started-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: started) }
        let executableURL = shellURL
        let directoryURL = workingDirectory
        let task = Task.detached {
            await GitCommand.runExecutableAsync(
                executableURL,
                arguments: [
                    "-c",
                    """
                    trap '' TERM
                    printf started > "$1"
                    printf '%s\\n' "$$"
                    while :; do sleep 1; done
                    """,
                    "pine-test",
                    started.path
                ],
                at: directoryURL,
                timeout: 10
            )
        }

        #expect(await waitUntilFileExists(started))
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        let elapsed = ProcessInfo.processInfo.systemUptime - cancelledAt
        let processIdentifier = pid_t(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(result.cancelled)
        #expect(result.timedOut == false)
        #expect(result.succeeded == false)
        #expect(elapsed >= 0.2)
        #expect(elapsed < 2)
        #expect(processIdentifier != nil)
        if let processIdentifier {
            #expect(waitUntilProcessDisappears(processIdentifier))
        }
    }

    @Test("parallel successes and timeouts keep lifecycle state isolated")
    func parallelInvocationsRemainIsolated() async {
        let invocationCount = 24
        let executableURL = shellURL
        let directoryURL = workingDirectory
        let results = await withTaskGroup(
            of: (Int, GitCommandResult).self,
            returning: [(Int, GitCommandResult)].self
        ) { group in
            for index in 0..<invocationCount {
                group.addTask {
                    let shouldTimeOut = index.isMultiple(of: 3)
                    let script = shouldTimeOut
                        ? """
                          trap '' TERM
                          while :; do sleep 1; done
                          """
                        : """
                          printf 'stdout-\(index)'
                          printf 'stderr-\(index)' >&2
                          """
                    let result = GitCommand.runExecutable(
                        executableURL,
                        arguments: ["-c", script],
                        at: directoryURL,
                        timeout: shouldTimeOut ? 0.2 : 5
                    )
                    return (index, result)
                }
            }

            var collected: [(Int, GitCommandResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == invocationCount)
        for (index, result) in results {
            if index.isMultiple(of: 3) {
                #expect(result.timedOut)
                #expect(result.exitCode != 0)
                #expect(result.succeeded == false)
            } else {
                #expect(result.succeeded)
                #expect(result.output == "stdout-\(index)")
                #expect(result.errorOutput == "stderr-\(index)")
            }
        }
    }

    @Test("the process-group leader remains waitable until final signalling")
    func reapPolicyPreservesProcessGroupIdentity() {
        #expect(
            GitCommand.shouldAttemptReap(
                phase: .running,
                streamsAreClosed: false
            ) == false
        )
        #expect(
            GitCommand.shouldAttemptReap(
                phase: .terminating,
                streamsAreClosed: false
            ) == false
        )
        #expect(
            GitCommand.shouldAttemptReap(
                phase: .killing,
                streamsAreClosed: false
            )
        )
        #expect(
            GitCommand.shouldAttemptReap(
                phase: .running,
                streamsAreClosed: true
            )
        )
    }

    @Test("deferred cleanup reaps once from a process-exit event")
    func deferredReaperUsesExitEvent() async {
        let waiter = GitCommandDeferredWaiter()
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: [
                "-c",
                "trap '' TERM; while :; do sleep 1; done"
            ],
            at: workingDirectory,
            timeout: 0,
            systemCalls: GitCommandSystemCalls(
                waitpid: { processIdentifier, status, options in
                    waiter.waitpid(
                        processIdentifier: processIdentifier,
                        status: status,
                        options: options
                    )
                }
            )
        )

        #expect(result.timedOut)
        #expect(result.succeeded == false)
        #expect(await waiter.waitForBlockingReap())
        #expect(waiter.blockingWaitCount == 1)
        let observationsAfterReap = waiter.nonblockingWaitCount
        usleep(100_000)
        #expect(waiter.nonblockingWaitCount == observationsAfterReap)
    }

    @Test("launch failures release their pipe descriptors")
    func launchFailureCleansUp() {
        let missingExecutable = workingDirectory
            .appendingPathComponent(UUID().uuidString)

        for _ in 0..<256 {
            let result = GitCommand.runExecutable(
                missingExecutable,
                arguments: [],
                at: workingDirectory,
                timeout: 0.05
            )
            #expect(result.exitCode == -1)
            #expect(result.timedOut == false)
            #expect(result.errorOutput.isEmpty == false)
        }

        let result = GitCommand.runExecutable(
            shellURL,
            arguments: ["-c", "printf ready"],
            at: workingDirectory,
            timeout: 1
        )
        #expect(result.succeeded)
        #expect(result.output == "ready")
    }

    @Test("unrelated parent descriptors are closed across exec")
    func unrelatedParentDescriptorsAreClosed() {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.pipe(&descriptors) == 0)
        guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }
        _ = Darwin.fcntl(descriptors[0], F_SETFD, 0)
        _ = Darwin.fcntl(descriptors[1], F_SETFD, 0)

        let script = """
        if [ -e "/dev/fd/$1" ] || [ -e "/dev/fd/$2" ]; then
          exit 42
        fi
        """
        let result = GitCommand.runExecutable(
            shellURL,
            arguments: [
                "-c",
                script,
                "pine-test",
                String(descriptors[0]),
                String(descriptors[1])
            ],
            at: workingDirectory,
            timeout: 1
        )

        #expect(result.succeeded)
    }

    private func waitUntilProcessDisappears(
        _ processIdentifier: pid_t
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            errno = 0
            if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        }
        errno = 0
        return Darwin.kill(processIdentifier, 0) == -1
            && errno == ESRCH
    }

    private func waitUntilFileExists(
        _ url: URL,
        timeout: TimeInterval = 1
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

nonisolated private final class GitCommandBlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}

nonisolated private final class GitCommandReadInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: GitCommandStream
    private let error: Int32
    private var injected = false

    init(stream: GitCommandStream, error: Int32) {
        self.stream = stream
        self.error = error
    }

    func read(
        stream: GitCommandStream,
        descriptor: Int32,
        buffer: UnsafeMutableRawPointer?,
        count: Int
    ) -> Int {
        lock.lock()
        let shouldInject = stream == self.stream && !injected
        if shouldInject {
            injected = true
        }
        lock.unlock()

        if shouldInject {
            errno = error
            return -1
        }
        return Darwin.read(descriptor, buffer, count)
    }
}

nonisolated private final class GitCommandSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []

    var recordedSignals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    func kill(processIdentifier: pid_t, signal: Int32) -> Int32 {
        lock.lock()
        signals.append(signal)
        lock.unlock()
        return Darwin.kill(processIdentifier, signal)
    }
}

nonisolated private final class GitCommandCompletionGate:
    @unchecked Sendable {
    private let lock = NSLock()
    private let returnGate = DispatchSemaphore(value: 0)
    private var processWasReaped = false
    private var didAllowReturn = false

    func waitpid(
        processIdentifier: pid_t,
        status: UnsafeMutablePointer<Int32>?,
        options: Int32
    ) -> pid_t {
        let result = Darwin.waitpid(processIdentifier, status, options)
        guard result == processIdentifier else { return result }
        lock.withLock {
            processWasReaped = true
        }
        returnGate.wait()
        return result
    }

    func waitUntilProcessIsReaped() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if lock.withLock({ processWasReaped }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { processWasReaped }
    }

    func allowWaitpidToReturn() {
        let shouldSignal = lock.withLock {
            guard !didAllowReturn else { return false }
            didAllowReturn = true
            return true
        }
        if shouldSignal {
            returnGate.signal()
        }
    }
}

nonisolated private final class GitCommandDeferredWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlockingWaitCount = 0
    private var storedNonblockingWaitCount = 0

    var blockingWaitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedBlockingWaitCount
    }

    var nonblockingWaitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedNonblockingWaitCount
    }

    func waitpid(
        processIdentifier: pid_t,
        status: UnsafeMutablePointer<Int32>?,
        options: Int32
    ) -> pid_t {
        if options == 0 {
            lock.lock()
            storedBlockingWaitCount += 1
            lock.unlock()
            return Darwin.waitpid(processIdentifier, status, options)
        }

        lock.lock()
        storedNonblockingWaitCount += 1
        lock.unlock()
        return 0
    }

    func waitForBlockingReap() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if blockingWaitCount > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return blockingWaitCount > 0
    }
}
