//
//  FoldingCoordinatorTests.swift
//  PineTests
//
//  Issue #1008 — tests for the LSP-first structural folding orchestrator.
//  Covers provider selection, fallback paths, the 250 ms deadline,
//  cancellation, and stale-generation discard.
//

import Foundation
import Testing

@testable import Pine

@Suite("FoldingCoordinator Tests")
@MainActor
struct FoldingCoordinatorTests {

    // MARK: - Fixtures

    /// A snapshot of a small bracketed document.
    private func snapshot(_ text: String = "func a() {\n    x()\n}\nfunc b() {\n    y()\n}") -> DocumentSnapshot {
        DocumentSnapshot(uri: "file:///test.swift", text: text, revision: DocumentRevision(1))
    }

    private func bracketRanges(_ text: String) -> [FoldableRange] {
        FoldRangeCalculator.calculate(text: text)
    }

    // MARK: - No LSP provider → bracket stands

    @Test("No LSP provider resolves to bracket ranges")
    func noLSPProviderResolvesToBracket() async {
        let coordinator = FoldingCoordinator(lspProvider: nil)
        let snap = snapshot()
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    // MARK: - LSP provider wins with valid ranges

    @Test("LSP provider wins when it returns valid ranges")
    func lspWinsWithValidRanges() async {
        let snap = snapshot()
        let lspRanges = [
            LSPFoldingRange(startLine: 0, endLine: 2),   // func a
            LSPFoldingRange(startLine: 3, endLine: 5)    // func b
        ]
        let provider = StubFoldProvider(ranges: lspRanges)
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        guard case .resolved(let ranges, .lsp) = resolution else {
            Issue.record("Expected .lsp resolution, got \(resolution)")
            return
        }
        // LSP line 0→2 maps to Pine lines 1→3; line 3→5 maps to 4→6.
        #expect(ranges.count == 2)
        #expect(ranges[0].startLine == 1)
        #expect(ranges[0].endLine == 3)
        #expect(ranges[1].startLine == 4)
        #expect(ranges[1].endLine == 6)
    }

    // MARK: - LSP declines (nil) → bracket fallback

    @Test("LSP returning nil falls back to bracket")
    func lspNilFallsBackToBracket() async {
        let snap = snapshot()
        let provider = StubFoldProvider(ranges: nil)
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    @Test("LSP returning empty list falls back to bracket")
    func lspEmptyFallsBackToBracket() async {
        let snap = snapshot()
        let provider = StubFoldProvider(ranges: [])
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    // MARK: - Invalid LSP ranges → bracket fallback

    @Test("LSP ranges out of bounds fall back to bracket")
    func lspInvalidFallsBackToBracket() async {
        let snap = snapshot()
        // Lines far beyond the 6-line document.
        let provider = StubFoldProvider(ranges: [LSPFoldingRange(startLine: 100, endLine: 200)])
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    @Test("LSP single-line ranges are skipped; all-invalid falls back")
    func lspSingleLineRangesSkipped() async {
        let snap = snapshot()
        // startLine == endLine is not multi-line → invalid.
        let provider = StubFoldProvider(ranges: [LSPFoldingRange(startLine: 0, endLine: 0)])
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    @Test("Mixed valid/invalid LSP ranges keep only valid ones")
    func lspMixedValidInvalid() async {
        let snap = snapshot()
        let provider = StubFoldProvider(ranges: [
            LSPFoldingRange(startLine: 0, endLine: 2),      // valid
            LSPFoldingRange(startLine: 0, endLine: 0),      // single-line, invalid
            LSPFoldingRange(startLine: 99, endLine: 100)    // out of bounds, invalid
        ])
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        guard case .resolved(let ranges, .lsp) = resolution else {
            Issue.record("Expected .lsp, got \(resolution)")
            return
        }
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 1 && ranges[0].endLine == 3)
    }

    // MARK: - Timeout → bracket fallback

    @Test("LSP slower than the deadline falls back to bracket")
    func lspTimeoutFallsBackToBracket() async {
        let snap = snapshot()
        // Sleep well past the 250 ms deadline.
        let provider = StubFoldProvider(ranges: [], delaySeconds: 2.0)
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        #expect(resolution == .resolved(brackets, source: .bracket))
    }

    // MARK: - Stale generation → discarded

    @Test("Stale generation discards a winning LSP result")
    func staleDiscardsLSPResult() async {
        let snap = snapshot()
        let lspRanges = [LSPFoldingRange(startLine: 0, endLine: 2)]
        let provider = StubFoldProvider(ranges: lspRanges, delaySeconds: 0.1)
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        // Start refine; it captures its generation and enters the race.
        let resolutionTask = Task {
            await coordinator.refine(snapshot: snap, bracketRanges: brackets)
        }
        // Let refine capture its generation and enter the race before we
        // invalidate (the provider's delay keeps the race pending).
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.invalidate()
        let resolution = await resolutionTask.value

        #expect(resolution == .stale)
    }

    @Test("A fresh generation keeps a winning LSP result")
    func freshGenerationKeepsLSPResult() async {
        let snap = snapshot()
        let lspRanges = [LSPFoldingRange(startLine: 0, endLine: 2)]
        let provider = StubFoldProvider(ranges: lspRanges)
        let coordinator = FoldingCoordinator(lspProvider: provider)
        let brackets = bracketRanges(snap.text)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: brackets)

        if case .stale = resolution {
            Issue.record("Should not be stale for a current generation")
        }
    }

    // MARK: - Normalisation edge cases

    @Test("CRLF lines normalise correctly")
    func crlfLines() async {
        let text = "func a() {\r\n    x()\r\n}\r\n"
        let snap = DocumentSnapshot(uri: "file:///t", text: text, revision: DocumentRevision(1))
        let lspRanges = [LSPFoldingRange(startLine: 0, endLine: 2)]
        let provider = StubFoldProvider(ranges: lspRanges)
        let coordinator = FoldingCoordinator(lspProvider: provider)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: [])

        guard case .resolved(let ranges, .lsp) = resolution else {
            Issue.record("Expected .lsp, got \(resolution)")
            return
        }
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 1 && ranges[0].endLine == 3)
    }

    @Test("Emoji/CJK text does not crash normalisation")
    func emojiCJK() async {
        let text = "func 😀() {\n    let 日本 = \"🇯🇵\"\n}\n"
        let snap = DocumentSnapshot(uri: "file:///t", text: text, revision: DocumentRevision(1))
        let lspRanges = [LSPFoldingRange(startLine: 0, endLine: 2)]
        let provider = StubFoldProvider(ranges: lspRanges)
        let coordinator = FoldingCoordinator(lspProvider: provider)

        let resolution = await coordinator.refine(snapshot: snap, bracketRanges: [])

        guard case .resolved(let ranges, .lsp) = resolution else {
            Issue.record("Expected .lsp, got \(resolution)")
            return
        }
        #expect(ranges.count == 1)
    }
}

// MARK: - Test doubles

/// A controllable fold provider for coordinator tests. Returns a fixed result
/// after an optional delay.
private nonisolated final class StubFoldProvider: FoldRangeProviding, @unchecked Sendable {
    private let ranges: [LSPFoldingRange]?
    private let delaySeconds: TimeInterval

    init(ranges: [LSPFoldingRange]?, delaySeconds: TimeInterval = 0) {
        self.ranges = ranges
        self.delaySeconds = delaySeconds
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool { true }

    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]? {
        if delaySeconds > 0 {
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
        guard let ranges else { return nil }
        return FoldingCoordinator.normalize(ranges, snapshot: snapshot)
    }
}
