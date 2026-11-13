//
//  TerminalProcessTreeController.swift
//  Pine
//

import Darwin
import Dispatch
import Foundation
import os

/// Owns the exact process generation launched for one terminal tab.
///
/// SwiftTerm closes the PTY and sends `SIGTERM` to only its direct child.
/// Interactive jobs normally move into separate foreground process groups,
/// and background children can outlive that shell. While the tab is alive,
/// the shared capture wave samples the identity-qualified descendant tree on
/// a 25 ms cadence; teardown then runs a bounded TERM-to-KILL cleanup away
/// from the main actor. Start timestamps in the shared process inspectors
/// prevent PID/PGID reuse from redirecting a signal to an unrelated process.
nonisolated final class TerminalProcessTreeController: @unchecked Sendable {
    private static let completionWaitPeriod: TimeInterval = 2.0
    private static let deferredCleanupQueue = DispatchQueue(
        label: "com.pine.terminal-process-tree.deferred-cleanup",
        qos: .utility,
        attributes: .concurrent
    )

    let rootIdentity: UserTaskProcessIdentity
    let processGroupIdentifier: pid_t?

    /// Serial queue for the bounded TERM-to-KILL teardown phase. Scheduled
    /// captures run on the shared capture wave, never on this queue, so a
    /// delayed or slow capture cannot postpone teardown.
    private let stateQueue: DispatchQueue
    private let processGroup: UserTaskProcessGroup?
    private let descendantTracker: UserTaskDescendantTracker
    private let lock = NSLock()
    private let terminationCompletion = DispatchGroup()
    private let deferredCleanupCompletion = DispatchGroup()
    private var terminationRequested = false
    private var terminationFinished = false
    private var terminationSucceeded = true
    let workingDirectoryRetention: TerminalWorkingDirectoryRetention
    #if DEBUG
    private let scheduledCaptureCount = UserTaskProcessTelemetryCounter()
    private var cleanupForTesting: (@Sendable () -> Bool)?
    private var deferredCleanupForTesting: (@Sendable () -> Void)?

    /// Observes how often the shared wave captured this controller.
    var scheduledCaptureCountForTesting: UInt64 {
        scheduledCaptureCount.current
    }

    /// Pauses/completes the same asynchronous completion path without a PTY.
    init(
        retention: TerminalWorkingDirectoryRetention,
        cleanupForTesting: @escaping @Sendable () -> Bool,
        deferredCleanupForTesting: (@Sendable () -> Void)? = nil
    ) {
        rootIdentity = UserTaskProcessIdentity(
            processID: 0, startSeconds: 0, startMicroseconds: 0
        )
        processGroupIdentifier = nil
        processGroup = nil
        descendantTracker = UserTaskDescendantTracker(rootProcessID: 0)
        stateQueue = DispatchQueue(label: "com.pine.terminal-process-tree.test")
        workingDirectoryRetention = retention
        self.cleanupForTesting = cleanupForTesting
        self.deferredCleanupForTesting = deferredCleanupForTesting
    }
    #endif

    init?(
        rootProcessID: pid_t,
        retention: TerminalWorkingDirectoryRetention
    ) {
        guard let rootIdentity = UserTaskProcessInspector.identity(
            for: rootProcessID
        ) else {
            return nil
        }

        self.rootIdentity = rootIdentity
        workingDirectoryRetention = retention
        // `forkpty` makes its child a session and process-group leader. Never
        // claim a broader inherited group if a future SwiftTerm path changes
        // that invariant; individual descendant identities remain safe.
        let observedGroup = Darwin.getpgid(rootProcessID)
        if observedGroup == rootProcessID {
            processGroupIdentifier = observedGroup
            processGroup = UserTaskProcessGroup(identifier: observedGroup)
        } else {
            processGroupIdentifier = nil
            processGroup = nil
        }
        descendantTracker = UserTaskDescendantTracker(
            rootProcessID: rootProcessID
        )
        stateQueue = DispatchQueue(
            label: "com.pine.terminal-process-tree.\(rootProcessID)",
            qos: .utility
        )
        TerminalProcessTreeCaptureScheduler.shared.register(self)
    }

    /// Starts teardown exactly once without blocking the main actor.
    func requestTermination() {
        let shouldStart = lock.withLock {
            guard !terminationRequested else { return false }
            terminationRequested = true
            terminationCompletion.enter()
            return true
        }
        guard shouldStart else { return }

        #if DEBUG
        if let cleanupForTesting {
            stateQueue.async { [self] in
                finishBoundedTermination(succeeded: cleanupForTesting())
            }
            return
        }
        #endif

        // The prologue runs on the shared capture queue, so the final capture
        // is ordered after every scheduled capture of this controller. The
        // bounded TERM-to-KILL sequence then moves to this controller's own
        // queue so a slow cleanup cannot delay other terminals' waves.
        TerminalProcessTreeCaptureScheduler.shared
            .assumeOwnershipForTermination(self) { [self] in
                stateQueue.async { [self] in
                    processGroup?.requestTermination(
                        beforeMemberCapture: { [descendantTracker] in
                            descendantTracker.captureDescendants()
                        }
                    )
                    let descendantsStopped = descendantTracker
                        .terminateTrackedProcesses()
                    let rootStopped = reapRootAfterTerminationRequest()
                    let groupStopped = processGroup?
                        .waitForRequestedTermination() ?? true
                    let succeeded = rootStopped
                        && descendantsStopped && groupStopped
                    finishBoundedTermination(
                        succeeded: succeeded,
                        rootNeedsCleanup: !rootStopped
                    )
                }
            }
    }

    /// Waits only on a caller-selected background thread. Production teardown
    /// is asynchronous; integration tests use this to place a hard bound on
    /// process and descriptor leak assertions.
    func waitForTermination(
        timeout: TimeInterval = completionWaitPeriod
    ) -> Bool {
        let state = lock.withLock {
            (
                requested: terminationRequested,
                finished: terminationFinished,
                succeeded: terminationSucceeded
            )
        }
        guard state.requested else { return true }
        if state.finished { return state.succeeded }
        guard terminationCompletion.wait(
            timeout: .now() + max(timeout, 0)
        ) == .success else {
            return false
        }
        return lock.withLock { terminationSucceeded }
    }

    /// Application Quit can await the already-running deferred cleanup after
    /// the ordinary bounded close fails. The caller supplies the outer deadline.
    func waitForApplicationTermination(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + max(timeout, 0)
        guard DispatchTime.now() < deadline else { return false }
        if waitForTermination(timeout: timeout) {
            return DispatchTime.now() < deadline
        }
        let state = lock.withLock {
            (requested: terminationRequested, finished: terminationFinished)
        }
        guard DispatchTime.now() < deadline,
              state.requested, state.finished,
              deferredCleanupCompletion.wait(timeout: deadline) == .success,
              DispatchTime.now() < deadline
        else { return false }
        workingDirectoryRetention.finishCleanup(succeeded: true)
        lock.withLock { terminationSucceeded = true }
        return true
    }

    private func finishBoundedTermination(
        succeeded: Bool,
        rootNeedsCleanup: Bool = true
    ) {
        if !succeeded {
            startDeferredCleanup(rootNeedsCleanup: rootNeedsCleanup)
        }
        finishTermination(succeeded: succeeded)
        guard !succeeded else { return }
        Logger.terminal.error(
            "Terminal process-tree cleanup exceeded its bounded phase for root \(self.rootIdentity.processID)"
        )
    }

    private func startDeferredCleanup(rootNeedsCleanup: Bool) {
        #if DEBUG
        if let deferredCleanupForTesting {
            scheduleDeferredCleanup(deferredCleanupForTesting)
            return
        }
        #endif
        scheduleDeferredCleanup { [processGroup] in
            processGroup?.finishDeferredCleanup()
        }
        scheduleDeferredCleanup { [descendantTracker] in
            descendantTracker.finishDeferredCleanup()
        }
        if rootNeedsCleanup {
            scheduleDeferredCleanup { [self] in
                finishDeferredRootCleanup()
            }
        }
    }

    private func scheduleDeferredCleanup(
        _ work: @escaping @Sendable () -> Void
    ) {
        deferredCleanupCompletion.enter()
        Self.deferredCleanupQueue.async { [self] in
            work()
            deferredCleanupCompletion.leave()
        }
    }

    private func finishDeferredRootCleanup() {
        guard rootIdentity.processID > 1 else { return }
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(
                rootIdentity.processID,
                &status,
                WNOHANG
            )
            if result == rootIdentity.processID
                || (result == -1 && errno == ECHILD) {
                return
            }
            if UserTaskProcessInspector.identity(
                for: rootIdentity.processID
            ) == rootIdentity {
                Darwin.kill(rootIdentity.processID, SIGKILL)
            }
            Darwin.usleep(10_000)
        }
    }

    private func finishTermination(succeeded: Bool) {
        // Publish the deletion-fence release before waking background waiters.
        // A bounded failure retains the fence until deferred cleanup completes.
        workingDirectoryRetention.finishCleanup(succeeded: succeeded)
        lock.withLock {
            terminationSucceeded = succeeded
            terminationFinished = true
        }
        terminationCompletion.leave()
    }

    /// Runs one ownership-capture pass. Called from the shared capture wave
    /// and from the scheduler's teardown prologue; both run on the scheduler's
    /// capture queue.
    func performScheduledCapture() {
        #if DEBUG
        scheduledCaptureCount.increment()
        #endif
        captureOwnedProcesses()
    }

    /// Final capture ordered after every scheduled capture of this
    /// controller. Runs on the scheduler's capture queue, immediately before
    /// the bounded teardown sequence moves to this controller's queue.
    func performFinalScheduledCapture() {
        captureOwnedProcesses()
    }

    private func captureOwnedProcesses() {
        #if DEBUG
        let startedNanoseconds = DispatchTime.now().uptimeNanoseconds
        defer {
            let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
            UserTaskProcessTelemetry.recordScheduledCapture(
                durationNanoseconds: nowNanoseconds >= startedNanoseconds
                    ? nowNanoseconds - startedNanoseconds
                    : 0
            )
        }
        #endif
        processGroup?.captureKnownMembers()
        descendantTracker.captureDescendants()
    }

    /// SwiftTerm's explicit `terminate()` cancels its process monitor before
    /// the monitor can call `waitpid`, so Pine becomes responsible for reaping
    /// that exact direct child. `waitpid` cannot target an unrelated reused
    /// PID: after the owned child is reaped it returns `ECHILD` instead.
    private func reapRootAfterTerminationRequest() -> Bool {
        let deadline = DispatchTime.now() + Self.completionWaitPeriod
        var status: Int32 = 0
        repeat {
            let result = Darwin.waitpid(
                rootIdentity.processID,
                &status,
                WNOHANG
            )
            if result == rootIdentity.processID
                || (result == -1 && errno == ECHILD) {
                return true
            }
            Darwin.usleep(10_000)
        } while DispatchTime.now() < deadline
        return false
    }
}
