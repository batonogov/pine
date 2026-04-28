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
            continuation.resume(returning: work())
        }
    }
}

// MARK: - runOnBackground (throwing)

/// Throwing variant of `runOnBackground(qos:_:)`. Errors thrown by `work` are
/// propagated through the continuation and surface to the awaiting caller.
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
                let result = try work()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
