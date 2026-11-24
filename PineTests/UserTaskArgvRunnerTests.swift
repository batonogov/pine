import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Literal argv supervision", .serialized, .timeLimit(.minutes(1)))
nonisolated struct UserTaskArgvRunnerTests {
    @Test func literalArgumentsAndWorkingDirectory() async throws {
        let literal = "$(printf expanded); | > * ' \" 雪"
        let probe = ArgvRunnerProbe()
        let root = FileManager.default.temporaryDirectory
        let cancellation = start(
            UserTaskRunner(), probe,
            executable: "/usr/bin/printf",
            arguments: ["[%s]", "", "a b", literal],
            directory: root,
            validate: { environment in
                #expect(!Thread.isMainThread)
                #expect(environment == ProcessInfo.processInfo.environment)
            }
        )
        let result = try await probe.finished()
        #expect(result.outcome.stdout == "[][a b][\(literal)]")
        #expect(result.outcome.processExitCode == 0)
        #expect(result.outcome.succeeded)
        #expect(probe.callbacksOnMainThread)
        #expect(cancellation.wait(until: .now() + 10))

        let pwd = ArgvRunnerProbe()
        start(UserTaskRunner(), pwd, executable: "/bin/pwd", directory: root)
        let pwdResult = try await pwd.finished()
        let actualDirectory = URL(fileURLWithPath:
            pwdResult.outcome.stdout.trimmingCharacters(in: .newlines))
        #expect(actualDirectory.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
    }

    @Test func rejectionHasNoEffects() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-rejected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let probe = ArgvRunnerProbe()
        let runner = UserTaskRunner(processDidSpawn: { _ in
            Issue.record("Rejected request spawned a process")
        })
        start(runner, probe, executable: "/usr/bin/touch", arguments: [marker.path]) { _ in
            throw CancellationError()
        }
        let result = try await probe.finished()
        #expect(result.outcome.preSpawnRejected)
        #expect(result.outcome.processExitCode == nil)
        #expect(!result.cancelled)
        #expect(probe.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func nonzeroAndMissingExecutable() async throws {
        let nonzero = ArgvRunnerProbe()
        start(UserTaskRunner(), nonzero, arguments: ["-e", "print 'partial'; exit 7"])
        let result = try await nonzero.finished()
        #expect(result.outcome.processExitCode == 7)
        #expect(result.outcome.exitCode == 7)
        #expect(result.outcome.stdout == "partial")
        #expect(result.outcome.outputCaptureSucceeded)

        let missing = ArgvRunnerProbe()
        start(UserTaskRunner(), missing, executable: "/pine-missing-\(UUID().uuidString)")
        let failure = try await missing.finished()
        #expect(failure.outcome.processExitCode == nil)
        #expect(failure.outcome.exitCode == -1)
        #expect(!failure.outcome.preSpawnRejected)
        #expect(missing.startCount == 0)
    }

    @Test func invalidLiteralInputsNeverReachSpawnGate() async throws {
        let cases: [(arguments: [String], directory: URL?)] = [
            (["bad\0argument"], nil),
            ([], URL(string: "https://example.invalid/worktree"))
        ]
        for input in cases {
            let probe = ArgvRunnerProbe()
            let gate = ArgvRunnerProbe()
            start(
                UserTaskRunner(), probe, executable: "/usr/bin/true",
                arguments: input.arguments, directory: input.directory
            ) { _ in gate.recordStart() }
            let result = try await probe.finished()
            #expect(gate.startCount == 0)
            #expect(result.outcome.processExitCode == nil)
            #expect(result.outcome.exitCode == -1)
            #expect(probe.startCount == 0)
        }
    }

    @Test func truncatedStreamsRetainActualExit() async throws {
        for exit in [0, 7] {
            let probe = ArgvRunnerProbe()
            let limit = UserTaskPipeReader.maximumCapturedBytes
            start(UserTaskRunner(timeout: 10), probe, arguments: [
                "-e", "print STDOUT 'o' x \(limit + 1); print STDERR 'e' x \(limit + 1); exit \(exit)"
            ])
            let result = try await probe.finished()
            #expect(result.outcome.processExitCode == Int32(exit))
            #expect(result.outcome.exitCode == -1)
            #expect(!result.outcome.outputCaptureSucceeded)
            #expect(!result.outcome.succeeded)
            #expect(result.outcome.stdout.utf8.count == limit)
            #expect(result.outcome.stderr.contains(Strings.userTaskDiagnosticOutputTruncated))
        }
    }

    @Test func invalidEncodingRetainsActualExit() async throws {
        let probe = ArgvRunnerProbe()
        start(UserTaskRunner(), probe, arguments: ["-e", "print chr(255); exit 9"])
        let result = try await probe.finished()
        #expect(result.outcome.processExitCode == 9)
        #expect(!result.outcome.outputCaptureSucceeded)
        #expect(result.outcome.exitCode == -1)
    }

    @Test func concurrencyBoundAndQueuedCancellation() async throws {
        let release = DispatchSemaphore(value: 0)
        let first = ArgvRunnerProbe()
        let second = ArgvRunnerProbe()
        let third = ArgvRunnerProbe()
        let gate = ArgvRunnerProbe()
        let runner = UserTaskRunner(maximumConcurrentExecutions: 1)
        defer { release.signal() }
        start(runner, first, executable: "/usr/bin/true") { _ in
            gate.recordStart()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        try await waitUntil { gate.startCount == 1 }
        let queued = start(runner, second, executable: "/usr/bin/true") { _ in
            Issue.record("Cancelled queued request reached spawn validation")
        }
        start(runner, third, executable: "/usr/bin/true") { _ in
            gate.recordStart()
        }
        #expect(queued.cancel())
        let cancelled = try await second.finished()
        #expect(cancelled.cancelled)
        #expect(queued.wait(until: .now() + 1))
        #expect(second.startCount == 0)
        #expect(gate.startCount == 1)
        release.signal()
        #expect(try await first.finished().outcome.succeeded)
        #expect(try await third.finished().outcome.succeeded)
        #expect(gate.startCount == 2)
    }

    @Test func cancellationDuringGateCreatesNoProcess() async throws {
        let release = DispatchSemaphore(value: 0)
        let gate = ArgvRunnerProbe()
        let probe = ArgvRunnerProbe()
        defer { release.signal() }
        let runner = UserTaskRunner(processDidSpawn: { _ in
            Issue.record("Request cancelled during validation spawned a process")
        })
        let cancellation = start(runner, probe, executable: "/usr/bin/true") { _ in
            gate.recordStart()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        try await waitUntil { gate.startCount == 1 }
        #expect(cancellation.cancel())
        release.signal()
        let result = try await probe.finished()
        #expect(result.cancelled)
        #expect(result.outcome.processExitCode == nil)
        #expect(probe.startCount == 0)
        #expect(cancellation.wait(until: .now() + 10))
    }

    @Test func queuedRequestRevalidatesLiveAuthority() async throws {
        let release = DispatchSemaphore(value: 0)
        let gate = ArgvRunnerProbe()
        let revoked = ArgvRunnerProbe()
        let first = ArgvRunnerProbe()
        let queued = ArgvRunnerProbe()
        let runner = UserTaskRunner(maximumConcurrentExecutions: 1)
        defer { release.signal() }
        start(runner, first, executable: "/usr/bin/true") { _ in
            gate.recordStart()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        try await waitUntil { gate.startCount == 1 }
        start(runner, queued, executable: "/usr/bin/true") { _ in
            if revoked.startCount > 0 { throw CancellationError() }
        }
        revoked.recordStart()
        release.signal()
        #expect(try await first.finished().outcome.succeeded)
        let result = try await queued.finished()
        #expect(result.outcome.preSpawnRejected)
        #expect(result.outcome.processExitCode == nil)
        #expect(queued.startCount == 0)
    }

    @Test func deferredCleanupRetainsConcurrencySlot() async throws {
        let workers = ArgvHoldingIOWorkers()
        defer { workers.release() }
        let runner = UserTaskRunner(
            ioExecutionPolicy: UserTaskIOExecutionPolicy(
                workerScheduler: workers, startupDeadline: 1, shutdownDeadline: 0
            ),
            maximumConcurrentExecutions: 1
        )
        let first = ArgvRunnerProbe()
        let second = ArgvRunnerProbe()
        let gate = ArgvRunnerProbe()
        let firstCancellation = start(runner, first, executable: "/usr/bin/true")
        start(runner, second, executable: "/usr/bin/true") { _ in gate.recordStart() }
        let incomplete = try await first.finished()
        #expect(!incomplete.outcome.cleanupSucceeded)
        #expect(!firstCancellation.wait(until: .now()))
        #expect(gate.startCount == 0)
        workers.release()
        #expect(firstCancellation.wait(until: .now() + 10))
        _ = try await second.finished()
        #expect(gate.startCount == 1)
    }

    @Test func noChildRejectionAndMissingExecutableReleaseOwnershipForRetry() async throws {
        for rejected in [true, false] {
            let runner = UserTaskRunner(maximumConcurrentExecutions: 1)
            let failed = ArgvRunnerProbe()
            let handle = start(
                runner, failed, executable: rejected ? "/usr/bin/true" : "/nonexistent/pine-owned-missing-tool"
            ) { _ in
                if rejected { throw CancellationError() }
            }
            let result = try await failed.finished()
            #expect(result.outcome.preSpawnRejected == rejected)
            #expect(result.outcome.processExitCode == nil)
            #expect(result.outcome.cleanupSucceeded)
            #expect(handle.wait(until: .now() + 10))
            #expect(failed.startCount == 0)
            let retry = ArgvRunnerProbe()
            start(runner, retry, executable: "/usr/bin/true")
            #expect(try await retry.finished().outcome.succeeded)
        }
    }

    @Test func cancellationAndDeadlineReapChildren() async throws {
        for cancel in [true, false] {
            let pidFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("pine-argv-child-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: pidFile) }
            let probe = ArgvRunnerProbe()
            let runner = UserTaskRunner(timeout: cancel ? 10 : 1)
            let cancellation = start(runner, probe, arguments: [
                "-e", """
                my $child = fork(); die "fork" unless defined $child;
                if (!$child) { $SIG{TERM} = 'IGNORE'; sleep 30; exit 0; }
                open my $file, '>', $ARGV[0] or die "pid";
                print {$file} $child; close $file;
                waitpid($child, 0);
                """, pidFile.path
            ])
            defer { _ = cancellation.cancel() }
            try await waitUntil {
                (try? String(contentsOf: pidFile, encoding: .utf8))
                    .flatMap { pid_t($0) } != nil
            }
            let child = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
            let identity = UserTaskProcessInspector.identity(for: child)
            defer {
                if let identity, UserTaskProcessInspector.identity(for: child) == identity {
                    _ = Darwin.kill(child, SIGKILL)
                }
            }
            if cancel { #expect(cancellation.cancel()) }
            let result = try await probe.finished()
            #expect(result.cancelled == cancel)
            #expect(result.outcome.timedOut == !cancel)
            #expect(result.outcome.processExitCode != nil)
            #expect(cancellation.wait(until: .now() + 10))
            #expect(UserTaskProcessInspector.identity(for: child) == nil)
        }
    }

    @discardableResult
    private func start(
        _ runner: UserTaskRunner,
        _ probe: ArgvRunnerProbe,
        executable: String = "/usr/bin/perl",
        arguments: [String] = [],
        directory: URL? = nil,
        validate: @escaping @Sendable ([String: String]) throws -> Void = { _ in }
    ) -> UserTaskCancellation {
        runner.run(
            taskID: "argv-test", executableURL: URL(fileURLWithPath: executable),
            arguments: arguments, workingDirectory: directory,
            preSpawnValidation: validate,
            progress: UserTaskProgress(
                onStart: { probe.recordStart() },
                onFinish: { probe.recordFinish($0, cancelled: $1) }
            )
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
}

nonisolated private final class ArgvRunnerProbe: @unchecked Sendable {
    struct Result: Sendable {
        let outcome: UserTaskOutcome
        let cancelled: Bool
    }

    private let lock = NSLock()
    private var result: Result?
    private var starts = 0
    private var onMainThread = true

    var startCount: Int { lock.withLock { starts } }
    var callbacksOnMainThread: Bool { lock.withLock { onMainThread } }

    func recordStart() {
        lock.withLock {
            starts += 1
            onMainThread = onMainThread && Thread.isMainThread
        }
    }

    func recordFinish(_ outcome: UserTaskOutcome, cancelled: Bool) {
        lock.withLock {
            #expect(result == nil)
            result = Result(outcome: outcome, cancelled: cancelled)
            onMainThread = onMainThread && Thread.isMainThread
        }
    }

    func finished() async throws -> Result {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let result = lock.withLock({ result }) { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(lock.withLock { result })
    }
}

nonisolated private final class ArgvHoldingIOWorkers:
    UserTaskIOWorkerScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let scheduler = UserTaskThreadIOWorkerScheduler()
    private var holding = true
    private var pending: [@Sendable () -> Void] = []

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        let held = lock.withLock {
            guard holding else { return false }
            pending.append(operation)
            return true
        }
        if !held { scheduler.schedule(operation) }
    }

    func release() {
        let operations = lock.withLock {
            holding = false
            let operations = pending
            pending.removeAll()
            return operations
        }
        operations.forEach { scheduler.schedule($0) }
    }
}
