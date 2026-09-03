//
//  BoundedMainActorWait.swift
//  PineTests
//
//  Shared bounded wait for conditions that flip on the main actor (#1568).
//

import Foundation

/// Polls a main-actor condition at a short interval under a generous ceiling.
///
/// ## Why the ceiling must be generous
///
/// Swift Testing runs suites in parallel, and every hop back onto the main
/// actor queues behind whatever `@MainActor` neighbours happen to be running.
/// A suite that hosts a SwiftUI view holds the main actor for roughly 80 ms
/// per test, so a wait budget tuned on an idle machine — a few hundred
/// milliseconds — does not measure the code under test. It measures how busy
/// the scheduler was, fails only in a full parallel run, and passes in
/// isolation, which is what makes it expensive to diagnose (#1568).
///
/// A wait for main-actor work therefore has two jobs that must not be
/// conflated:
///
/// - **Completeness** — notice the condition promptly. The 1 ms poll interval
///   does this: the condition is observed within one main-actor turn of it
///   becoming true.
/// - **Stuck detection** — still fail instead of hanging when the operation
///   is genuinely broken. That is all the ceiling is: a tripwire, not a
///   stopwatch. The 5 s default tolerates dozens of hosted-view neighbours
///   while bounding a hung operation.
///
/// Consequences for call sites:
///
/// - Never tune the ceiling down because the test "usually finishes in
///   milliseconds" — that is exactly the idle-machine assumption this helper
///   exists to retire.
/// - If the point of a test is *speed*, the measurement belongs in
///   `PinePerformanceTests`, not in a suite that runs beside arbitrary
///   neighbours.
/// - Never replace a wait with an unconditional `sleep`; either poll the
///   condition with this helper or signal completion explicitly through a
///   continuation.
///
/// - Returns: `true` once the condition held, `false` if the ceiling was
///   reached or the calling task was cancelled. Record the result with
///   `#require`/`#expect` at the call site so a failure carries the caller's
///   source location and intent.
///
///   Cancellation is checked explicitly at the top of every iteration: in a
///   cancelled task `Task.sleep` throws before sleeping at all, and a `try?`
///   would swallow that, turning the poll into a hot spin on the main actor
///   until the ceiling expires. A cancelled caller returns `false`
///   immediately instead (same pattern as the SourceKit-LSP smoke wait).
@MainActor
func waitUntilMainActor(
    _ condition: @MainActor () -> Bool,
    ceiling: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: ceiling)
    while !condition() {
        if Task.isCancelled { return false }
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: pollInterval)
    }
    return true
}
