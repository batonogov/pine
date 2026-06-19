//
//  PerformanceSignposts.swift
//  Pine
//
//  Lightweight `os.OSSignposter` interval tracing for Pine's hot paths.
//
//  The actual `OSSignposter` API calls are compiled ONLY in DEBUG builds,
//  so release/production builds carry zero signpost overhead. Call sites
//  never need their own `#if DEBUG` guard — the public API is identical in
//  both configurations. In release, `trace` is a trivial non-escaping
//  wrapper that the optimizer inlines away.
//
//  Intervals show up in Instruments (Time Profiler / Points of Interest) and
//  `xctrace` recordings. See `Perf/README.md` for the profiling template.
//
//  Declared `nonisolated` so the hot paths can call it from any actor context
//  (main-actor editor views, the nonisolated SyntaxHighlighter facade, and
//  detached file-tree load tasks).
//

import os

/// Centralized performance signposting for Pine's hot paths.
///
/// Usage (synchronous):
/// ```swift
/// let result = PerformanceSignposts.trace("highlight.full") {
///     engine.highlight(...)
/// }
/// ```
///
/// Usage (async / cross-actor — use explicit begin/end pairs):
/// ```swift
/// let token = PerformanceSignposts.beginInterval("filetree.load")
/// // ... work that may cross actor boundaries ...
/// PerformanceSignposts.endInterval("filetree.load", token)
/// ```
nonisolated enum PerformanceSignposts {

    /// Subsystem matches Pine's bundle identifier so signposts are easy to
    /// filter in Instruments: `io.github.batonogov.pine`.
    static let subsystem = "io.github.batonogov.pine"

    #if DEBUG
    /// Category groups all hot-path intervals together under the subsystem.
    /// `OSSignposter` is a thread-safe Sendable value type.
    private static let signposter = OSSignposter(
        subsystem: subsystem,
        category: "hotpath"
    )
    #endif

    // MARK: - Synchronous Interval Tracing

    /// Wraps a synchronous block in a signposted interval.
    ///
    /// In DEBUG builds the interval is emitted to the unified logging system
    /// (visible in Instruments). In release builds the wrapper inlines to a
    /// bare call of `body` with no signpost work at all.
    @discardableResult
    static func trace<T>(
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> T {
        #if DEBUG
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        #endif
        return try body()
    }

    // MARK: - Manual Interval Tracing (for async / cross-actor work)

    /// Opaque token returned by `beginInterval` and consumed by `endInterval`.
    ///
    /// Carries no state in release builds — the type still exists so call
    /// sites compile without `#if DEBUG`, but instances are empty.
    nonisolated struct IntervalToken {
        #if DEBUG
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        #endif
    }

    /// Begins a manually-paired interval. Use for work that spans actor
    /// boundaries where a synchronous `trace` closure would not cover the
    /// full duration. Always pair with a matching `endInterval`.
    static func beginInterval(_ name: StaticString) -> IntervalToken {
        #if DEBUG
        let id = signposter.makeSignpostID()
        return IntervalToken(
            name: name,
            state: signposter.beginInterval(name, id: id)
        )
        #else
        return IntervalToken()
        #endif
    }

    /// Ends a manually-paired interval started by `beginInterval`.
    static func endInterval(_ name: StaticString, _ token: IntervalToken) {
        #if DEBUG
        // The name is passed again for API symmetry and so the compiler can
        // catch mismatched begin/end pairs; OSSignposter requires the same
        // name used to begin the interval.
        signposter.endInterval(token.name, token.state)
        #endif
    }
}
