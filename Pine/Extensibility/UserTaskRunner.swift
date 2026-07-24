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
            DispatchQueue.main.async { completion(outcome) }
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

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.execute(
                command: task.command,
                workingDirectory: workingDir,
                stdin: stdinText,
                timeout: timeout,
                taskID: task.id
            )

            // Log the result (exit code).
            if outcome.succeeded {
                Logger.task.info(
                    "Task '\(task.id, privacy: .public)' completed (exit 0)"
                )
            } else {
                let exitCode = outcome.exitCode
                let timedOut = outcome.timedOut
                Logger.task.error(
                    "Task '\(task.id, privacy: .public)' finished (exit \(exitCode), timedOut: \(timedOut)): \(outcome.stderr, privacy: .public)"
                )
            }

            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    // MARK: - Private

    /// Spawns the shell command and waits for it (called off the main thread).
    private static func execute(
        command: String,
        workingDirectory: URL?,
        stdin: String,
        timeout: TimeInterval,
        taskID: String
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

        // Write stdin and close.
        if !stdin.isEmpty {
            stdinPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Timeout via a timer source.
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
