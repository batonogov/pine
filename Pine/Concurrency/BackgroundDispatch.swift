//
//  BackgroundDispatch.swift
//  Pine
//
//  Created for issue #898 — replaces the repeated
//  `await withCheckedContinuation { DispatchQueue.global(qos: ...).async { ... } }`
//  boilerplate with a single typed helper that can be called from any actor.
//

import Foundation

// MARK: - runOnBackground (non-throwing)

/// Runs `work` on a global dispatch queue at `qos` and bridges the result back
/// to async/await via `withCheckedContinuation`.
///
/// Use this when you need to leave the current actor for CPU-bound or blocking
/// I/O work (process spawning, regex computation, file enumeration) and resume
/// once the result is ready. The closure is `@Sendable`, so callers must pass
/// in pure values rather than capturing actor-isolated state.
///
/// The body runs inside an explicit `autoreleasepool` (#1509). Global dispatch
/// queues install no pool of their own, so without one every autoreleased
/// Foundation/AppKit temporary the body produces — `NSURL`, `NSString`,
/// bridged `CharacterSet`, git and file-enumeration byproducts — lands in
/// libobjc's thread-wide fallback pool and stays alive until the worker thread
/// is destroyed. A full `PineTests` run under `OBJC_DEBUG_MISSING_POOLS=YES`
/// logs thousands of "autoreleased with no pool in place - just leaking"
/// warnings for exactly this reason. Draining per call also keeps each pool
/// small, which bounds the work a single `objc_autoreleasePoolPop` has to do.
///
/// - Parameters:
///   - qos: Quality of service of the global queue. Defaults to `.userInitiated`
///     to match Pine's existing call sites.
///   - work: The synchronous work to perform off the calling actor.
/// - Returns: The value produced by `work`.
@inlinable
func runOnBackground<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @Sendable @escaping () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            // Resume outside the pool: the continuation must not run with this
            // pool still on the stack.
            let value = autoreleasepool { work() }
            continuation.resume(returning: value)
        }
    }
}

// MARK: - runOnBackground (throwing)

/// Throwing variant of `runOnBackground(qos:_:)`. Errors thrown by `work` are
/// propagated through the continuation and surface to the awaiting caller.
///
/// The body runs inside an explicit `autoreleasepool` for the reason described
/// on the non-throwing variant (#1509). The pool drains on the error path too,
/// so a throwing body cannot strand its temporaries on the worker thread.
///
/// - Parameters:
///   - qos: Quality of service of the global queue. Defaults to `.userInitiated`.
///   - work: The synchronous work to perform off the calling actor.
/// - Returns: The value produced by `work`.
/// - Throws: Any error thrown by `work`.
@inlinable
func runOnBackground<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @Sendable @escaping () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            do {
                // Resume outside the pool: the continuation must not run with
                // this pool still on the stack.
                let result = try autoreleasepool { try work() }
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
