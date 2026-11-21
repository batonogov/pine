//
//  TerminalProcessTreeController.swift
//  Pine
//

import Darwin
import Dispatch
import Foundation
import os
import SwiftTerm

/// Owns the exact process generation launched for one terminal tab.
///
/// SwiftTerm owns TERM/KILL and reaping for its direct child. Pine owns the
/// identity-qualified descendant tree: the shared capture wave samples it on
/// a 25 ms cadence, then teardown runs a bounded TERM-to-KILL cleanup away
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
    private let swiftTermOwnsRootLifecycle: Bool
    private let cleanupOwnerRegistry: TerminalProcessCleanupOwnerRegistry
    private let lock = NSLock()
    private var rootProcess: LocalProcess?
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
    let workingDirectoryRetention: TerminalWorkingDirectoryRetention
    #if DEBUG
    private let scheduledCaptureCount = UserTaskProcessTelemetryCounter()
    private var cleanupForTesting: (@Sendable () -> Bool)?
    private var deferredCleanupForTesting: (@Sendable () -> Void)?
    private var deferredCleanupWorksForTesting: [@Sendable () -> Void]?

    /// Observes how often the shared wave captured this controller.
    var scheduledCaptureCountForTesting: UInt64 {
        scheduledCaptureCount.current
    }

    /// Pauses/completes the same asynchronous completion path without a PTY.
    init(
        retention: TerminalWorkingDirectoryRetention,
        ownerRegistry: TerminalProcessCleanupOwnerRegistry = .shared,
        cleanupForTesting: @escaping @Sendable () -> Bool,
        deferredCleanupForTesting: (@Sendable () -> Void)? = nil,
        deferredCleanupWorksForTesting: [@Sendable () -> Void]? = nil
    ) {
        rootIdentity = UserTaskProcessIdentity(
            processID: 0, startSeconds: 0, startMicroseconds: 0
        )
        processGroupIdentifier = nil
        processGroup = nil
        descendantTracker = UserTaskDescendantTracker(rootProcessID: 0)
        swiftTermOwnsRootLifecycle = false
        cleanupOwnerRegistry = ownerRegistry
        rootProcess = nil
        stateQueue = DispatchQueue(label: "com.pine.terminal-process-tree.test")
        workingDirectoryRetention = retention
        self.cleanupForTesting = cleanupForTesting
        self.deferredCleanupForTesting = deferredCleanupForTesting
        self.deferredCleanupWorksForTesting = deferredCleanupWorksForTesting
    }
    #endif

    init?(
        rootProcessID: pid_t,
        rootProcess: LocalProcess? = nil,
        ownerRegistry: TerminalProcessCleanupOwnerRegistry = .shared,
        retention: TerminalWorkingDirectoryRetention
    ) {
        guard let rootIdentity = UserTaskProcessInspector.identity(
            for: rootProcessID
        ) else {
            return nil
        }

        self.rootIdentity = rootIdentity
        self.rootProcess = rootProcess
        swiftTermOwnsRootLifecycle = rootProcess != nil
        cleanupOwnerRegistry = ownerRegistry
        workingDirectoryRetention = retention
        // `forkpty` makes its child a session and process-group leader. Never
        // claim a broader inherited group if a future SwiftTerm path changes
        // that invariant; individual descendant identities remain safe.
        let observedGroup = Darwin.getpgid(rootProcessID)
        if observedGroup == rootProcessID {
            processGroupIdentifier = observedGroup
            processGroup = UserTaskProcessGroup(
                identifier: observedGroup,
                signalsLeader: rootProcess == nil
            )
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
        cleanupOwnerRegistry.retain(self)

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
                    descendantTracker.captureDescendants()
                    terminateSwiftTermRootProcess()
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

    /// Application Quit can await deferred cleanup after the ordinary bounded
    /// close fails. Completion publishes the fence release and owner removal;
    /// this wait additionally records successful application termination only
    /// when that completion arrives before the caller's absolute deadline.
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
        cleanupOwnerRegistry.release(self)
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
        let works: [@Sendable () -> Void]
        #if DEBUG
        if let deferredCleanupWorksForTesting {
            works = deferredCleanupWorksForTesting
        } else if let deferredCleanupForTesting {
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

    /// Deferred workers return only after every observed process is gone.
    /// Publish that positive completion before dropping the detached owner;
    /// the bounded `waitForTermination` result remains a separate truth.
    private func publishDeferredCleanupCompletion() {
        workingDirectoryRetention.finishCleanup(succeeded: true)
        cleanupOwnerRegistry.release(self)
    }

    private func terminateSwiftTermRootProcess() {
        guard swiftTermOwnsRootLifecycle else { return }
        let process = lock.withLock {
            defer { rootProcess = nil }
            return rootProcess
        }
        if let process {
            process.terminate(escalatingAfter: process.killEscalationDelay)
        }
    }

    private func finishDeferredRootCleanup() {
        guard rootIdentity.processID > 1 else { return }
        if swiftTermOwnsRootLifecycle {
            while !rootWasReapedBySwiftTerm() {
                Darwin.usleep(10_000)
            }
            return
        }
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
            // The bounded result is the termination truth; deferred completion
            // only releases the owner record, never a success report (#1786).
            terminationSucceeded = succeeded
            terminationFinished = true
        }
        if succeeded {
            cleanupOwnerRegistry.release(self)
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

    /// SwiftTerm retains exclusive signal/waitpid ownership of its direct
    /// child. Pine only observes that child's reap with non-reaping `waitid`.
    /// Directly spawned test workloads keep the original Pine-owned path.
    private func reapRootAfterTerminationRequest() -> Bool {
        let deadline = DispatchTime.now() + Self.completionWaitPeriod
        if swiftTermOwnsRootLifecycle {
            repeat {
                if rootWasReapedBySwiftTerm() { return true }
                Darwin.usleep(10_000)
            } while DispatchTime.now() < deadline
            return rootWasReapedBySwiftTerm()
        }

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

    private func rootWasReapedBySwiftTerm() -> Bool {
        var info = siginfo_t()
        let result = Darwin.waitid(
            P_PID,
            id_t(rootIdentity.processID),
            &info,
            WEXITED | WNOHANG | WNOWAIT
        )
        return result == -1 && errno == ECHILD
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
    #if DEBUG
    private var releaseCounts: [ObjectIdentifier: Int] = [:]
    #endif

    init() {}

    func retain(_ controller: TerminalProcessTreeController) {
        lock.withLock {
            owners[ObjectIdentifier(controller)] = controller
        }
    }

    func release(_ controller: TerminalProcessTreeController) {
        lock.withLock {
            let identifier = ObjectIdentifier(controller)
            _ = owners.removeValue(forKey: identifier)
            #if DEBUG
            releaseCounts[identifier, default: 0] += 1
            #endif
        }
    }

    #if DEBUG
    func releaseCountForTesting(
        _ controller: TerminalProcessTreeController
    ) -> Int {
        lock.withLock { releaseCounts[ObjectIdentifier(controller)] ?? 0 }
    }
    #endif

    /// Detached owners whose cleanup is still in flight.
    var inFlightControllers: [TerminalProcessTreeController] {
        lock.withLock { Array(owners.values) }
    }

    /// Pre-termination barrier input: the attached controllers a Quit
    /// transaction stopped plus every detached in-flight owner, deduplicated
    /// so one owner is waited on once (#1786).
    func applicationTerminationControllers(
        from liveControllers: [TerminalProcessTreeController]
    ) -> [TerminalProcessTreeController] {
        var merged: [TerminalProcessTreeController] = []
        var seen = Set<ObjectIdentifier>()
        for controller in liveControllers
            where seen.insert(ObjectIdentifier(controller)).inserted {
            merged.append(controller)
        }
        for controller in inFlightControllers
            where seen.insert(ObjectIdentifier(controller)).inserted {
            merged.append(controller)
        }
        return merged
    }
}
