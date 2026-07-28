//
//  UserTaskRunner.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): runs user-defined tasks
//  (UserTask) via `Process` on a background queue, reporting the outcome
//  through a callback. Mirrors the threading contract of
//  `ExternalFileFormatter` / `runRealProcess`: never blocks the main thread.
//

import Foundation
import os

/// Outcome of running a user task.
nonisolated struct UserTaskOutcome: Sendable, Equatable {
    let taskID: String
    /// Captured stdout (UTF-8). Empty on error or no output.
    let stdout: String
    /// Captured stderr (UTF-8). Empty on success.
    let stderr: String
    /// Process exit status. -1 when the process could not be spawned.
    let exitCode: Int32
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// A handle that can cancel a running task (issue #1246).
///
/// Cancelling terminates the spawned process (if still running) via
/// `Process.terminate()`. The handle is safe to invoke from the main actor;
/// process termination itself happens synchronously on the calling thread
/// (Process is thread-safe for `terminate`).
nonisolated final class UserTaskCancellation: @unchecked Sendable {
    private let terminate: @Sendable () -> Void

    init(terminate: @escaping @Sendable () -> Void) {
        self.terminate = terminate
    }

    /// A no-op handle used when a task was blocked before launch.
    static let noop = UserTaskCancellation(terminate: {})

    /// Terminates the underlying process if it is still running.
    func cancel() {
        terminate()
    }
}

/// Progress callbacks for a running task (issue #1246).
///
/// Each closure is invoked on the main thread so `@MainActor` UI models can
/// be updated directly. All are optional; `onStart` fires when the process
/// has been spawned, `onFinish` when it has exited (or was cancelled), and
/// `cancellation` returns a handle the caller stores to enable Cancel.
nonisolated struct UserTaskProgress: Sendable {
    let onStart: (@Sendable () -> Void)?
    let onFinish: (@Sendable (UserTaskOutcome, Bool) -> Void)?
    /// Receives the cancellation handle once the process is spawned so the
    /// caller can terminate it later.
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

/// Runs `UserTask`s on a background queue.
///
/// Threading: `run(...)` dispatches the `Process` to `DispatchQueue.global`
/// and invokes `completion` on the main thread. The caller (main actor) is
/// never blocked. This mirrors `ExternalFileFormatter.format()`'s
/// `DispatchGroup.wait()` pattern but is fully async — tasks are user-facing
/// and may take longer than a formatter.
nonisolated final class UserTaskRunner: @unchecked Sendable {
    static let shared = UserTaskRunner()

    /// Per-task timeout. Matches the formatter default; generous enough for
    /// lint/compile commands but bounded so a hung task can't wedge the menu.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30.0) {
        self.timeout = timeout
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
    func run(
        task: UserTask,
        fileURL: URL?,
        projectRootURL: URL?,
        fileContent: String?,
        completion: @escaping @Sendable (UserTaskOutcome) -> Void
    ) {
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
    func run(
        task: UserTask,
        fileURL: URL?,
        projectRootURL: URL?,
        fileContent: String?,
        progress: UserTaskProgress
    ) {
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
                stderr: "Task blocked: \(validation.reason)",
                exitCode: -1,
                timedOut: false
            )
            // Surface the blocked outcome through the progress callbacks so
            // the UI model reflects the rejection (issue #1246), then invoke
            // the legacy completion for backward compatibility.
            DispatchQueue.main.async {
                progress.onFinish?(outcome, false)
                completion(outcome)
            }
            return
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
            "Task '\(task.id, privacy: .public)' starting: '\(task.command, privacy: .public)'"
        )

        // Cancellation flag shared between the cancel handle and the execute
        // path. Set to `true` when the user cancels so the reported outcome
        // is marked as cancelled rather than a generic failure.
        let cancelFlag = UserTaskCancellationFlag()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.execute(
                config: .init(
                    command: task.command,
                    workingDirectory: workingDir,
                    stdin: stdinText,
                    timeout: timeout,
                    taskID: task.id,
                    cancelFlag: cancelFlag
                ),
                onStart: {
                    DispatchQueue.main.async { progress.onStart?() }
                }
            )

            let didCancel = cancelFlag.isCancelled

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
                    Logger.task.error("stderr: \(stderr, privacy: .public)")
                }
            }

            DispatchQueue.main.async {
                progress.onFinish?(outcome, didCancel)
                completion(outcome)
            }
        }

        // Provide the cancellation handle so the caller can terminate the
        // process. The handle flips `cancelFlag` and calls `terminate()` on
        // the process once it has been spawned.
        progress.onCancellationReady?(UserTaskCancellation {
            cancelFlag.cancel()
        })
    }

    // MARK: - Private

    /// Spawns the shell command and waits for it (called off the main thread).
    struct ExecuteConfig: Sendable {
        let command: String
        let workingDirectory: URL?
        let stdin: String
        let timeout: TimeInterval
        let taskID: String
        let cancelFlag: UserTaskCancellationFlag
    }

    private static func execute(
        config: ExecuteConfig,
        onStart: @escaping @Sendable () -> Void
    ) -> UserTaskOutcome {
        precondition(!Thread.isMainThread, "UserTaskRunner must run off the main thread")

        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Logger.task.error("Task '\(taskID, privacy: .public)' failed to launch: \(error.localizedDescription, privacy: .public)")
            return UserTaskOutcome(
                taskID: taskID, stdout: "", stderr: error.localizedDescription,
                exitCode: -1, timedOut: false
            )
        }

        // Publish the process so user-initiated cancellation can terminate it
        // (issue #1246). If the user cancelled between spawn and here, the
        // flag terminates the process immediately.
        cancelFlag.setProcess(process)

        // Notify the caller that the process is now running so the UI can
        // switch from the pending to the running state and start the timer.
        onStart()

        // Write stdin and close.
        if !stdin.isEmpty {
            stdinPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Timeout via a timer source. The same terminate path is reused for
        // user-initiated cancellation (issue #1246): `cancelFlag.cancel()`
        // terminates the process and records that the exit was a cancel.
        let timedOutLock = NSLock()
        nonisolated(unsafe) var timedOutValue = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            timedOutLock.lock()
            timedOutValue = true
            timedOutLock.unlock()
            if process.isRunning { process.terminate() }
        }
        timer.resume()

        // Read both pipes concurrently to avoid deadlock on full stderr buffer.
        let readGroup = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        readGroup.enter()
        DispatchQueue.global().async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.wait()
        process.waitUntilExit()
        timer.cancel()

        timedOutLock.lock()
        let didTimeout = timedOutValue
        timedOutLock.unlock()

        return UserTaskOutcome(
            taskID: taskID,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: didTimeout
        )
    }
}

/// Thread-safe handle coordinating user cancellation with the background
/// `execute` path (issue #1246). Lives outside actor isolation because the
/// process runs on `DispatchQueue.global` and the cancel handle may be
/// invoked from the main actor.
///
/// The spawned `Process` is stored as a weak, locked reference so that
/// `cancel()` can terminate it even if it is called before `execute` has
/// finished wiring (the handle captures the flag; `execute` publishes the
/// process into it once spawned).
final class UserTaskCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var process: Process?

    /// Publishes the spawned process so `cancel()` can terminate it. Called
    /// from `execute` on the background queue right after `process.run()`.
    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        // If the user cancelled between spawn and publication, terminate now.
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        let proc = process
        lock.unlock()
        guard !alreadyCancelled else { return }
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}
