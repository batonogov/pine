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

    init(uri: String, text: String, revision: DocumentRevision) {
        self.uri = uri
        self.text = text
        self.revision = revision
    }
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
nonisolated final class FoldGeneration: @unchecked Sendable {
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

// MARK: - Document symbols (step 4 — model prepared; wiring deferred)

/// Coarse symbol classification shared by LSP `documentSymbol` and the regex
/// fallback. The protocol below is defined so the fold and symbol stacks share
/// one provider/fallback policy; hierarchical Symbol Navigator wiring is
/// step 4 of #1008 and is deliberately not implemented in this slice.
nonisolated enum SymbolKind: String, Sendable, Equatable {
    case function
    case `class`
    case `struct`
    case `enum`
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

/// A symbol provider owns document symbols for one revision. Wiring is step 4
/// of #1008; the protocol is declared here so fold and symbol providers share
/// the same fallback semantics once the navigator is made hierarchical.
nonisolated protocol SymbolProviding: Sendable {
    func canProvide(for snapshot: DocumentSnapshot) -> Bool
    func symbols(for snapshot: DocumentSnapshot) async -> [DocumentSymbolNode]?
}
