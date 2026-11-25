//
//  StructuralProviders.swift
//  Pine
//
//  Issue #1008 — structural intelligence (ADR 0001, #1182).
//
//  Defines the normalised, provider-agnostic models and protocols consumed by
//  bracket matching. These seams let one structural provider own a feature for
//  a single immutable document revision, with deterministic fallback to the
//  local calculator.
//
//  All types are pure data/protocol definitions with no new dependency.
//  `nonisolated` opts out of the project-wide MainActor default isolation so
//  providers can be queried off the main thread.
//

import Foundation

// MARK: - Document identity

/// A monotonic document revision token. Structural providers and their
/// coordinators compare a captured revision against the live generation before
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

// MARK: - Generation token

/// Thread-safe generation counter for discarding stale structural results.
///
/// The editor bumps the generation whenever the document text changes; a
/// provider result computed against an earlier generation is discarded before
/// it is applied, so an in-flight result can never overwrite newer edits.
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
/// to the same immutable snapshot model as folds.
nonisolated protocol BracketProviding: Sendable {
    func canProvide(for snapshot: DocumentSnapshot) -> Bool
    func highlight(for snapshot: BracketSnapshot) -> BracketHighlightResult?
}
