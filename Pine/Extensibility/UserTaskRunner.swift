//
//  UserTaskRunner.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): runs user-defined tasks
//  (UserTask) in an isolated POSIX process group on a background queue,
//  reporting the outcome through a callback. Mirrors the threading contract of
//  `ExternalFileFormatter` / `runRealProcess`: never blocks the main thread.
//

import Darwin
import Foundation
import os

/// Outcome of running a user task.
nonisolated struct UserTaskOutcome: Sendable, Equatable {
    let taskID: String
    /// Captured stdout (UTF-8), including partial output from failed runs.
    let stdout: String
    /// Captured stderr (UTF-8), regardless of the exit status.
    let stderr: String
    /// Process exit status. -1 when launch, cleanup, or output capture failed.
    let exitCode: Int32
    let timedOut: Bool
    /// `true` only after Pine reaped the direct child and completed bounded
    /// process-tree and pipe cleanup.
    let cleanupSucceeded: Bool
    /// `true` when every byte intended for stdin was delivered. Replacement
    /// tasks fail closed when the child exits before consuming the buffer.
    let standardInputCompleted: Bool
    /// UTF-8 bytes retained by the UI history, calculated off the main actor
    /// for process outcomes so store trimming remains constant-time per run.
    let retainedOutputBytes: Int
    /// Bounded rendering payload, prepared beside the outcome off-main.
    let outputPreview: UserTaskOutputPreview

    init(
        taskID: String,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        cleanupSucceeded: Bool = true,
        standardInputCompleted: Bool = true,
        retainedOutputBytes: Int? = nil
    ) {
        self.taskID = taskID
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cleanupSucceeded = cleanupSucceeded
        self.standardInputCompleted = standardInputCompleted
        self.retainedOutputBytes = max(
            retainedOutputBytes
                ?? stdout.utf8.count + stderr.utf8.count,
            0
        )
        outputPreview = UserTaskOutputPreview.make(
            stdout: stdout,
            stderr: stderr
        )
    }

    var succeeded: Bool {
        exitCode == 0
            && !timedOut
            && cleanupSucceeded
            && standardInputCompleted
    }
}

/// A handle that can cancel a running task (issue #1246).
///
/// Cancelling requests bounded TERM-to-KILL cleanup of the spawned shell's
/// process group. The handle is safe to invoke from the main actor: the first
/// TERM is delivered synchronously, while grace-period polling and KILL run
/// on a dedicated background queue.
nonisolated final class UserTaskCancellation: @unchecked Sendable {
    private let terminate: @Sendable () -> Bool
    private let waitForCompletion: @Sendable (DispatchTime) -> Bool

    init(
        terminate: @escaping @Sendable () -> Bool,
        waitForCompletion: @escaping @Sendable (DispatchTime) -> Bool = { _ in true }
    ) {
        self.terminate = terminate
        self.waitForCompletion = waitForCompletion
    }

    /// A no-op handle used when a task was blocked before launch.
    static let noop = UserTaskCancellation(terminate: { false })

    /// Requests termination while the task is still active.
    ///
    /// Returns false when execution already finished, allowing the store to
    /// avoid falsely reclassifying a completed task as cancelled.
    @discardableResult
    func cancel() -> Bool {
        terminate()
    }

    /// Waits until subprocess cleanup has completed, sharing the caller's
    /// absolute deadline with every other task being shut down.
    func wait(until deadline: DispatchTime) -> Bool {
        waitForCompletion(deadline)
    }
}

/// Progress callbacks for a running task (issue #1246).
///
/// Each closure is invoked on the main thread so `@MainActor` UI models can
/// be updated directly. All are optional; `onStart` fires after the process
/// and its I/O workers are ready, `onFinish` after bounded lifecycle cleanup,
/// and `onCancellationReady` supplies the handle used by Cancel.
nonisolated struct UserTaskProgress: Sendable {
    let onStart: (@Sendable () -> Void)?
    let onFinish: (@Sendable (UserTaskOutcome, Bool) -> Void)?
    /// Receives a cancellation handle before background execution begins, so
    /// the caller can also cancel while the process is still queued.
    let onCancellationReady: (@Sendable (UserTaskCancellation) -> Void)?

    init(
        onStart: (@Sendable () -> Void)? = nil,
        onFinish: (@Sendable (UserTaskOutcome, Bool) -> Void)? = nil,
        onCancellationReady: (@Sendable (UserTaskCancellation) -> Void)? = nil
    ) {
        self.onStart = onStart
        self.onFinish = onFinish
        self.onCancellationReady = onCancellationReady
    }
}

/// Schedules the blocking workers that own a task's stdin/stdout/stderr
/// handles. The injectable implementation lets tests hold workers before
/// their entry point without suspending a process-wide dispatch queue.
nonisolated protocol UserTaskIOWorkerScheduling: Sendable {
    func schedule(_ operation: @escaping @Sendable () -> Void)
}

nonisolated struct UserTaskDispatchIOWorkerScheduler:
    UserTaskIOWorkerScheduling,
    @unchecked Sendable {
    let queue: DispatchQueue

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

nonisolated struct UserTaskIOExecutionPolicy: Sendable {
    let workerScheduler: any UserTaskIOWorkerScheduling
    let startupDeadline: TimeInterval
    let shutdownDeadline: TimeInterval
}

/// Runs `UserTask`s on a background queue.
///
/// Threading: `run(...)` dispatches subprocess execution to
/// `DispatchQueue.global` and invokes progress callbacks on the main thread.
/// The caller (main actor) is never blocked. This mirrors
/// `ExternalFileFormatter.format()`'s `DispatchGroup.wait()` pattern but is
/// fully async — tasks are user-facing and may take longer than a formatter.
nonisolated final class UserTaskRunner: @unchecked Sendable {
    static let shared = UserTaskRunner()
    private static let processIOQueue = DispatchQueue(
        label: "com.pine.user-task-io",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let processPollIntervalMicroseconds: useconds_t = 10_000
    private static let descendantSnapshotInterval: TimeInterval = 0.025
    private static let terminationReapDeadline: TimeInterval = 2.0
    private static let overallDeadlineLeeway: TimeInterval = 3.0
    private static let ioStartupDeadline: TimeInterval = 2.0
    private static let ioShutdownDeadline: TimeInterval = 0.5

    /// Per-task timeout. Matches the formatter default; generous enough for
    /// lint/compile commands but bounded so a hung task can't wedge the menu.
    private let timeout: TimeInterval
    /// Injectable for deterministic spawn-failure coverage. Production always
    /// uses the system POSIX shell.
    private let shellExecutableURL: URL
    private let ioExecutionPolicy: UserTaskIOExecutionPolicy
    /// Internal lifecycle observation used by process-ownership tests. The
    /// public progress contract deliberately does not expose process IDs.
    private let processDidSpawn: (@Sendable (pid_t) -> Void)?

    init(
        timeout: TimeInterval = 30.0,
        shellExecutableURL: URL = URL(fileURLWithPath: "/bin/sh"),
        ioExecutionPolicy: UserTaskIOExecutionPolicy? = nil,
        processDidSpawn: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.shellExecutableURL = shellExecutableURL
        self.ioExecutionPolicy = ioExecutionPolicy ?? UserTaskIOExecutionPolicy(
            workerScheduler: UserTaskDispatchIOWorkerScheduler(
                queue: Self.processIOQueue
            ),
            startupDeadline: Self.ioStartupDeadline,
            shutdownDeadline: Self.ioShutdownDeadline
        )
        self.processDidSpawn = processDidSpawn
    }

    /// Runs a task against the given file/project context.
    ///
    /// - Parameters:
    ///   - task: The task definition.
    ///   - fileURL: URL of the active file, or nil when none is open.
    ///   - projectRootURL: URL of the project root, or nil when no project.
    ///   - fileContent: Content of the active file for stdin (only used when
    ///     `task.replacesFileContent` and `task.scope == .activeFile`).
    ///   - completion: Invoked on the main thread with the outcome.
    @discardableResult
    func run(
        task: UserTask,
        fileURL: URL?,
        projectRootURL: URL?,
        fileContent: String?,
        completion: @escaping @Sendable (UserTaskOutcome) -> Void
    ) -> UserTaskCancellation {
        run(
            task: task,
            fileURL: fileURL,
            projectRootURL: projectRootURL,
            fileContent: fileContent,
            progress: UserTaskProgress(onFinish: { outcome, _ in
                completion(outcome)
            })
        )
    }

    /// Runs a task with structured progress reporting (issue #1246).
    ///
    /// The validated command path is identical to ``run(task:fileURL:projectRootURL:fileContent:completion:)``;
    /// this overload additionally surfaces start/cancellation/finish events
    /// so the UI can render running state, elapsed time, and a Cancel button.
    /// Shell text still comes directly from the validated task definition —
    /// editor, terminal, and OSC-derived content is never interpolated.
    @discardableResult
    func run(
        task: UserTask,
        fileURL: URL?,
        projectRootURL: URL?,
        fileContent: String?,
        progress: UserTaskProgress
    ) -> UserTaskCancellation {
        // --- Security gate (milestone #1088, item 4) ---
        // Validate the command *before* spawning any process.  Commands that
        // match known-dangerous patterns (rm -rf, sudo, curl|sh, …) are
        // rejected outright and never reach `/bin/sh`.
        let validation = UserTaskValidator.default.validate(command: task.command)
        if !validation.allowed {
            Logger.task.error(
                "Task '\(task.id, privacy: .public)' blocked by validator: \(validation.reason, privacy: .public)"
            )
            let outcome = UserTaskOutcome(
                taskID: task.id,
                stdout: "",
                stderr: Strings.userTaskBlocked,
                exitCode: -1,
                timedOut: false
            )
            // Surface the blocked outcome through the progress callback so
            // the UI model reflects the rejection (issue #1246).
            DispatchQueue.main.async {
                progress.onCancellationReady?(.noop)
                progress.onFinish?(outcome, false)
            }
            return .noop
        }

        let workingDir: URL?
        let stdinText: String

        switch task.scope {
        case .activeFile:
            workingDir = fileURL?.deletingLastPathComponent() ?? projectRootURL
            stdinText = task.replacesFileContent ? (fileContent ?? "") : ""
        case .project:
            workingDir = projectRootURL
            stdinText = ""
        }

        let timeout = self.timeout

        // Log the attempt (what + when).
        Logger.task.info(
            "Task '\(task.id, privacy: .public)' starting: '\(task.command, privacy: .private)'"
        )

        let executionState = UserTaskExecutionState()

        // Publish the handle before dispatch so a caller can cancel even while
        // the background queue is still waiting to start the process.
        let cancellation = UserTaskCancellation {
            executionState.requestCancellation()
        } waitForCompletion: { deadline in
            executionState.waitForCompletion(until: deadline)
        }
        DispatchQueue.main.async {
            progress.onCancellationReady?(cancellation)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let execution = Self.execute(
                config: .init(
                    executableURL: self.shellExecutableURL,
                    command: task.command,
                    workingDirectory: workingDir,
                    stdin: stdinText,
                    timeout: timeout,
                    taskID: task.id,
                    executionState: executionState,
                    ioExecutionPolicy: self.ioExecutionPolicy,
                    processDidSpawn: self.processDidSpawn
                ),
                onStart: {
                    DispatchQueue.main.async { progress.onStart?() }
                }
            )
            let outcome = execution.outcome
            let didCancel = execution.cancelled

            // Log the result (exit code).
            if outcome.succeeded {
                Logger.task.info(
                    "Task '\(task.id, privacy: .public)' completed (exit 0)"
                )
            } else {
                let exitCode = outcome.exitCode
                let timedOut = outcome.timedOut
                let stderr = outcome.stderr
                Logger.task.error(
                    "Task '\(task.id, privacy: .public)' exit \(exitCode), timedOut: \(timedOut), cancelled: \(didCancel)"
                )
                if !stderr.isEmpty {
                    Logger.task.error("stderr: \(stderr, privacy: .private)")
                }
            }

            DispatchQueue.main.async {
                progress.onFinish?(outcome, didCancel)
            }
        }
        return cancellation
    }

    // MARK: - Private

    /// Spawns the shell command and waits for it (called off the main thread).
    struct ExecuteConfig: Sendable {
        let executableURL: URL
        let command: String
        let workingDirectory: URL?
        let stdin: String
        let timeout: TimeInterval
        let taskID: String
        let executionState: UserTaskExecutionState
        let ioExecutionPolicy: UserTaskIOExecutionPolicy
        let processDidSpawn: (@Sendable (pid_t) -> Void)?
    }

    private struct ExecutionResult: Sendable {
        let outcome: UserTaskOutcome
        let cancelled: Bool
    }

    private static func execute(
        config: ExecuteConfig,
        onStart: @escaping @Sendable () -> Void
    ) -> ExecutionResult {
        precondition(!Thread.isMainThread, "UserTaskRunner must run off the main thread")
        var completedCleanup = false
        defer {
            config.executionState.complete(
                cleanupSucceeded: completedCleanup
            )
        }

        // A cancellation accepted while this work item was still queued must
        // not launch a process merely to terminate it.
        if config.executionState.terminalCause == .cancelled {
            completedCleanup = true
            return ExecutionResult(
                outcome: UserTaskOutcome(
                    taskID: config.taskID,
                    stdout: "",
                    stderr: "",
                    exitCode: -1,
                    timedOut: false,
                    cleanupSucceeded: true
                ),
                cancelled: true
            )
        }

        let subprocess: UserTaskSubprocess
        do {
            subprocess = try UserTaskSubprocess(
                executableURL: config.executableURL,
                command: config.command,
                workingDirectory: config.workingDirectory
            )
        } catch {
            // No child exists, so there is nothing for shutdown to reap even
            // though the task outcome itself is a launch failure.
            completedCleanup = true
            Logger.task.error(
                "Task '\(config.taskID, privacy: .public)' failed to launch: \(error.localizedDescription, privacy: .public)"
            )
            return ExecutionResult(
                outcome: UserTaskOutcome(
                    taskID: config.taskID,
                    stdout: "",
                    stderr: Strings.userTaskLaunchFailed(
                        error.localizedDescription
                    ),
                    exitCode: -1,
                    timedOut: false,
                    cleanupSucceeded: false
                ),
                cancelled: config.executionState.closeWithoutProcess() == .cancelled
            )
        }
        let descendantTracker = UserTaskDescendantTracker(
            rootProcessID: subprocess.processGroup.identifier
        )

        // Publish the isolated process group so cancellation terminates the
        // shell and ordinary descendants. A pre-spawn cancellation is applied
        // immediately; observed group escapees are cleaned up below.
        config.executionState.publishProcessGroup(subprocess.processGroup)
        config.processDidSpawn?(subprocess.processGroup.identifier)

        // Each pipe has one owning worker. Polling readers/writer observe the
        // shared stop state, so cleanup never closes a FileHandle underneath
        // a blocking operation on another thread.
        let ioGroup = DispatchGroup()
        let ioStopState = UserTaskIOStopState()
        let outputCapture = UserTaskOutputCapture()
        let inputCapture = UserTaskInputCapture()
        let stdinData = config.stdin.data(using: .utf8) ?? Data()
        let ioStartup = UserTaskIOStartupBarrier(
            workerCount: stdinData.isEmpty ? 2 : 3
        )
        ioGroup.enter()
        config.ioExecutionPolicy.workerScheduler.schedule {
            ioStartup.workerDidStart()
            defer { ioGroup.leave() }
            outputCapture.setStdout(
                UserTaskPipeReader.read(
                    from: subprocess.standardOutput,
                    stopState: ioStopState
                )
            )
        }
        ioGroup.enter()
        config.ioExecutionPolicy.workerScheduler.schedule {
            ioStartup.workerDidStart()
            defer { ioGroup.leave() }
            outputCapture.setStderr(
                UserTaskPipeReader.read(
                    from: subprocess.standardError,
                    stopState: ioStopState
                )
            )
        }

        if stdinData.isEmpty {
            subprocess.standardInput.closeFile()
            inputCapture.setResult(.complete)
        } else {
            ioGroup.enter()
            config.ioExecutionPolicy.workerScheduler.schedule {
                ioStartup.workerDidStart()
                defer { ioGroup.leave() }
                inputCapture.setResult(
                    UserTaskPipeWriter.write(
                        stdinData,
                        to: subprocess.standardInput,
                        stopState: ioStopState
                    )
                )
            }
        }

        // A task is not "running" until every worker owns its descriptor.
        // This also keeps Pine's own executor delay outside the task timeout.
        // If scheduling never begins, fail closed and start bounded process
        // cleanup instead of waiting indefinitely.
        let ioWorkersStarted = ioStartup.wait(
            timeout: config.ioExecutionPolicy.startupDeadline
        )
        if ioWorkersStarted {
            onStart()
        } else {
            ioStopState.stop()
            subprocess.processGroup.requestTermination()
        }

        // One polling loop owns both waitpid and the timeout decision. It
        // always checks for process exit first, eliminating the old timer
        // race that could mark an already-reapable command as timed out.
        let effectiveTimeout = max(config.timeout, 0)
        let lifecycleStart = DispatchTime.now()
        let timeoutDeadline = lifecycleStart + effectiveTimeout

        // Polling waitpid keeps descendant snapshots current and gives the
        // runner a hard return deadline. If SIGKILL cannot promptly finish
        // the shell, ownership moves to the dedicated background reaper.
        let directChild = waitForDirectChild(
            subprocess,
            descendantTracker: descendantTracker,
            executionState: config.executionState,
            timeoutDeadline: timeoutDeadline,
            overallDeadline: timeoutDeadline + overallDeadlineLeeway
        )

        let terminalCause = config.executionState.terminalCause
        let didTimeout = terminalCause == .timedOut
        let didCancel = terminalCause == .cancelled

        // A command can deliberately background a child and let its shell
        // exit. Clean ordinary group members plus best-effort identities for
        // children that changed groups before declaring the task finished.
        descendantTracker.captureDescendants()
        subprocess.processGroup.captureKnownMembers()
        if subprocess.processGroup.isAlive {
            subprocess.processGroup.requestTermination()
        }
        let terminatedProcessGroup =
            subprocess.processGroup.waitForRequestedTermination()
        let terminatedTrackedDescendants =
            descendantTracker.terminateTrackedProcesses()

        // Readers normally observe EOF and drain buffered bytes before their
        // bounded stop fallback is requested. Under executor contention a
        // worker may not start until after the shell exits; stopping first
        // would incorrectly classify that clean run as incomplete.
        let ioFinished = UserTaskIOShutdown.waitForCompletion(
            ioGroup,
            stopState: ioStopState,
            naturalTimeout: config.ioExecutionPolicy.shutdownDeadline,
            forcedTimeout: config.ioExecutionPolicy.shutdownDeadline
        )
        let output = outputCapture.snapshot()
        let inputResult = inputCapture.snapshot()
        let streamsReachedEOF =
            output.stdout.reachedEndOfFile
            && output.stderr.reachedEndOfFile
        let outputWasTruncated =
            output.stdout.truncated || output.stderr.truncated
        let decodedStdout = String(
            data: output.stdout.data,
            encoding: .utf8
        )
        let decodedStderr = String(
            data: output.stderr.data,
            encoding: .utf8
        )
        let outputWasValidUTF8 =
            decodedStdout != nil && decodedStderr != nil
        let standardInputCompleted = inputResult == .complete

        var diagnostics: [String] = []
        if !directChild.reaped {
            diagnostics.append(
                Strings.userTaskDiagnosticBackgroundReaper
            )
        }
        if !terminatedProcessGroup || !terminatedTrackedDescendants {
            diagnostics.append(
                Strings.userTaskDiagnosticSubprocessCleanup
            )
        }
        if !ioWorkersStarted || !ioFinished || !streamsReachedEOF {
            diagnostics.append(
                Strings.userTaskDiagnosticOutputDeadline
            )
        }
        if outputWasTruncated {
            diagnostics.append(
                Strings.userTaskDiagnosticOutputTruncated
            )
        }
        if !outputWasValidUTF8 {
            diagnostics.append(
                Strings.userTaskDiagnosticInvalidUTF8
            )
        }
        if !standardInputCompleted {
            diagnostics.append(
                Strings.userTaskDiagnosticInputIncomplete
            )
        }

        var stderr = decodedStderr ?? ""
        if !diagnostics.isEmpty {
            if !stderr.isEmpty { stderr.append("\n") }
            stderr.append(diagnostics.joined(separator: "\n"))
        }
        let cleanupSucceeded =
            directChild.reaped
            && terminatedProcessGroup
            && terminatedTrackedDescendants
            && ioWorkersStarted
            && ioFinished
            && streamsReachedEOF
        let resultIsValid =
            cleanupSucceeded
            && !outputWasTruncated
            && outputWasValidUTF8
            && standardInputCompleted
        let reportedExitCode = resultIsValid
            ? directChild.exitCode
            : -1
        completedCleanup = cleanupSucceeded

        return ExecutionResult(
            outcome: UserTaskOutcome(
                taskID: config.taskID,
                stdout: decodedStdout ?? "",
                stderr: stderr,
                exitCode: reportedExitCode,
                timedOut: didTimeout,
                cleanupSucceeded: cleanupSucceeded,
                standardInputCompleted: standardInputCompleted,
                retainedOutputBytes:
                    (decodedStdout?.utf8.count ?? 0)
                    + stderr.utf8.count
            ),
            cancelled: didCancel
        )
    }

    private struct DirectChildWaitResult {
        let exitCode: Int32
        let reaped: Bool
    }

    private static func waitForDirectChild(
        _ subprocess: UserTaskSubprocess,
        descendantTracker: UserTaskDescendantTracker,
        executionState: UserTaskExecutionState,
        timeoutDeadline: DispatchTime,
        overallDeadline: DispatchTime
    ) -> DirectChildWaitResult {
        var terminationDeadline: DispatchTime?
        var nextDescendantSnapshot = DispatchTime.now()

        while true {
            let now = DispatchTime.now()
            if now >= nextDescendantSnapshot {
                // Snapshot before waitpid can reap a zombie group leader. The
                // leader's start identity is still a safe anchor at this point,
                // allowing ordinary background members to be recorded.
                descendantTracker.captureDescendants()
                subprocess.processGroup.captureKnownMembers()
                nextDescendantSnapshot =
                    now + descendantSnapshotInterval
            }

            switch subprocess.pollExit(beforeReaping: {
                // `pollExit` first retains the shell's final process-group
                // snapshot while WNOWAIT still reserves its pid. Capture the
                // best-effort descendant tree in the same pre-reap window.
                descendantTracker.captureDescendants()
            }) {
            case .exited(let exitCode):
                executionState.claimNaturalExit()
                return DirectChildWaitResult(
                    exitCode: exitCode,
                    reaped: true
                )
            case .waitFailed(let error):
                Logger.task.error(
                    "waitpid failed for task shell: errno \(error)"
                )
                executionState.closeWithoutProcess()
                return DirectChildWaitResult(exitCode: -1, reaped: false)
            case .running:
                break
            }

            if now >= timeoutDeadline {
                executionState.requestTimeout()
            }
            if subprocess.processGroup.terminationWasRequested,
               terminationDeadline == nil {
                terminationDeadline = now + terminationReapDeadline
            }
            let terminationExpired =
                terminationDeadline.map { now >= $0 } ?? false
            if terminationExpired || now >= overallDeadline {
                subprocess.processGroup.requestTermination()
                descendantTracker.captureDescendants()
                subprocess.processGroup.captureKnownMembers()
                subprocess.reapInBackground()
                executionState.closeWithoutProcess()
                return DirectChildWaitResult(exitCode: -1, reaped: false)
            }

            Darwin.usleep(processPollIntervalMicroseconds)
        }
    }
}

nonisolated enum UserTaskTerminalCause: Sendable, Equatable {
    case active
    case naturalExit
    case cancelled
    case timedOut
}

/// The single lock-protected arbiter for every terminal transition.
///
/// Cancellation, timeout, and direct-child exit compete exactly once. The
/// winning cause cannot be overwritten by a later callback. Completion is a
/// separate milestone: it is published only after reaping, descendant cleanup,
/// and pipe shutdown, which makes cancellation handles safe to wait on during
/// application termination without depending on the main-thread finish callback.
nonisolated final class UserTaskExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var cause: UserTaskTerminalCause = .active
    private var processGroup: UserTaskProcessGroup?
    private var didComplete = false
    private var completionSucceeded = false

    init() {
        completion.enter()
    }

    var terminalCause: UserTaskTerminalCause {
        lock.withLock { cause }
    }

    /// Publishes the spawned group. A pre-spawn cancellation is forwarded
    /// immediately. `requestTermination()` synchronously sends the first TERM
    /// before returning and schedules only the grace/KILL portion.
    func publishProcessGroup(_ processGroup: UserTaskProcessGroup) {
        let shouldTerminate = lock.withLock {
            self.processGroup = processGroup
            return cause == .cancelled || cause == .timedOut
        }
        if shouldTerminate {
            processGroup.requestTermination()
        }
    }

    @discardableResult
    func requestCancellation() -> Bool {
        claim(.cancelled)
    }

    @discardableResult
    func requestTimeout() -> Bool {
        claim(.timedOut)
    }

    @discardableResult
    func claimNaturalExit() -> Bool {
        claim(.naturalExit)
    }

    /// Closes a launch/wait failure to late cancellation while preserving an
    /// earlier cancellation or timeout winner.
    @discardableResult
    func closeWithoutProcess() -> UserTaskTerminalCause {
        lock.withLock {
            if cause == .active {
                cause = .naturalExit
            }
            processGroup = nil
            return cause
        }
    }

    func complete(cleanupSucceeded: Bool = true) {
        let shouldLeave = lock.withLock {
            guard !didComplete else { return false }
            didComplete = true
            completionSucceeded = cleanupSucceeded
            processGroup = nil
            return true
        }
        if shouldLeave {
            completion.leave()
        }
    }

    func waitForCompletion(until deadline: DispatchTime) -> Bool {
        guard completion.wait(timeout: deadline) == .success else {
            return false
        }
        return lock.withLock { completionSucceeded }
    }

    private func claim(_ requestedCause: UserTaskTerminalCause) -> Bool {
        let result: (accepted: Bool, group: UserTaskProcessGroup?) = lock.withLock {
            guard cause == .active, !didComplete else {
                return (false, nil)
            }
            cause = requestedCause
            return (true, processGroup)
        }
        guard result.accepted else { return false }
        result.group?.requestTermination()
        return true
    }
}
