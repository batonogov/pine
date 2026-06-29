//
//  AgentDetectionCoordinator.swift
//  Pine
//
//  Periodically polls the system process list (`ps`) on a background queue
//  and feeds snapshots to an `AgentDetector` (vision #933, Phase 1 — Awareness).
//  After each snapshot, reconciles detected agent sessions with terminal tabs
//  so that a tab whose foreground process is a known agent gets an
//  `AgentSession` badge (#951).
//

import Foundation

/// Polls `ps` off the main thread and drives `AgentDetector` lifecycle,
/// then maps detected agent pids to terminal tabs via `tcgetpgrp`.
///
/// Marked `nonisolated` (not `@MainActor`) because it owns a background
/// `DispatchQueue` for polling. This matches the project's canonical pattern
/// for background-queue owners — see `FileSystemWatcher`. The project-wide
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting means an
/// unannotated class would be implicitly `@MainActor`; a `@MainActor` type
/// that owns a background dispatch queue is the crash pattern from #613/#693.
///
/// The polling path (`captureSnapshot`) runs on `pollQueue`, parses `ps`
/// output via the `nonisolated` `parsePsOutput`, then hops to main using a
/// `DispatchWorkItem` + `MainActor.assumeIsolated` — the same GCD-interop
/// pattern `FileSystemWatcher` uses. References needed on main (`detector`,
/// `terminalManager`) are extracted into locals BEFORE the hop so the
/// `@MainActor` closure never captures `self` (which is nonisolated and
/// non-Sendable). The static `applySnapshot(_:detector:terminalManager:)`
/// method is `@MainActor` and takes its dependencies as parameters.
///
/// **Timer handler isolation (release 1.31.1 crash fix):** the
/// `DispatchSource` timer fires on `pollQueue` and invokes its handler
/// closure directly — no actor hop. A closure literal inherits the isolation
/// of its *enclosing* function, so a handler written inline inside the
/// `@MainActor` `start()` is MainActor-isolated; running it off-main trips
/// Swift's `swift_task_isCurrentExecutorWithFlagsImpl` check
/// (`dispatch_assert_queue(main)`) and traps the process (the macOS 27 crash
/// on project open in 1.31.1). The handler is therefore built in the
/// `nonisolated` `makePollHandler()` so the closure is nonisolated. Note that
/// `captureSnapshot` being `nonisolated` is NOT sufficient on its own — only
/// the closure literal's own isolation matters at the dispatch boundary.
nonisolated final class AgentDetectionCoordinator {
    let detector: AgentDetector
    weak var terminalManager: TerminalManager?
    private let processRunner: ProcessRunner
    private let pollInterval: TimeInterval
    private let pollQueue = DispatchQueue(label: "com.pine.agent-detection", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Whether polling is active. Read/written only from `@MainActor` methods
    /// (`start`/`stop`); the background polling path does not touch it.
    private(set) var isRunning = false

    init(
        detector: AgentDetector,
        terminalManager: TerminalManager?,
        processRunner: @escaping ProcessRunner = runRealProcess,
        pollInterval: TimeInterval = 2.0
    ) {
        self.detector = detector
        self.terminalManager = terminalManager
        self.processRunner = processRunner
        self.pollInterval = pollInterval
    }

    @MainActor func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        // Build the handler via the nonisolated makePollHandler(): a closure
        // literal written here (inside the @MainActor start()) would inherit
        // MainActor isolation and trap when the source invokes it on
        // pollQueue — see the class doc and the release 1.31.1 crash fix.
        timer.setEventHandler(handler: makePollHandler())
        timer.resume()
        self.timer = timer
    }

    /// Builds the timer's event handler in a `nonisolated` function so the
    /// returned closure is nonisolated. The `DispatchSource` timer invokes
    /// this handler directly on `pollQueue` (no actor hop); a MainActor-
    /// isolated handler would trip Swift's executor-isolation assertion
    /// (`swift_task_isCurrentExecutorWithFlagsImpl` → `dispatch_assert_queue`)
    /// and trap the process (release 1.31.1 crash). `captureSnapshot` is
    /// itself `nonisolated`, so a nonisolated handler can call it directly.
    /// Returns `() -> Void` (not `@Sendable`) so the closure may capture the
    /// non-Sendable `self` without a strict-concurrency violation.
    nonisolated private func makePollHandler() -> () -> Void {
        { [weak self] in self?.captureSnapshot() }
    }

    @MainActor func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        clearAllTabSessions()
    }

    deinit { timer?.cancel() }

    /// Runs on `pollQueue`: captures the process list, parses it, then hops
    /// to main to apply the snapshot. `nonisolated` so the nonisolated timer
    /// handler (`makePollHandler`) can call it directly off-main. A handler's
    /// isolation is determined by where its closure literal is written, not
    /// by this method's isolation — that is why the handler lives in
    /// `makePollHandler`, not inline in `start()` (see the class doc and the
    /// release 1.31.1 crash fix).
    ///
    /// Uses `DispatchWorkItem` + `MainActor.assumeIsolated` instead of
    /// `Task { @MainActor in }` to match the `FileSystemWatcher` pattern:
    /// `DispatchWorkItem` does not require `@Sendable` so non-Sendable
    /// references (`detector`, `terminalManager`) can be captured. The
    /// references are extracted to locals BEFORE the hop so the
    /// `@MainActor` closure never captures `self`, avoiding the strict-
    /// concurrency "sending 'self' risks causing data races" error.
    nonisolated private func captureSnapshot() {
        let result = processRunner("/bin/ps", ["-eo", "pid=,command="], "", 3.0)
        let processes = Self.parsePsOutput(result.stdout)
        // Extract references before the hop — the DispatchWorkItem closure
        // must not capture `self` (nonisolated, non-Sendable).
        let detector = self.detector
        let termManager = self.terminalManager
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                Self.applySnapshot(processes, detector: detector, terminalManager: termManager)
            }
        }
        DispatchQueue.main.async(execute: work)
    }

    /// Parses raw `ps -eo pid=,command=` output into `[DetectedProcess]`.
    /// `nonisolated` so it is callable from the background polling queue
    /// via `captureSnapshot`. Relies on `DetectedProcess` being `nonisolated`
    /// so its init is reachable from here.
    nonisolated static func parsePsOutput(_ output: String) -> [DetectedProcess] {
        var processes: [DetectedProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
            let pidString = String(trimmed[..<spaceIndex])
            guard let pid = Int32(pidString) else { continue }
            let command = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            processes.append(DetectedProcess(pid: pid, command: command))
        }
        return processes
    }

    /// Feeds the process snapshot to the detector and reconciles terminal
    /// tabs. `@MainActor` because it touches `AgentDetector` (main state)
    /// and `TerminalManager` / `TerminalTab.agentSession` (main state).
    /// Static + takes dependencies as parameters so callers that captured
    /// references before a main-actor hop can invoke it without capturing
    /// `self` (which is nonisolated and non-Sendable).
    @MainActor private static func applySnapshot(
        _ processes: [DetectedProcess],
        detector: AgentDetector,
        terminalManager: TerminalManager?
    ) {
        detector.processSnapshotDidUpdate(processes)
        guard let terminalManager else { return }
        for tab in terminalManager.allTerminalTabs {
            let fgPid = tab.foregroundProcessID
            tab.agentSession = fgPid > 0 ? detector.session(forPID: fgPid) : nil
        }
    }

    @MainActor private func clearAllTabSessions() {
        guard let terminalManager else { return }
        for tab in terminalManager.allTerminalTabs { tab.agentSession = nil }
    }

    #if DEBUG
    /// Synchronous snapshot+apply for unit tests. Bypasses the async hop in
    /// `captureSnapshot` so tests can assert state immediately after the call
    /// returns. Uses the injected `processRunner` (mock in tests), parses via
    /// `parsePsOutput`, then calls `applySnapshot` directly on the main actor.
    @MainActor internal func runSnapshotForTesting() {
        let result = processRunner("/bin/ps", ["-eo", "pid=,command="], "", 3.0)
        let processes = Self.parsePsOutput(result.stdout)
        Self.applySnapshot(processes, detector: detector, terminalManager: terminalManager)
    }
    #endif
}
