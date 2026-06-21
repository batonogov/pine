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
@MainActor
final class AgentDetectionCoordinator {
    let detector: AgentDetector
    weak var terminalManager: TerminalManager?
    private let processRunner: ProcessRunner
    private let pollInterval: TimeInterval
    private let pollQueue = DispatchQueue(label: "com.pine.agent-detection", qos: .utility)
    private var timer: DispatchSourceTimer?
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

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.captureSnapshot() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        clearAllTabSessions()
    }

    deinit { timer?.cancel() }

    nonisolated private func captureSnapshot() {
        let result = processRunner("/bin/ps", ["-eo", "pid=,command="], "", 3.0)
        let processes = Self.parsePsOutput(result.stdout)
        Task { @MainActor [weak self] in self?.applySnapshot(processes) }
    }

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

    private func applySnapshot(_ processes: [DetectedProcess]) {
        detector.processSnapshotDidUpdate(processes)
        reconcileTabs()
    }

    private func reconcileTabs() {
        guard let terminalManager else { return }
        for tab in terminalManager.allTerminalTabs {
            let fgPid = tab.foregroundProcessID
            tab.agentSession = fgPid > 0 ? detector.session(forPID: fgPid) : nil
        }
    }

    private func clearAllTabSessions() {
        guard let terminalManager else { return }
        for tab in terminalManager.allTerminalTabs { tab.agentSession = nil }
    }

    #if DEBUG
    internal func runSnapshotForTesting() { captureSnapshot() }
    #endif
}
