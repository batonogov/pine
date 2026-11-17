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
    /// Total deferred-cleanup work items, frozen before dispatch; the
    /// returned counter advances per worker. The last return publishes the
    /// deferred outcome (#1786).
    private var deferredWorkScheduled = 0
    private var deferredWorkCompleted = 0
    /// Set once the deferred outcome was published so a bounded failure
    /// published later cannot clobber an already-completed success (#1786).
    private var deferredCompletionPublished = false
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
        // Retain the cleanup owner independently of the tab, pane, or manager
        // that started it. A tab closed before application Quit must not drop
        // an in-flight TERM-to-KILL cleanup from the pre-termination barrier
        // (#1786).
        TerminalProcessCleanupOwnerRegistry.shared.retain(self)

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
    /// the ordinary bounded close fails. The caller supplies the outer
    /// deadline. A drained deferred phase reports its published outcome
    /// rather than assuming success, so a still-pending cleanup fails the
    /// termination truthfully (#1786).
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
        return lock.withLock { terminationSucceeded }
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
        let works: [@Sendable () -> Void]
        #if DEBUG
        if let deferredCleanupForTesting {
            works = [deferredCleanupForTesting]
        } else {
            works = deferredProductionWorks(rootNeedsCleanup: rootNeedsCleanup)
        }
        #else
        works = deferredProductionWorks(rootNeedsCleanup: rootNeedsCleanup)
        #endif
        // Freeze the total before any block is dispatched, so a fast
        // finishing early worker cannot publish while later works are still
        // unscheduled (#1786).
        lock.withLock { deferredWorkScheduled = works.count }
        for work in works {
            scheduleDeferredCleanup(work)
        }
    }

    private func deferredProductionWorks(
        rootNeedsCleanup: Bool
    ) -> [@Sendable () -> Void] {
        var works: [@Sendable () -> Void] = [
            { [processGroup] in
                processGroup?.finishDeferredCleanup()
            },
            { [descendantTracker] in
                descendantTracker.finishDeferredCleanup()
            },
        ]
        if rootNeedsCleanup {
            works.append { [self] in
                finishDeferredRootCleanup()
            }
        }
        return works
    }

    private func scheduleDeferredCleanup(
        _ work: @escaping @Sendable () -> Void
    ) {
        deferredCleanupCompletion.enter()
        Self.deferredCleanupQueue.async { [self] in
            work()
            let isLastCompletion = lock.withLock {
                deferredWorkCompleted += 1
                return deferredWorkCompleted == deferredWorkScheduled
            }
            if isLastCompletion {
                publishDeferredCleanupCompletion()
            }
            // Leave after the publish so a drained group always carries the
            // completed outcome and the fence release (#1786).
            deferredCleanupCompletion.leave()
        }
    }

    /// Deferred workers return only after every observed process is gone, so
    /// the last return is a truthful success. Publish it, release the
    /// cwd/worktree fence, and drop the detached-owner record exactly once —
    /// without requiring an application Quit (#1786).
    private func publishDeferredCleanupCompletion() {
        workingDirectoryRetention.finishCleanup(succeeded: true)
        lock.withLock {
            deferredCompletionPublished = true
            terminationSucceeded = true
        }
        TerminalProcessCleanupOwnerRegistry.shared.release(self)
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
            // Deferred work that already completed cannot be demoted by the
            // bounded result published against it (#1786).
            terminationSucceeded = succeeded || deferredCompletionPublished
            terminationFinished = true
        }
        if succeeded {
            TerminalProcessCleanupOwnerRegistry.shared.release(self)
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

/// Detached owner records for in-flight terminal process-tree cleanup,
/// independent of the view, tab, or manager that started the cleanup.
///
/// A record is retained when the bounded TERM-to-KILL teardown starts and is
/// released exactly once when the cleanup actually completes (bounded
/// success, or bounded failure plus completed deferred cleanup). Retention
/// fails closed until that outcome is established: a D-state descendant can
/// outlive SIGKILL, so the record is never dropped on a deadline alone.
/// Application Quit reads the records so a tab or project closed before Quit
/// cannot drop an owner whose KILL/reaping is still pending (#1786).
nonisolated final class TerminalProcessCleanupOwnerRegistry:
    @unchecked Sendable {
    static let shared = TerminalProcessCleanupOwnerRegistry()

    private let lock = NSLock()
    private var owners: [ObjectIdentifier: TerminalProcessTreeController] = [:]

    private init() {}

    func retain(_ controller: TerminalProcessTreeController) {
        lock.withLock {
            owners[ObjectIdentifier(controller)] = controller
        }
    }

    func release(_ controller: TerminalProcessTreeController) {
        lock.withLock {
            _ = owners.removeValue(forKey: ObjectIdentifier(controller))
        }
    }

    /// Detached owners whose cleanup is still in flight.
    var inFlightControllers: [TerminalProcessTreeController] {
        lock.withLock { Array(owners.values) }
    }

    /// Pre-termination barrier input: the attached controllers a Quit
    /// transaction stopped plus every detached in-flight owner, deduplicated
    /// so one owner is waited on once (#1786).
    static func applicationTerminationControllers(
        from liveControllers: [TerminalProcessTreeController]
    ) -> [TerminalProcessTreeController] {
        var merged: [TerminalProcessTreeController] = []
        var seen = Set<ObjectIdentifier>()
        for controller in liveControllers
            where seen.insert(ObjectIdentifier(controller)).inserted {
            merged.append(controller)
        }
        for controller in shared.inFlightControllers
            where seen.insert(ObjectIdentifier(controller)).inserted {
            merged.append(controller)
        }
        return merged
    }
}
