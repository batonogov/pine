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
    private let uptimeProvider: @Sendable () -> TimeInterval
    private let pollQueue = DispatchQueue(label: "com.pine.agent-detection", qos: .utility)
    private let lifecycleGate = AgentPollingLifecycleGate()
    private let testingRun = AgentPollingRun(generation: 0)
    private var timer: DispatchSourceTimer?

    /// Whether polling is active. Read/written only from `@MainActor` methods
    /// (`start`/`stop`); the background polling path does not touch it.
    private(set) var isRunning = false

    init(
        detector: AgentDetector,
        terminalManager: TerminalManager?,
        processRunner: @escaping ProcessRunner = runRealProcess,
        pollInterval: TimeInterval = 2.0,
        uptimeProvider: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.detector = detector
        self.terminalManager = terminalManager
        self.processRunner = processRunner
        self.pollInterval = pollInterval
        self.uptimeProvider = uptimeProvider
    }

    @MainActor func start() {
        guard !isRunning else { return }
        isRunning = true
        let run = AgentPollingRun(generation: lifecycleGate.begin())
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        // Build the handler via the nonisolated makePollHandler(): a closure
        // literal written here (inside the @MainActor start()) would inherit
        // MainActor isolation and trap when the source invokes it on
        // pollQueue — see the class doc and the release 1.31.1 crash fix.
        timer.setEventHandler(handler: makePollHandler(run: run))
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
    nonisolated private func makePollHandler(
        run: AgentPollingRun
    ) -> () -> Void {
        { [weak self] in self?.captureSnapshot(run: run) }
    }

    @MainActor func stop() {
        guard isRunning else { return }
        isRunning = false
        lifecycleGate.end()
        timer?.cancel()
        timer = nil
        clearAllTabSessions()
    }

    deinit {
        lifecycleGate.end()
        timer?.cancel()
    }

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
    nonisolated private func captureSnapshot(run: AgentPollingRun) {
        let sequence = run.nextSequence()
        let result = processRunner(
            "/bin/ps",
            ["-eo", "pid=,lstart=,cputime=,command="],
            "",
            3.0
        )
        let observation = AgentObservationStamp(
            wallTime: Date(),
            uptime: uptimeProvider(),
            generation: run.generation,
            sequence: sequence
        )
        let snapshot = Self.makeSnapshot(
            from: result,
            observation: observation
        )
        // Extract references before the hop — the DispatchWorkItem closure
        // must not capture `self` (nonisolated, non-Sendable).
        let detector = self.detector
        let termManager = self.terminalManager
        let lifecycleGate = self.lifecycleGate
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard lifecycleGate.accepts(run.generation) else { return }
                Self.applySnapshot(
                    snapshot,
                    detector: detector,
                    terminalManager: termManager
                )
            }
        }
        DispatchQueue.main.async(execute: work)
    }

    /// Parses raw `ps -eo pid=,lstart=,cputime=,command=` output.
    /// `nonisolated` so it is callable from the background polling queue
    /// via `captureSnapshot`. Relies on `DetectedProcess` being `nonisolated`
    /// so its init is reachable from here.
    ///
    /// macOS `lstart=` is a fixed five-token value (`Wed Jul 22 15:08:40
    /// 2026`), followed by cputime and then the unbounded command. Keeping
    /// command last makes parsing unambiguous and supplies a stable start
    /// discriminator for same-pid reuse. The legacy `pid,command,cputime`
    /// injected-test form remains supported.
    nonisolated static func parsePsOutput(_ output: String) -> [DetectedProcess] {
        var processes: [DetectedProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2 else { continue }
            guard let pid = Int32(tokens[0]) else { continue }

            let looksLikeLongStart = Self.psWeekdays.contains(String(tokens[1]))
                || (tokens.count >= 5 && tokens[4].filter { $0 == ":" }.count == 2)
            if looksLikeLongStart {
                guard tokens.count >= 8,
                      tokens[4].filter({ $0 == ":" }).count == 2,
                      Int(tokens[5]) != nil,
                      let cpuTime = parseCpuTime(String(tokens[6])) else {
                    continue
                }
                let command = tokens[7...].joined(separator: " ")
                guard !command.isEmpty else { continue }
                let startIdentifier = tokens[1...5].joined(separator: " ")
                processes.append(
                    DetectedProcess(
                        pid: pid,
                        command: command,
                        cpuTime: cpuTime,
                        startIdentifier: startIdentifier
                    )
                )
                continue
            }

            // Last token is cumulative CPU time (ps cputime=) when it parses
            // as one — see ``parseCpuTime(_:)``.
            let last = String(tokens[tokens.count - 1])
            let cpuTime = parseCpuTime(last)
            let commandEnd = cpuTime != nil ? tokens.count - 1 : tokens.count
            guard commandEnd > 1 else { continue }
            let command = tokens[1..<commandEnd].joined(separator: " ")
            processes.append(DetectedProcess(pid: pid, command: command, cpuTime: cpuTime))
        }
        return processes
    }

    nonisolated private static let psWeekdays: Set<String> = [
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    ]

    /// Parses a macOS `ps cputime=` value (`[[DD-]HH:]MM:SS[.cc]`, always
    /// containing a colon) into cumulative whole seconds. Returns `nil` for
    /// anything without a colon — in particular a bare integer, which is a
    /// command argument (e.g. `--port 8080`), not a CPU time. Centiseconds
    /// (the `.cc` suffix) are truncated, not rounded — we only compare for
    /// advancement between snapshots, so sub-second precision is irrelevant.
    ///
    /// `nonisolated` so it is reachable from the nonisolated parser above.
    nonisolated static func parseCpuTime(_ value: String) -> Int? {
        // macOS `ps` always emits at least `MM:SS[.cc]`; a colon must be
        // present. Reject bare integers (command args) explicitly.
        guard value.contains(":") else { return nil }
        // Strip a leading day field (`DD-HH:MM:SS` → `DD:HH:MM:SS`) and the
        // optional centisecond suffix (`.cc`).
        let withoutDays = value.replacingOccurrences(of: "-", with: ":")
        let withoutCenti = withoutDays.split(separator: ".").first.map(String.init) ?? withoutDays
        let parts = withoutCenti.split(separator: ":").compactMap { Int($0) }
        // parts is [SS], [MM, SS], [HH, MM, SS], or [DD, HH, MM, SS]. Must
        // match the segment count exactly (a stray non-numeric segment means
        // this was not really a cputime value). Days are base-24, the rest
        // base-60, so pad to a fixed [DD, HH, MM, SS] and apply positional
        // multipliers (a naive `*60` fold mis-counts day fields).
        let expectedSegments = withoutCenti.filter { $0 == ":" }.count + 1
        guard parts.count == expectedSegments, (1...4).contains(parts.count) else { return nil }
        let padded = [Int](repeating: 0, count: 4 - parts.count) + parts
        return padded[0] * 86_400 + padded[1] * 3_600 + padded[2] * 60 + padded[3]
    }

    /// Classifies a process-run result without conflating empty, partial, or
    /// malformed exit-zero stdout with an authoritative full process list.
    /// A valid non-agent row still yields a non-empty parsed list and is
    /// therefore authoritative absence for tracked agents.
    nonisolated private static func makeSnapshot(
        from result: ProcessRunResult,
        observation: AgentObservationStamp
    ) -> AgentProcessSnapshot {
        guard result.exitCode == 0, !result.timedOut else {
            return .failed(observation: observation)
        }
        let processes = parsePsOutput(result.stdout)
        let reportedRowCount = result.stdout.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).count
        guard !processes.isEmpty,
              processes.count == reportedRowCount else {
            return .failed(observation: observation)
        }
        return .success(processes: processes, observation: observation)
    }

    /// Feeds the process snapshot to the detector and reconciles terminal
    /// tabs. `@MainActor` because it touches `AgentDetector` (main state)
    /// and `TerminalManager` / `TerminalTab.agentSession` (main state).
    /// Static + takes dependencies as parameters so callers that captured
    /// references before a main-actor hop can invoke it without capturing
    /// `self` (which is nonisolated and non-Sendable).
    @MainActor private static func applySnapshot(
        _ snapshot: AgentProcessSnapshot,
        detector: AgentDetector,
        terminalManager: TerminalManager?
    ) {
        switch snapshot {
        case .failed(let observation):
            // An unavailable process list is uncertainty, not evidence that
            // every agent exited. Keep tab associations and age their last
            // successful observations instead of reconciling against [].
            detector.processSnapshotDidFail(observation: observation)
            // Termination was already established by an earlier successful
            // snapshot, so its one-interval exit badge can expire even though
            // this poll failed. Live/stale associations remain untouched.
            guard let terminalManager else { return }
            for tab in terminalManager.allTerminalTabs
            where shouldExpireAfterFailedSnapshot(tab.agentSession) {
                tab.agentSession = nil
            }

        case .success(let processes, let observation):
            let newlyTerminated = detector.processSnapshotDidUpdate(
                processes,
                observation: observation
            )
            guard let terminalManager else { return }
            for tab in terminalManager.allTerminalTabs {
                tab.agentSession = reconciledSession(
                    previous: tab.agentSession,
                    foregroundPID: tab.foregroundProcessID,
                    detector: detector,
                    newlyTerminated: newlyTerminated
                )
            }
        }
    }

    /// Resolves one terminal tab association after a successful snapshot.
    ///
    /// Internal for deterministic unit coverage without launching a real PTY.
    @MainActor
    static func reconciledSession(
        previous: AgentSession?,
        foregroundPID: Int32,
        detector: AgentDetector,
        newlyTerminated: Set<UUID>
    ) -> AgentSession? {
        if foregroundPID > 0, let current = detector.session(forPID: foregroundPID) {
            return current
        }
        guard let previous,
              previous.liveness == .terminated,
              newlyTerminated.contains(previous.id) else {
            return nil
        }
        return previous
    }

    /// A failed poll cannot detach a session whose process evidence is merely
    /// uncertain. It may only expire exit feedback whose termination was
    /// already established by an earlier successful snapshot.
    @MainActor
    static func shouldExpireAfterFailedSnapshot(
        _ session: AgentSession?
    ) -> Bool {
        session?.liveness == .terminated
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
        let result = processRunner(
            "/bin/ps",
            ["-eo", "pid=,lstart=,cputime=,command="],
            "",
            3.0
        )
        let observation = AgentObservationStamp(
            wallTime: Date(),
            uptime: uptimeProvider(),
            generation: testingRun.generation,
            sequence: testingRun.nextSequence()
        )
        let snapshot = Self.makeSnapshot(
            from: result,
            observation: observation
        )
        Self.applySnapshot(
            snapshot,
            detector: detector,
            terminalManager: terminalManager
        )
    }
    #endif
}

/// Result of one attempt to capture the complete process list.
///
/// Keeping failure distinct from a successful empty list is essential:
/// absence in the latter is termination evidence; the former is uncertainty.
nonisolated private enum AgentProcessSnapshot: Sendable {
    case success(
        processes: [DetectedProcess],
        observation: AgentObservationStamp
    )
    case failed(observation: AgentObservationStamp)
}

/// One immutable start/stop lifecycle plus its ordered poll sequence.
///
/// The lock keeps the testing path and dispatch timer path race-free without
/// imposing actor isolation on the timer handler.
nonisolated private final class AgentPollingRun: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    init(generation: UInt64) {
        self.generation = generation
    }

    func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }
}

/// Thread-safe acceptance gate for results crossing the background-to-main
/// dispatch boundary. `stop()` invalidates the active generation before
/// cancelling the timer, so a runner already blocked in `ps` cannot apply.
nonisolated private final class AgentPollingLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    func end() {
        lock.lock()
        activeGeneration = nil
        lock.unlock()
    }

    func accepts(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }
}
