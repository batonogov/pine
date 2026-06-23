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
/// `-default-isolation=MainActor` flag means an unannotated class would be
/// implicitly `@MainActor`, which is exactly the crash pattern forbidden by
/// `check_nonisolated.py` (a `@MainActor` type that schedules work on a
/// background queue is the bug from #613/#693).
///
/// The polling path (`captureSnapshot`) runs on `pollQueue`, parses `ps`
/// output via the `nonisolated` `parsePsOutput`, then hops to main using a
/// `DispatchWorkItem` + `MainActor.assumeIsolated` — the same GCD-interop
/// pattern `FileSystemWatcher` uses. References needed on main (`detector`,
/// `terminalManager`) are extracted into locals BEFORE the hop so the
/// `@MainActor` closure never captures `self` (which is nonisolated and
/// non-Sendable). The static `applySnapshot(_:detector:terminalManager:)`
/// method is `@MainActor` and takes its dependencies as parameters.
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
        timer.setEventHandler { [weak self] in self?.captureSnapshot() }
        timer.resume()
        self.timer = timer
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
    /// to main to apply the snapshot. Stays `nonisolated` so the timer event
    /// handler closure does not inherit MainActor isolation (which would
    /// crash at runtime — see `check_nonisolated.py` / #693).
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
