//
//  SymbolCoordinator.swift
//  Pine
//
//  Deterministic LSP-first document-symbol selection for #1008.
//

import Foundation

/// Selects one symbol provider for an immutable document revision.
///
/// Regex symbols are computed off the main actor and shown first. A valid,
/// non-empty LSP hierarchy replaces them only when it arrives within the
/// shared 250 ms deadline and the revision is still current. Results are never
/// merged.
nonisolated final class SymbolCoordinator: @unchecked Sendable {
    static let lspDeadline = FoldingCoordinator.lspDeadline

    private let generation = StructuralGeneration()

    /// Starts a new immutable document revision and invalidates older work.
    func beginRevision() -> DocumentRevision {
        DocumentRevision(generation.increment())
    }

    /// Invalidates pending provider work when the navigator closes.
    func invalidate() {
        generation.increment()
    }

    /// Whether a local fallback computed for `revision` may still be shown.
    func isCurrent(_ revision: DocumentRevision) -> Bool {
        generation.current == revision.value
    }

    func refine(
        snapshot: DocumentSnapshot,
        regexSymbols: [DocumentSymbolNode],
        lspProvider: SymbolProviding?
    ) async -> SymbolResolution {
        let issuedGeneration = snapshot.revision.value
        guard generation.current == issuedGeneration else {
            return .stale
        }
        guard let lspProvider,
              lspProvider.canProvide(for: snapshot) else {
            return .resolved(regexSymbols, source: .regex)
        }

        let query: @Sendable () async -> [DocumentSymbolNode]? = {
            await lspProvider.symbols(for: snapshot)
        }
        let outcome = await StructuralDeadlineRace.run(
            deadline: Self.lspDeadline,
            operation: query
        )

        guard generation.current == issuedGeneration else {
            return .stale
        }

        switch outcome {
        case .completed(let symbols):
            guard let symbols, !symbols.isEmpty else {
                return .resolved(regexSymbols, source: .regex)
            }
            return .resolved(symbols, source: .lsp)
        case .timedOut, .cancelled:
            return .resolved(regexSymbols, source: .regex)
        }
    }
}
