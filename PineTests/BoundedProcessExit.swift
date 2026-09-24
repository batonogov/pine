//
//  BoundedProcessExit.swift
//  PineTests
//
//  Shared bounded wait for child processes (issue #1622).
//

import Foundation

/// Error thrown when a child process outlives its deadline (issue #1622).
///
/// A bare `Process.waitUntilExit()` blocks forever when the child hangs —
/// on the macOS 27 runtime, where fork/spawn of child processes is known to
/// stall under load (#1060, #1509), a stuck `git init` then hangs a
/// `@MainActor` Swift Testing suite with no per-test execution allowance to
/// save it (`-test-timeouts-enabled` is an XCTest mechanism). A hung child
/// must become a red test in seconds, not a dead lane.
nonisolated enum BoundedProcessExitError: Error, CustomStringConvertible {
    /// `command` did not exit within `deadline` seconds and was terminated
    /// (SIGTERM, escalating to SIGKILL after the grace period).
    case timedOut(command: String, deadline: TimeInterval)

    var description: String {
        switch self {
        case let .timedOut(command, deadline):
            "'\(command)' did not exit within \(Int(deadline))s and was terminated"
        }
    }
}

/// The collected outcome of a bounded child-process run.
nonisolated struct BoundedProcessOutput {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

/// Drains a pipe on a background queue as soon as it is created.
///
/// The drain must start before `process.run()`: a child that writes more
/// than the 64 KB pipe buffer blocks on `write(2)` and never exits, so
/// reading only after the wait would turn large output into a false
/// timeout.
///
/// `collect(allowance:)` is bounded (issue #1622 review): it is called only
/// after the child is known to have exited, but a surviving grandchild can
/// still hold the write end of the pipe and withhold EOF forever — the
/// same dead lane, just moved inside the helper. So instead of waiting for
/// the reader unconditionally, collect waits `allowance` seconds for EOF
/// and then returns whatever was drained so far (partial output beats a
/// hung suite).
nonisolated private final class BoundedPipeDrain: @unchecked Sendable {
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        // Background work owns its autorelease pool (#1509).
        DispatchQueue.global().async {
            autoreleasepool {
                while true {
                    let chunk = handle.availableData
                    self.lock.lock()
                    self.data.append(chunk)
                    self.lock.unlock()
                    if chunk.isEmpty { break } // EOF
                }
            }
            self.eofSemaphore.signal()
        }
    }

    /// Waits `allowance` seconds for EOF, then returns the data drained so
    /// far — possibly partial, possibly empty, never hung.
    func collect(allowance: TimeInterval) -> Data {
        _ = eofSemaphore.wait(timeout: .now() + allowance)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs a fully configured (not yet started) `process` and waits for it to
/// exit under a deadline (issue #1622).
///
/// The wait keeps the synchronous shape callers rely on, but a hung child is
/// terminated instead of blocking the caller forever:
///
/// 1. `terminationHandler` signals a semaphore, raced against the deadline.
/// 2. On timeout the child gets `SIGTERM`; if it is still running after
///    `gracePeriod` more seconds, it gets `SIGKILL` (same escalation as the
///    SourceKit-LSP smoke wait).
/// 3. Only then does the helper throw `BoundedProcessExitError`, naming the
///    command that hung.
///
/// Any `Pipe` attached to `standardOutput`/`standardError` is drained on a
/// background queue for the whole run (see `BoundedPipeDrain`). A caller
/// that wires both streams into one pipe gets that pipe's output in both
/// fields. Non-zero exit status is *not* an error here — callers decide
/// whether a status is a failure.
///
/// Precondition: `process` must not already have a `terminationHandler` —
/// the helper overwrites it to observe the exit.
///
/// Precondition: the command should not leave pipe-surviving grandchildren
/// behind (a still-running descendant inherits the pipe's write end and
/// withholds EOF). If it does anyway, the helper degrades gracefully:
/// output collection is bounded by `postExitAllowance` and returns the
/// partial data drained so far instead of hanging.
///
/// - Parameters:
///   - process: configured, not yet running.
///   - commandDescription: human-readable command for failure messages.
///   - deadline: seconds to wait for a normal exit. A tripwire, not a
///     stopwatch — keep it generous (see `BoundedMainActorWait.swift`).
///   - gracePeriod: seconds to wait after `SIGTERM` before `SIGKILL`.
///   - postExitAllowance: seconds to wait for pipe EOF after the child has
///     exited, covering a grandchild that still holds the write end.
@discardableResult
nonisolated func runProcessBounded(
    _ process: Process,
    commandDescription: String,
    deadline: TimeInterval = 10,
    gracePeriod: TimeInterval = 2,
    postExitAllowance: TimeInterval = 5
) throws -> BoundedProcessOutput {
    var stdoutDrain: BoundedPipeDrain?
    var stderrDrain: BoundedPipeDrain?
    if let outPipe = process.standardOutput as? Pipe {
        stdoutDrain = BoundedPipeDrain(outPipe)
        if let errPipe = process.standardError as? Pipe,
           errPipe.fileHandleForReading.fileDescriptor
               == outPipe.fileHandleForReading.fileDescriptor {
            // Both streams share one pipe: a single drain feeds both fields.
            stderrDrain = stdoutDrain
        }
    }
    if stderrDrain == nil, let errPipe = process.standardError as? Pipe {
        stderrDrain = BoundedPipeDrain(errPipe)
    }

    let exitSemaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exitSemaphore.signal() }
    try process.run()

    guard exitSemaphore.wait(timeout: .now() + deadline) == .success else {
        process.terminate()
        if exitSemaphore.wait(timeout: .now() + gracePeriod) == .timedOut,
           process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exitSemaphore.wait(timeout: .now() + gracePeriod)
        }
        throw BoundedProcessExitError.timedOut(
            command: commandDescription,
            deadline: deadline
        )
    }

    let stdout = stdoutDrain?.collect(allowance: postExitAllowance) ?? Data()
    let stderr = (stderrDrain === stdoutDrain)
        ? stdout
        : (stderrDrain?.collect(allowance: postExitAllowance) ?? Data())
    return BoundedProcessOutput(
        terminationStatus: process.terminationStatus,
        standardOutput: stdout,
        standardError: stderr
    )
}

/// Runs `/bin/sh -c command` bounded by `deadline` and returns its stdout.
///
/// Throws `NSError` (domain `"ShellError"`) when the command exits
/// non-zero, with the child's stderr in the message — the same contract the
/// per-suite `runShell` copies used before #1622, so a migrated suite keeps
/// its behaviour and only gains the deadline.
@discardableResult
nonisolated func runShellBounded(
    _ command: String,
    at dir: URL? = nil,
    deadline: TimeInterval = 10,
    gracePeriod: TimeInterval = 2,
    postExitAllowance: TimeInterval = 5
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    let output = try runProcessBounded(
        process,
        commandDescription: command,
        deadline: deadline,
        gracePeriod: gracePeriod,
        postExitAllowance: postExitAllowance
    )
    guard output.terminationStatus == 0 else {
        let stderr = String(data: output.standardError, encoding: .utf8) ?? ""
        throw NSError(
            domain: "ShellError",
            code: Int(output.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
        )
    }
    return String(data: output.standardOutput, encoding: .utf8) ?? ""
}
