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

import Darwin
import Foundation

nonisolated struct TerminalAgentOwnershipEvidence: Sendable {
    let foreground: TerminalForegroundProcessSnapshot
    let processes: [DetectedProcess]
}

nonisolated enum AgentMonotonicCounter {
    static func next(after value: UInt64) -> UInt64? {
        guard value < UInt64.max else { return nil }
        return value + 1
    }
}

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
        guard let generation = lifecycleGate.begin() else { return }
        isRunning = true
        let run = AgentPollingRun(generation: generation)
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
        guard suspendPolling() else { return }
        terminalManager?.markAgentEvidenceUnavailable()
        clearAllTabSessions()
    }

    /// Stops polling for the final termination snapshot without changing the
    /// tab-local session identities that an already granted close authorization
    /// covers. The normal ``stop()`` path still clears those sessions.
    @MainActor func suspendForTermination() {
        _ = suspendPolling()
    }

    /// Invalidates the active generation before cancelling its timer so an
    /// already captured background result cannot mutate state after suspension.
    @MainActor @discardableResult
    private func suspendPolling() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        lifecycleGate.end()
        timer?.cancel()
        timer = nil
        return true
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
        guard let sequence = run.nextSequence() else {
            lifecycleGate.end()
            return
        }
        let result = processRunner(
            "/bin/sh",
            ["-c", Self.psSnapshotCommand],
            "",
            3.0
        )
        let observation = AgentObservationStamp(
            wallTime: Date(),
            uptime: uptimeProvider(),
            generation: run.generation,
            sequence: sequence
        )
        let snapshot = Self.enrichProcessStarts(Self.makeSnapshot(
            from: result,
            observation: observation
        ))
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

    /// Parses raw
    /// `ps -eo pid=,ppid=,pgid=,lstart=,cputime=,command=` output.
    /// `nonisolated` so it is callable from the background polling queue
    /// via `captureSnapshot`. Relies on `DetectedProcess` being `nonisolated`
    /// so its init is reachable from here.
    ///
    /// macOS `lstart=` is a fixed five-token UTC value (`Wed Jul 22 15:08:40
    /// 2026`), followed by cputime and then the unbounded command. Keeping
    /// command last makes parsing unambiguous and supplies a stable start
    /// discriminator for same-pid reuse.
    ///
    /// Every fixed field is validated. A row that does not match the exact
    /// production shape is omitted, causing ``makeSnapshot`` to reject the
    /// entire poll rather than treating damaged output as absence evidence.
    nonisolated static func parsePsOutput(_ output: String) -> [DetectedProcess] {
        var processes: [DetectedProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 10,
                  let pid = Int32(tokens[0]),
                  pid > 0,
                  let parentProcessID = Int32(tokens[1]),
                  parentProcessID >= 0,
                  let processGroupID = Int32(tokens[2]),
                  processGroupID > 0,
                  parseLongStart(tokens[3...7]) != nil,
                  let cpuTime = parseCpuTime(String(tokens[8])) else {
                continue
            }
            let command = tokens[9...].joined(separator: " ")
            guard !command.isEmpty else { continue }
            processes.append(
                DetectedProcess(
                    pid: pid,
                    parentProcessID: parentProcessID,
                    processGroupID: processGroupID,
                    command: command,
                    cpuTime: cpuTime,
                    startIdentifier: tokens[3...7].joined(separator: " ")
                )
            )
        }
        return processes
    }

    nonisolated private static func enrichProcessStarts(
        _ snapshot: AgentProcessSnapshot
    ) -> AgentProcessSnapshot {
        guard case .success(let processes, let observation) = snapshot else {
            return snapshot
        }
        return .success(
            processes: processes.map { process in
                DetectedProcess(
                    pid: process.pid,
                    parentProcessID: process.parentProcessID,
                    processGroupID: process.processGroupID,
                    command: process.command,
                    cwd: process.cwd,
                    cpuTime: process.cpuTime,
                    startIdentifier: process.startIdentifier,
                    preciseStartedAt: coherentProcessStart(process)
                )
            },
            observation: observation
        )
    }

    nonisolated private static func coherentProcessStart(
        _ process: DetectedProcess
    ) -> Date? {
        guard process.pid > 1,
              let startIdentifier = process.startIdentifier,
              let coarseStart = parseLongStart(
                  startIdentifier.split(separator: " ")[...]
              ),
              let observedToken = process.command.split(
                  separator: " ",
                  maxSplits: 1,
                  omittingEmptySubsequences: true
              ).first else {
            return nil
        }
        let observedExecutable = URL(fileURLWithPath: String(observedToken))
            .lastPathComponent.lowercased()
        guard !observedExecutable.isEmpty else { return nil }

        var before = proc_bsdinfo()
        var after = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(
            process.pid,
            PROC_PIDTBSDINFO,
            0,
            &before,
            expectedSize
        ) == expectedSize,
        before.pbi_pid == UInt32(process.pid) else {
            return nil
        }
        guard let kernelArguments = kernelArguments(for: process.pid) else {
            return nil
        }

        var pathBuffer = [CChar](
            repeating: 0,
            // libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN,
            // but Swift's Clang importer does not expose that compound macro.
            count: 4 * Int(MAXPATHLEN)
        )
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(
                process.pid,
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
        guard pathLength > 0 else { return nil }
        let currentExecutable = URL(fileURLWithPath: String(cString: pathBuffer))
            .lastPathComponent.lowercased()
        guard processArgumentsAreCoherent(
            observedCommand: process.command,
            kernelArguments: kernelArguments,
            currentExecutable: currentExecutable
        ) else { return nil }

        guard proc_pidinfo(
            process.pid,
            PROC_PIDTBSDINFO,
            0,
            &after,
            expectedSize
        ) == expectedSize,
        after.pbi_pid == UInt32(process.pid) else {
            return nil
        }
        let beforeStart = Date(
            timeIntervalSince1970: TimeInterval(before.pbi_start_tvsec)
                + TimeInterval(before.pbi_start_tvusec) / 1_000_000
        )
        let preciseStart = Date(
            timeIntervalSince1970: TimeInterval(after.pbi_start_tvsec)
                + TimeInterval(after.pbi_start_tvusec) / 1_000_000
        )
        return processSampleIsCoherent(
            coarseStart: coarseStart,
            beforeStart: beforeStart,
            afterStart: preciseStart,
            observedExecutable: observedExecutable,
            currentExecutable: currentExecutable
        ) ? preciseStart : nil
    }

    nonisolated private static func kernelArguments(
        for pid: Int32
    ) -> [String]? {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size,
              size <= 16_384 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0,
              size <= bytes.count else { return nil }
        bytes.removeSubrange(size..<bytes.count)
        let argumentCount = Int(bytes.withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        })
        guard argumentCount > 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        guard consumeCString(in: bytes, cursor: &cursor) != nil else {
            return nil
        }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        while arguments.count < min(argumentCount, 2), cursor < bytes.count {
            guard let argument = consumeCString(in: bytes, cursor: &cursor) else {
                return nil
            }
            arguments.append(argument)
        }
        return arguments.count == min(argumentCount, 2) ? arguments : nil
    }

    nonisolated private static func consumeCString(
        in bytes: [UInt8],
        cursor: inout Int
    ) -> String? {
        guard cursor < bytes.count,
              let terminator = bytes[cursor...].firstIndex(of: 0),
              let value = String(
                  bytes: bytes[cursor..<terminator],
                  encoding: .utf8
              ) else { return nil }
        cursor = terminator + 1
        return value
    }

    nonisolated private static func processArgumentsAreCoherent(
        observedCommand: String,
        kernelArguments: [String],
        currentExecutable: String
    ) -> Bool {
        let observedArguments = observedCommand.split(
            separator: " ",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard let observedFirst = observedArguments.first,
              let kernelFirst = kernelArguments.first else { return false }
        let observedBase = URL(fileURLWithPath: observedFirst)
            .lastPathComponent.lowercased()
        let kernelBase = URL(fileURLWithPath: kernelFirst)
            .lastPathComponent.lowercased()
        guard observedBase == kernelBase,
              kernelBase == currentExecutable,
              AgentDetector.extractExecutableName(arguments: observedArguments)
                .lowercased()
                == AgentDetector.extractExecutableName(arguments: kernelArguments)
                    .lowercased() else { return false }
        let isWrapped = AgentDetector.extractExecutableName(
            arguments: observedArguments
        ).lowercased() != observedBase
        return !isWrapped || (
            observedArguments.count >= 2
                && kernelArguments.count >= 2
                && observedArguments[1] == kernelArguments[1]
        )
    }

    nonisolated private static func processSampleIsCoherent(
        coarseStart: Date,
        beforeStart: Date,
        afterStart: Date,
        observedExecutable: String,
        currentExecutable: String
    ) -> Bool {
        observedExecutable == currentExecutable
            && beforeStart == afterStart
            && coarseStart.timeIntervalSince1970
                == afterStart.timeIntervalSince1970.rounded(.down)
    }

    #if DEBUG
    nonisolated static func processArgumentsAreCoherentForTesting(
        observedCommand: String,
        kernelArguments: [String],
        currentExecutable: String
    ) -> Bool {
        processArgumentsAreCoherent(
            observedCommand: observedCommand,
            kernelArguments: kernelArguments,
            currentExecutable: currentExecutable
        )
    }

    nonisolated static func processSampleIsCoherentForTesting(
        coarseStart: Date,
        beforeStart: Date,
        afterStart: Date,
        observedExecutable: String,
        currentExecutable: String
    ) -> Bool {
        processSampleIsCoherent(
            coarseStart: coarseStart,
            beforeStart: beforeStart,
            afterStart: afterStart,
            observedExecutable: observedExecutable,
            currentExecutable: currentExecutable
        )
    }
    #endif

    #if DEBUG
    /// Parses the historical injected-test `pid command [cputime]` shape.
    ///
    /// Production evidence never passes through this seam: accepting a short
    /// row from the real long-form command would turn truncated output into
    /// authoritative absence.
    nonisolated static func parseLegacyPsOutputForTesting(
        _ output: String
    ) -> [DetectedProcess] {
        var processes: [DetectedProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = line.split(
                separator: " ",
                omittingEmptySubsequences: true
            )
            guard tokens.count >= 2, let pid = Int32(tokens[0]) else { continue }
            let cpuTime = parseCpuTime(String(tokens[tokens.count - 1]))
            let commandEnd = cpuTime == nil ? tokens.count : tokens.count - 1
            guard commandEnd > 1 else { continue }
            processes.append(
                DetectedProcess(
                    pid: pid,
                    command: tokens[1..<commandEnd].joined(separator: " "),
                    cpuTime: cpuTime
                )
            )
        }
        return processes
    }
    #endif

    nonisolated private static let psMonths: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    /// Calendar weekday values use Sunday == 1.
    nonisolated private static let psWeekdays: [String: Int] = [
        "Sun": 1, "Mon": 2, "Tue": 3, "Wed": 4,
        "Thu": 5, "Fri": 6, "Sat": 7,
    ]

    /// A marker written by the wrapper only after `ps` has closed its output.
    /// Unlike any particular process row, this is guaranteed to be last.
    nonisolated static let psCompletionMarker = "__PINE_PS_SNAPSHOT_COMPLETE__"

    nonisolated private static let psSnapshotCommand = [
        "TZ=UTC LC_ALL=C /bin/ps -eo pid=,ppid=,pgid=,lstart=,cputime=,command=;",
        "status=$?;",
        "printf '\\n\(psCompletionMarker)\\n';",
        "exit \"$status\"",
    ].joined(separator: " ")

    /// Parses the five fixed UTC `lstart` tokens, including the actual
    /// Gregorian date and matching weekday. This rejects values such as
    /// `Wed Xxx 99 25:80:80 2026` that merely occupy the expected columns.
    nonisolated private static func parseLongStart(
        _ tokens: ArraySlice<Substring>
    ) -> Date? {
        guard tokens.count == 5 else { return nil }
        let values = Array(tokens)
        guard let expectedWeekday = psWeekdays[String(values[0])],
              let month = psMonths[String(values[1])],
              let day = Int(values[2]),
              let year = Int(values[4]),
              (1970...9999).contains(year),
              let clock = parseClock(String(values[3])) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = utc
        components.year = year
        components.month = month
        components.day = day
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: date
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == clock.hour,
              resolved.minute == clock.minute,
              resolved.second == clock.second,
              resolved.weekday == expectedWeekday else {
            return nil
        }
        return date
    }

    nonisolated private static func parseClock(
        _ value: String
    ) -> (hour: Int, minute: Int, second: Int)? {
        let fields = value.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let hour = Int(fields[0]),
              let minute = Int(fields[1]),
              let second = Int(fields[2]),
              (0..<24).contains(hour),
              (0..<60).contains(minute),
              (0..<60).contains(second) else {
            return nil
        }
        return (hour, minute, second)
    }

    /// Parses a macOS `ps cputime=` value (`[[DD-]HH:]MM:SS[.cc]`, always
    /// containing a colon) into cumulative whole seconds. Returns `nil` for
    /// anything without a colon — in particular a bare integer, which is a
    /// command argument (e.g. `--port 8080`), not a CPU time. Centiseconds
    /// (the `.cc` suffix) are truncated, not rounded — we only compare for
    /// advancement between snapshots, so sub-second precision is irrelevant.
    ///
    /// `nonisolated` so it is reachable from the nonisolated parser above.
    nonisolated static func parseCpuTime(_ value: String) -> Int? {
        let fractionParts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1...2).contains(fractionParts.count),
              fractionParts.count == 1
                || (fractionParts[1].count == 2
                    && fractionParts[1].allSatisfy(\.isNumber)) else {
            return nil
        }

        let dayParts = fractionParts[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard (1...2).contains(dayParts.count) else { return nil }
        let clockFields = dayParts[dayParts.count - 1].split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard (2...3).contains(clockFields.count),
              clockFields.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy(\.isNumber)
              }) else {
            return nil
        }
        if dayParts.count == 2, clockFields.count != 3 {
            return nil
        }

        let days: Int
        if dayParts.count == 2 {
            guard !dayParts[0].isEmpty,
                  dayParts[0].allSatisfy(\.isNumber),
                  let parsedDays = Int(dayParts[0]) else {
                return nil
            }
            days = parsedDays
        } else {
            days = 0
        }

        let values = clockFields.compactMap { Int($0) }
        guard values.count == clockFields.count else { return nil }
        let hours = values.count == 3 ? values[0] : 0
        let minutes = values[values.count - 2]
        let seconds = values[values.count - 1]
        guard (0..<24).contains(hours),
              minutes >= 0,
              (0..<60).contains(seconds),
              values.count == 2 || minutes < 60 else {
            return nil
        }

        let (daySeconds, dayOverflow) = days.multipliedReportingOverflow(
            by: 86_400
        )
        let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(
            by: 3_600
        )
        let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(
            by: 60
        )
        guard !dayOverflow, !hourOverflow, !minuteOverflow else { return nil }
        let (dayAndHour, firstOverflow) = daySeconds.addingReportingOverflow(
            hourSeconds
        )
        let (throughMinutes, secondOverflow) = dayAndHour.addingReportingOverflow(
            minuteSeconds
        )
        let (total, thirdOverflow) = throughMinutes.addingReportingOverflow(
            seconds
        )
        guard !firstOverflow, !secondOverflow, !thirdOverflow else { return nil }
        return total
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
        let outputLines = result.stdout.split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        guard outputLines.last == Substring(psCompletionMarker) else {
            return .failed(observation: observation)
        }
        let processLines = outputLines.dropLast()
        let processOutput = processLines.joined(separator: "\n")
        let processes = parsePsOutput(processOutput)
        guard !processes.isEmpty,
              processes.count == processLines.count,
              processes.contains(where: { $0.pid == 1 }) else {
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
            terminalManager.refreshAgentTasks()
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
                let previous = tab.agentSession
                let current = reconciledSession(
                    previous: previous,
                    ownership: TerminalAgentOwnershipEvidence(
                        foreground: tab.foregroundProcessSnapshot(),
                        processes: processes
                    ),
                    detector: detector,
                    agentIdentityStillMatches: {
                        tab.agentProcessIdentityStillMatches($0)
                    },
                    newlyTerminated: newlyTerminated
                )
                if let current {
                    terminalManager.bridgeAgentSession(
                        current,
                        replacing: previous,
                        in: tab
                    )
                }
                tab.agentSession = current
                if let current {
                    terminalManager.captureProjectAgentOwnership(
                        of: current,
                        in: tab
                    )
                }
            }
            terminalManager.refreshAgentTasks()
        }
    }

    /// Resolves one terminal tab association after a successful snapshot.
    ///
    /// Internal for deterministic unit coverage without launching a real PTY.
    @MainActor
    static func reconciledSession(
        previous: AgentSession?,
        ownership: TerminalAgentOwnershipEvidence,
        detector: AgentDetector,
        agentIdentityStillMatches: (
            TerminalProcessStartIdentity
        ) -> Bool,
        newlyTerminated: Set<UUID>
    ) -> AgentSession? {
        if let current = foregroundOwner(
            foreground: ownership.foreground,
            processes: ownership.processes,
            detector: detector,
            agentIdentityStillMatches: agentIdentityStillMatches
        ) {
            return current
        }
        // A live foreground group that has no exact ancestry proof is new or
        // unrelated work. It may not inherit even the one-poll exit badge.
        guard ownership.foreground == .idle else { return nil }
        guard let previous,
              previous.liveness == .terminated,
              newlyTerminated.contains(previous.id) else {
            return nil
        }
        return previous
    }

    /// Returns the unique live agent generation that owns the exact current
    /// foreground process-group member. The member's authoritative start time
    /// closes the sampling race between `ps` and `tcgetpgrp`; walking only
    /// parent links captured in that same snapshot proves ancestry. Ambiguous,
    /// incomplete, and unrelated process trees fail closed.
    @MainActor
    private static func foregroundOwner(
        foreground: TerminalForegroundProcessSnapshot,
        processes: [DetectedProcess],
        detector: AgentDetector,
        agentIdentityStillMatches: (
            TerminalProcessStartIdentity
        ) -> Bool
    ) -> AgentSession? {
        guard case .running(let processGroupID, let identity) = foreground,
              processGroupID > 1 else {
            return nil
        }
        var processesByPID: [Int32: DetectedProcess] = [:]
        for process in processes {
            guard processesByPID.updateValue(process, forKey: process.pid)
                    == nil else {
                return nil
            }
        }
        guard let witness = processesByPID[identity.processID],
              witness.processGroupID == processGroupID,
              witness.preciseStartedAt.flatMap({
                  TerminalProcessStartIdentity(
                      processID: witness.pid,
                      startedAt: $0
                  )
              }) == identity else {
            return nil
        }

        var owners: [UUID: AgentSession] = [:]
        var processID = identity.processID
        var visited: Set<Int32> = []
        while processID > 1, visited.insert(processID).inserted {
            if let session = detector.session(forPID: processID) {
                guard exactGenerationMatches(
                    session,
                    process: processesByPID[processID],
                    liveIdentityStillMatches: agentIdentityStillMatches
                ) else {
                    return nil
                }
                owners[session.id] = session
            }
            guard let parent = processesByPID[processID]?.parentProcessID,
                  parent > 1 else {
                break
            }
            processID = parent
        }
        guard owners.count == 1 else { return nil }
        return owners.values.first
    }

    /// `session(forPID:)` proves that this is the detector's current logical
    /// generation. Match its immutable authoritative OS start witness against
    /// the current `ps` row as well, so same-second PID reuse, precision loss,
    /// or a stale ancestry row cannot transfer terminal ownership.
    @MainActor
    private static func exactGenerationMatches(
        _ session: AgentSession,
        process: DetectedProcess?,
        liveIdentityStillMatches: (
            TerminalProcessStartIdentity
        ) -> Bool
    ) -> Bool {
        guard session.liveness == .live,
              session.state != .done,
              let process,
              let evidence = session.processEvidence,
              evidence.startIsAuthoritative,
              evidence.processIdentifier == process.pid,
              let sessionIdentity = TerminalProcessStartIdentity(
                  processEvidence: evidence
              ),
              let preciseStartedAt = process.preciseStartedAt,
              let processIdentity = TerminalProcessStartIdentity(
                  processID: process.pid,
                  startedAt: preciseStartedAt
              ),
              sessionIdentity == processIdentity,
              liveIdentityStillMatches(sessionIdentity),
              let evidenceStart = evidence.startIdentifier,
              evidenceStart == process.startIdentifier else {
            return false
        }
        return true
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
            "/bin/sh",
            ["-c", Self.psSnapshotCommand],
            "",
            3.0
        )
        let observation = AgentObservationStamp(
            wallTime: Date(),
            uptime: uptimeProvider(),
            generation: testingRun.generation,
            sequence: testingRun.nextSequence() ?? UInt64.max
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

    /// Applies a simulated complete process tree through the production
    /// detector + terminal reconciliation path. Tests supply authoritative
    /// starts directly because synthetic pids cannot be verified by libproc.
    @MainActor internal func applySnapshotForTesting(
        processes: [DetectedProcess]
    ) {
        let observation = AgentObservationStamp(
            wallTime: Date(),
            uptime: uptimeProvider(),
            generation: testingRun.generation,
            sequence: testingRun.nextSequence() ?? UInt64.max
        )
        Self.applySnapshot(
            .success(processes: processes, observation: observation),
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

    func nextSequence() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = AgentMonotonicCounter.next(after: sequence) else {
            return nil
        }
        sequence = next
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

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = AgentMonotonicCounter.next(
            after: nextGeneration
        ) else {
            activeGeneration = nil
            return nil
        }
        nextGeneration = next
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
