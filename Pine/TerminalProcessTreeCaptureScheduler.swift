//
//  TerminalProcessTreeCaptureScheduler.swift
//  Pine
//

import Dispatch
import Foundation

/// One shared capture wave for every live terminal process-tree controller.
///
/// Before issue #1718 each terminal owned a utility serial queue with its own
/// 25 ms repeating timer. Every tick independently re-enumerated the system
/// process list once for the shell's process group and once per descendant for
/// children, so N terminals produced N concurrent waves of full libproc scans
/// every 25 ms. This scheduler collapses the N timers into a single shared
/// utility-queue wave: each terminal is captured once per wave (waves are
/// scheduled at a 25 ms cadence; a wave whose total capture time exceeds the
/// period defers the next one), and the passes run serially instead of
/// re-scanning the kernel process list concurrently.
///
/// The wave timer is armed only while at least one controller is registered:
/// it stops when the registry becomes empty and re-arms on the next
/// registration, so a process with no terminals performs no 25 ms polling at
/// all.
///
/// Ordering guarantees:
/// - A controller's scheduled captures and its teardown prologue (unregister
///   plus final capture) are whole blocks on the same serial queue, so the
///   final capture is ordered after every scheduled capture and before any
///   later wave that no longer includes the controller.
/// - The bounded TERM-to-KILL teardown itself runs on the controller's own
///   per-terminal queue, so one slow cleanup cannot starve the captures of
///   other terminals.
nonisolated final class TerminalProcessTreeCaptureScheduler: @unchecked Sendable {
    static let shared = TerminalProcessTreeCaptureScheduler()

    private static let captureInterval: DispatchTimeInterval = .milliseconds(25)
    private static let captureLeeway: DispatchTimeInterval = .milliseconds(5)

    private let captureQueue = DispatchQueue(
        label: "com.pine.terminal-process-tree.capture-wave",
        qos: .utility
    )
    private let registryLock = NSLock()
    private var entries: [ObjectIdentifier: WeakController] = [:]
    private var timer: DispatchSourceTimer?

    private init() {}

    /// Adds the controller to future capture waves. Arms the shared wave
    /// timer if no other controller is registered. A dead weak entry (a
    /// controller deallocated without teardown whose entry was not yet
    /// pruned) does not block re-registration of a controller that reused the
    /// same address.
    func register(_ controller: TerminalProcessTreeController) {
        registryLock.withLock {
            let objectIdentifier = ObjectIdentifier(controller)
            if let existing = entries[objectIdentifier],
               existing.controller != nil {
                return
            }
            entries[objectIdentifier] = WeakController(controller)
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: captureQueue)
            timer.schedule(
                deadline: .now(),
                repeating: Self.captureInterval,
                leeway: Self.captureLeeway
            )
            timer.setEventHandler { [self] in
                runWave()
            }
            self.timer = timer
            timer.activate()
        }
    }

    /// Removes the controller from future waves and takes the final capture
    /// ordered after every scheduled capture of that controller. The
    /// continuation runs on the shared capture queue, strictly after the
    /// final capture. Stops the wave timer if the registry is now empty.
    func assumeOwnershipForTermination(
        _ controller: TerminalProcessTreeController,
        continuation: @escaping @Sendable () -> Void
    ) {
        captureQueue.async { [self] in
            registryLock.withLock {
                _ = entries.removeValue(forKey: ObjectIdentifier(controller))
            }
            stopWaveIfIdle()
            controller.performFinalScheduledCapture()
            continuation()
        }
    }

    private func runWave() {
        #if DEBUG
        Self.waveCount.increment()
        #endif
        let controllers = registryLock.withLock {
            let live = entries.values.compactMap(\.controller)
            if live.count < entries.count {
                entries = entries.filter { $0.value.controller != nil }
            }
            return live
        }
        for controller in controllers {
            controller.performScheduledCapture()
        }
        if controllers.isEmpty {
            stopWaveIfIdle()
        }
    }

    /// Stops the shared wave timer while no controllers remain registered.
    ///
    /// The check-and-stop is atomic under `registryLock`, so a concurrent
    /// `register` can never observe "stopped timer with a live entry": either
    /// it runs before the stop (the stop sees its entry and keeps the timer)
    /// or after it (it sees `timer == nil` and arms a fresh timer).
    private func stopWaveIfIdle() {
        registryLock.withLock {
            guard entries.isEmpty else { return }
            timer?.cancel()
            timer = nil
        }
    }

    #if DEBUG
    private static let waveCount = UserTaskProcessTelemetryCounter()

    /// Observes how many waves ran since process start (test seam, #1718).
    static var waveCountForTesting: UInt64 {
        waveCount.current
    }

    /// Observes whether the shared wave timer is currently stopped (test
    /// seam, #1718).
    static var isIdleForTesting: Bool {
        shared.registryLock.withLock { shared.timer == nil }
    }
    #endif

    private final class WeakController {
        weak var controller: TerminalProcessTreeController?

        init(_ controller: TerminalProcessTreeController) {
            self.controller = controller
        }
    }
}
