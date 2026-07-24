//
//  StructuralProviders.swift
//  Pine
//
//  Issue #1008 — LSP-first structural intelligence (ADR 0001, #1182).
//
//  Defines the normalised, provider-agnostic models and protocols consumed by
//  `FoldRangeCalculator`, `SymbolNavigatorView`, and bracket matching. These
//  seams let one structural provider own a feature for a single immutable
//  document revision, with deterministic fallback to the local calculator.
//
//  All types are pure data/protocol definitions with no new dependency.
//  `nonisolated` opts out of the project-wide MainActor default isolation so
//  providers can be queried off the main thread.
//

import Foundation

// MARK: - Document identity

/// A monotonic document revision token. Structural providers and the folding
/// coordinator compare a captured revision against the live generation before
/// applying results, discarding anything computed against stale text.
nonisolated struct DocumentRevision: Hashable, Sendable {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }
}

/// An immutable snapshot of a document at a specific revision. Structural
/// providers analyse this exact text — never the live, mutable editor buffer.
/// Positions and ranges are UTF-16 code-unit based, matching
/// `NSString`/`NSTextView`.
nonisolated struct DocumentSnapshot: Sendable, Equatable {
    /// The document URI (e.g. "file://...") — identifies the file, not the
    /// revision.
    let uri: String
    /// The full document text captured at this revision.
    let text: String
    /// Monotonic revision; consumers compare this against the current
    /// generation before applying results.
    let revision: DocumentRevision
}

// MARK: - Fold provider protocol

/// A structural-intelligence provider that owns fold ranges for one immutable
/// document revision.
///
/// Provider results are never merged: the coordinator selects exactly one
/// provider's output per revision (ADR 0001). A provider returns `nil` to
/// defer to the next provider in the chain (empty result, unsupported
/// language, transient error, or missing capability).
///
/// Conformers must be `Sendable` so they can be queried off the main thread.
nonisolated protocol FoldRangeProviding: Sendable {
    /// Whether this provider can serve the given document. Called before
    /// `foldRanges(for:)`; returning `false` defers to the next provider
    /// without issuing a request.
    func canProvide(for snapshot: DocumentSnapshot) -> Bool

    /// Returns fold ranges for the snapshot, or `nil` to defer to the next
    /// provider. Never throws — surface failures as `nil` so the coordinator
    /// can fall back deterministically.
    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]?
}

// MARK: - Generation token

/// Thread-safe generation counter for discarding stale structural results.
///
/// The editor bumps the generation whenever the document text changes; a
/// provider result computed against an earlier generation is discarded before
/// it is applied, so an in-flight LSP reply can never overwrite newer edits.
nonisolated final class StructuralGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    /// The current generation. A request is stale when its captured
    /// generation is less than this value.
    var current: Int {
        lock.withLock { value }
    }

    /// Bumps the generation, invalidating every request issued before this
    /// call. Returns the new generation.
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    /// `true` when `generation` was issued before the current generation —
    /// i.e. the result is stale and must be discarded.
    func isStale(_ generation: Int) -> Bool {
        lock.withLock { generation < value }
    }
}

/// Compatibility name retained for the folding slice introduced before the
/// generation token became shared by every structural feature.
typealias FoldGeneration = StructuralGeneration

// MARK: - Shared provider deadline

/// Result of racing a structural provider against its interactive deadline.
nonisolated enum StructuralRaceOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    case cancelled
}

/// Timing captured at the instant the one-shot gate resolves. Keeping this
/// separate from caller resumption makes deadline observability accurate even
/// when the caller's executor is temporarily saturated.
nonisolated struct StructuralRaceMeasurement<Value: Sendable>: Sendable {
    let outcome: StructuralRaceOutcome<Value>
    let elapsed: Duration
}

/// Runs a provider without allowing a non-cooperative implementation to extend
/// Pine's 250 ms structural deadline.
///
/// A task group cannot enforce that bound because leaving its scope waits for
/// every child, including one that ignores cancellation. This one-shot gate
/// resumes the caller as soon as either the provider, deadline, or parent
/// cancellation wins, then cancels the remaining tasks.
nonisolated enum StructuralDeadlineRace {
    /// Dedicated high-QoS timer queue. A cooperative `Task.sleep` timeout can
    /// be starved for seconds when thousands of tests or provider tasks fill
    /// the Swift executor; the UI deadline must remain a wall-clock bound.
    private static let timerQueue = DispatchQueue(
        label: "com.pine.structural-deadline",
        qos: .userInteractive
    )

    private final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let clock = ContinuousClock()
        private let started: ContinuousClock.Instant
        private var measurement: StructuralRaceMeasurement<Value>?
        private var continuation:
            CheckedContinuation<StructuralRaceMeasurement<Value>, Never>?
        private var queryTask: Task<Void, Never>?
        private var timeoutWorkItem: DispatchWorkItem?

        init() {
            started = clock.now
        }

        func install(
            _ continuation:
                CheckedContinuation<StructuralRaceMeasurement<Value>, Never>
        ) {
            let completed: StructuralRaceMeasurement<Value>? = lock.withLock {
                if let measurement {
                    return measurement
                }
                self.continuation = continuation
                return nil
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }

        func install(
            queryTask: Task<Void, Never>,
            timeoutWorkItem: DispatchWorkItem
        ) {
            let shouldCancel = lock.withLock {
                if measurement != nil {
                    return true
                }
                self.queryTask = queryTask
                self.timeoutWorkItem = timeoutWorkItem
                return false
            }
            if shouldCancel {
                queryTask.cancel()
                timeoutWorkItem.cancel()
            }
        }

        func resolve(_ outcome: StructuralRaceOutcome<Value>) {
            let measurement = StructuralRaceMeasurement(
                outcome: outcome,
                elapsed: started.duration(to: clock.now)
            )
            let completion: (
                CheckedContinuation<StructuralRaceMeasurement<Value>, Never>?,
                Task<Void, Never>?,
                DispatchWorkItem?
            )? = lock.withLock {
                guard self.measurement == nil else { return nil }
                self.measurement = measurement
                let completion = (
                    continuation,
                    queryTask,
                    timeoutWorkItem
                )
                continuation = nil
                queryTask = nil
                timeoutWorkItem = nil
                return completion
            }
            guard let completion else { return }
            completion.1?.cancel()
            completion.2?.cancel()
            completion.0?.resume(returning: measurement)
        }
    }

    static func run<Value: Sendable>(
        deadline: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> StructuralRaceOutcome<Value> {
        await runMeasured(
            deadline: deadline,
            operation: operation
        ).outcome
    }

    /// The same race with gate-resolution timing for diagnostics and tests.
    /// `elapsed` excludes any delay before the caller's executor resumes.
    static func runMeasured<Value: Sendable>(
        deadline: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> StructuralRaceMeasurement<Value> {
        let gate = Gate<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let queryTask = Task.detached(priority: .userInitiated) {
                    gate.resolve(.completed(await operation()))
                }
                let timeoutWorkItem = DispatchWorkItem {
                    gate.resolve(.timedOut)
                }
                gate.install(
                    queryTask: queryTask,
                    timeoutWorkItem: timeoutWorkItem
                )
                timerQueue.asyncAfter(
                    deadline: .now() + dispatchInterval(for: deadline),
                    execute: timeoutWorkItem
                )
            }
        } onCancel: {
            gate.resolve(.cancelled)
        }
    }

    private static func dispatchInterval(
        for duration: Duration
    ) -> DispatchTimeInterval {
        let components = duration.components
        let nanoseconds =
            Double(components.seconds) * 1_000_000_000
            + Double(components.attoseconds) / 1_000_000_000
        let bounded = min(
            Double(Int.max),
            max(0, nanoseconds.rounded(.up))
        )
        return .nanoseconds(Int(bounded))
    }
}

// MARK: - Coordinator result types

/// Which provider produced a resolved fold set. Used for observability and
/// tests; never affects behaviour after resolution.
nonisolated enum FoldSource: Equatable, Sendable {
    /// The universal bracket-pair calculator (always available).
    case bracket
    /// A richer structural provider (LSP `textDocument/foldingRange`).
    case lsp
}

/// The outcome of a structural folding request.
nonisolated enum FoldResolution: Equatable, Sendable {
    /// Fold ranges resolved by the owning provider for this revision.
    case resolved([FoldableRange], source: FoldSource)
    /// The request was superseded by a newer one (stale generation); the
    /// caller must discard this result and keep whatever it currently shows.
    case stale
}

// MARK: - Document symbols

/// Coarse symbol classification shared by LSP `documentSymbol` and the regex
/// fallback.
nonisolated enum SymbolKind: String, Sendable, Equatable {
    case function
    case `class`
    case `struct`
    case `enum`
    case interface
    case namespace
    case property
    case variable
    case other
}

/// A hierarchical document symbol. Normalised so the Symbol Navigator and a
/// future structural provider share one model. UTF-16 `NSRange` based.
nonisolated struct DocumentSymbolNode: Sendable, Equatable {
    let name: String
    let kind: SymbolKind
    /// Full span of the symbol (UTF-16 code units).
    let range: NSRange
    /// The span to select when navigating to the symbol.
    let selectionRange: NSRange
    let children: [DocumentSymbolNode]
}

/// A symbol provider owns document symbols for one revision.
nonisolated protocol SymbolProviding: Sendable {
    func canProvide(for snapshot: DocumentSnapshot) -> Bool
    func symbols(for snapshot: DocumentSnapshot) async -> [DocumentSymbolNode]?
}

/// Which provider produced a resolved symbol tree.
nonisolated enum SymbolSource: Equatable, Sendable {
    case regex
    case lsp
}

/// The outcome of a structural symbol request.
nonisolated enum SymbolResolution: Equatable, Sendable {
    case resolved([DocumentSymbolNode], source: SymbolSource)
    case stale
}

// MARK: - Brackets

/// Immutable input for bounded bracket matching. Syntax-derived comment and
/// string ranges are captured with the same text revision as the cursor.
nonisolated struct BracketSnapshot: Sendable, Equatable {
    let document: DocumentSnapshot
    let cursorPosition: Int
    let skipRanges: [NSRange]
}

/// Provider seam for bracket navigation/highlighting. The production provider
/// remains Pine's bounded local matcher; this seam keeps its coordinates tied
/// to the same immutable snapshot model as folds and symbols.
nonisolated protocol BracketProviding: Sendable {
    func canProvide(for snapshot: DocumentSnapshot) -> Bool
    func highlight(for snapshot: BracketSnapshot) -> BracketHighlightResult?
}
