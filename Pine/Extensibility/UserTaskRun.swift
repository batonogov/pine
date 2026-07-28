//
//  UserTaskRun.swift
//  Pine
//
//  Task execution UI (issue #1246): a lightweight, observable model that
//  represents a single user-task invocation — running state, elapsed time,
//  exit status, and captured stdout/stderr. Owned by `UserTaskRunStore`,
//  which lives on the initiating `ProjectManager` so each project window
//  surfaces only its own task activity.
//
//  The model is a pure UI projection: it never spawns processes or touches
//  the shell. `UserTaskRunner` drives it by updating state as the task
//  progresses; the validated command path (`UserTaskInvocationController`
//  → `UserTaskValidator` → `UserTaskRunner`) is unchanged.
//

import Foundation

/// Bounded text used by SwiftUI for task-output rendering.
///
/// The full captured streams remain available for an explicit Copy action,
/// but rendering multi-megabyte output in one SwiftUI `Text` can synchronously
/// allocate and lay out the whole value on the main actor. This preview is
/// prepared with the outcome on the runner's background queue and caps both
/// bytes and lines before the result reaches the UI model.
nonisolated struct UserTaskOutputPreview: Sendable, Equatable {
    static let maximumUTF8Bytes = 16 * 1_024
    static let maximumLines = 200

    let text: String
    let wasTruncated: Bool

    static let empty = UserTaskOutputPreview(
        text: "",
        wasTruncated: false
    )

    static func make(
        stdout: String,
        stderr: String,
        maximumUTF8Bytes: Int = maximumUTF8Bytes,
        maximumLines: Int = maximumLines
    ) -> UserTaskOutputPreview {
        let byteLimit = max(maximumUTF8Bytes, 0)
        let lineLimit = max(maximumLines, 1)
        var data = Data()
        data.reserveCapacity(byteLimit)
        var lineCount = 1
        let newline: UInt8 = 0x0A

        func append<Bytes: Sequence>(_ bytes: Bytes) -> Bool
        where Bytes.Element == UInt8 {
            for byte in bytes {
                guard data.count < byteLimit else { return false }
                if byte == newline, lineCount >= lineLimit {
                    return false
                }
                data.append(byte)
                if byte == newline {
                    lineCount += 1
                }
            }
            return true
        }

        var complete = append(stdout.utf8)
        if complete, !stdout.isEmpty, !stderr.isEmpty {
            complete = append(CollectionOfOne(newline))
        }
        if complete {
            complete = append(stderr.utf8)
        }

        // Both source strings are valid UTF-8. A byte-boundary cut can only
        // leave one incomplete scalar at the end, so remove at most its tail
        // before publishing the preview. Never inject a replacement glyph.
        var text: String?
        repeat {
            text = String(data: data, encoding: .utf8)
            if text == nil, !data.isEmpty {
                data.removeLast()
            }
        } while text == nil && !data.isEmpty

        return UserTaskOutputPreview(
            text: text ?? "",
            wasTruncated: !complete
        )
    }
}

/// Lifecycle phase of a single task run.
nonisolated enum UserTaskRunState: Sendable, Equatable {
    /// The task has been queued / is preparing to launch.
    case pending
    /// The process is running.
    case running
    /// Cancellation won, but subprocess cleanup and direct-child reaping have
    /// not completed yet. The run remains active and waitable in this state.
    case cancelling
    /// The process exited with status 0.
    case succeeded
    /// The process exited with a non-zero status, was cancelled, timed out,
    /// or could not be launched.
    case failed
    /// The user cancelled the run before it finished.
    case cancelled

    /// `true` while the run has not reached a terminal state.
    var isActive: Bool {
        switch self {
        case .pending, .running, .cancelling: true
        case .succeeded, .failed, .cancelled: false
        }
    }
}

/// A single user-task invocation surfaced in the UI.
///
/// `@MainActor @Observable` so SwiftUI can render progress, elapsed time,
/// and captured output reactively. The `id` is stable for the lifetime of
/// the run; the store replaces a run in place by `id` as state evolves.
@MainActor
@Observable
final class UserTaskRun: Identifiable {
    /// Stable identifier for this run.
    let id: UUID
    /// The task definition's id (from `tasks.json`).
    let taskID: String
    /// Human-readable task label, snapshotted at invocation time so later
    /// edits to `tasks.json` do not retroactively rename an in-flight run.
    let taskLabel: String
    /// The validated shell command text, captured for display only. This is
    /// the exact string handed to `/bin/sh -c` — never editor or terminal
    /// content interpolated into shell text (issue #1117 safety contract).
    let command: String
    /// Whether this run was an active-file replacement task.
    let replacesFileContent: Bool

    /// Current lifecycle phase.
    private(set) var state: UserTaskRunState
    /// Wall-clock start time.
    let startedAt: Date
    /// Wall-clock finish time, set when the run reaches a terminal state.
    private(set) var finishedAt: Date?

    /// Captured stdout (UTF-8). Populated as/after the process runs.
    private(set) var stdout: String
    /// Captured stderr (UTF-8). Populated as/after the process runs.
    private(set) var stderr: String
    /// Process exit status. `-1` when the process could not be spawned or
    /// was cancelled before exiting.
    private(set) var exitCode: Int32?
    /// `true` when the task exceeded its timeout and was terminated.
    private(set) var timedOut: Bool
    /// Short, human-readable reason when the run was blocked before launch
    /// (e.g. the validator rejected the command) or failed to launch.
    private(set) var blockedReason: String?
    /// Cached retained bytes so history trimming never rescans large strings
    /// on the main actor.
    private(set) var retainedOutputBytes: Int
    /// Cached, bounded output used by the SwiftUI history surface.
    private(set) var outputPreview: UserTaskOutputPreview

    init(
        taskID: String,
        taskLabel: String,
        command: String,
        replacesFileContent: Bool,
        startedAt: Date = Date()
    ) {
        self.id = UUID()
        self.taskID = taskID
        self.taskLabel = taskLabel
        self.command = command
        self.replacesFileContent = replacesFileContent
        self.state = .pending
        self.startedAt = startedAt
        self.finishedAt = nil
        self.stdout = ""
        self.stderr = ""
        self.exitCode = nil
        self.timedOut = false
        self.blockedReason = nil
        self.retainedOutputBytes = 0
        self.outputPreview = .empty
    }

    // MARK: - Mutations (driven by UserTaskRunner)

    /// Marks the run as having started executing.
    func markRunning() {
        guard state == .pending else { return }
        state = .running
    }

    /// Records that the run was blocked before launch (validator rejection
    /// or spawn failure). Treated as a failure with a descriptive reason.
    func markBlocked(
        reason: String,
        finishedAt: Date = Date()
    ) {
        state = .failed
        self.finishedAt = finishedAt
        blockedReason = reason
    }

    /// Applies the terminal outcome of the run.
    func applyOutcome(
        _ outcome: UserTaskOutcome,
        cancelled: Bool,
        finishedAt: Date = Date()
    ) {
        stdout = outcome.stdout
        stderr = outcome.stderr
        exitCode = outcome.exitCode
        timedOut = outcome.timedOut
        retainedOutputBytes = outcome.retainedOutputBytes
        outputPreview = outcome.outputPreview
        self.finishedAt = finishedAt
        if !outcome.cleanupSucceeded || !outcome.standardInputCompleted {
            state = .failed
        } else if cancelled {
            state = .cancelled
        } else if outcome.exitCode == 0 && !outcome.timedOut {
            state = .succeeded
        } else {
            state = .failed
        }
    }

    /// Records an accepted cancellation request while retaining active
    /// ownership until the runner confirms reaping and cleanup.
    func markCancelling() {
        guard state.isActive else { return }
        state = .cancelling
    }

    // MARK: - Derived presentation values

    /// Elapsed seconds for an active run (computed at render time from
    /// `startedAt` and now) or the final duration for a finished run.
    var elapsedSeconds: TimeInterval {
        elapsedSeconds(at: Date())
    }

    /// Elapsed seconds at an explicit render instant. Terminal runs always
    /// use their recorded finish time, so the displayed duration freezes
    /// after completion.
    func elapsedSeconds(at date: Date) -> TimeInterval {
        let end = finishedAt ?? date
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// Stable, compact duration text suitable for a live task-row timer.
    func elapsedText(at date: Date) -> String {
        Self.formatElapsedDuration(elapsedSeconds(at: date))
    }

    /// Formats a duration as `M:SS`, or `H:MM:SS` after the first hour.
    nonisolated static func formatElapsedDuration(
        _ duration: TimeInterval
    ) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(format: "%d:%02d", totalMinutes, seconds)
    }

    /// `true` when the run captured any stdout or stderr worth showing in
    /// the output surface.
    var hasOutput: Bool {
        !stdout.isEmpty || !stderr.isEmpty
    }

    /// The output text to display, preferring stdout and appending stderr
    /// when present. Returns an empty string when nothing was captured.
    var combinedOutput: String {
        if !stdout.isEmpty && !stderr.isEmpty {
            return stdout + "\n" + stderr
        }
        return stdout.isEmpty ? stderr : stdout
    }

    /// Exact payload copied by the ordinary task-row Copy Output action.
    var outputCopyPayload: String {
        combinedOutput
    }

    /// Bounded, precomputed text safe to lay out in the output panel.
    var displayOutputPreview: String {
        outputPreview.text
    }

    /// Whether the panel must explain that Copy retains more than it renders.
    var displayOutputPreviewWasTruncated: Bool {
        outputPreview.wasTruncated
    }

    /// A short, human-readable summary of the terminal status, e.g.
    /// "Exit 0", "Exit 1", "Cancelled", "Timed out".
    var statusSummary: String {
        switch state {
        case .pending:
            return Strings.userTaskRunStatusPending
        case .running:
            return Strings.userTaskRunStatusRunning
        case .cancelling:
            return Strings.userTaskRunStatusCancelling
        case .succeeded:
            return Strings.userTaskRunStatusSucceeded
        case .failed:
            if timedOut {
                return Strings.userTaskRunStatusTimedOut
            }
            if let exitCode {
                return Strings.userTaskRunStatusExitCode(Int(exitCode))
            }
            return Strings.userTaskRunStatusFailed
        case .cancelled:
            return Strings.userTaskRunStatusCancelled
        }
    }
}
