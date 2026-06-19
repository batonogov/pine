//
//  TerminalSessionBridgeTests.swift
//  PineTests
//
//  Unit tests for the pure helpers extracted from `TerminalSession.swift`
//  (issue #997). These construct the helpers directly — no NSView, no live
//  SwiftTerm `LocalProcessTerminalView`, no `Task.detached` — so the
//  previously inlined arithmetic is covered without AppKit lifecycle.
//
//  Two helpers are covered here:
//    - `TerminalBufferSearch` — the buffer-scanning algorithm pulled out of
//      `TerminalTab.search(for:)`.
//    - `TerminalScrollEventInfo` — the scroll-delta / phase-boundary / intercept
//      decision pulled out of `TerminalContainerView.installScrollMonitor`.
//
//  Note on `TerminalScrollEventInfo.init(event:)`: that initializer is a
//  four-line property mapping from an `NSEvent`. The macOS 26 SDK does not
//  expose a reliable public constructor for synthetic `scrollWheel` events
//  (the `NSEvent(scrollWheelEventWith:)` / `scrollWheelEvent(with:)` APIs are
//  unavailable), and the existing `TerminalScrollForwardingTests` likewise
//  avoid constructing real scroll-wheel `NSEvent`s. The decision logic that
//  actually matters is therefore exercised through the scalar initializer
//  below, mirroring how `MouseScrollForwarder` (the residual-delta helper
//  from milestone 10) is already tested.
//

import Testing
import Foundation
@testable import Pine

@Suite("TerminalSession Bridge Tests")
@MainActor
struct TerminalSessionBridgeTests {

    // MARK: - TerminalBufferSearch

    @Test("scan on empty buffer returns no matches and counts one row")
    func scanEmptyBuffer() {
        // `"".split(separator:"\n", omittingEmptySubsequences:false)` yields a
        // single empty substring, so totalRows is 1 (matches the historical
        // inlined behaviour). Empty query is never passed by the caller.
        let result = TerminalBufferSearch.scan(bufferText: "", query: "x", caseSensitive: false)
        #expect(result.matches.isEmpty)
        #expect(result.totalRows == 1)
    }

    @Test("scan with no matches returns empty list and correct row count")
    func scanNoMatches() {
        let result = TerminalBufferSearch.scan(
            bufferText: "hello world\nfoo bar",
            query: "xyz",
            caseSensitive: false
        )
        #expect(result.matches.isEmpty)
        #expect(result.totalRows == 2)
    }

    @Test("scan finds a single match at the start of a line")
    func scanSingleMatchAtStart() {
        let result = TerminalBufferSearch.scan(bufferText: "hello world", query: "hello", caseSensitive: false)
        #expect(result.matches.count == 1)
        let match = result.matches[0]
        #expect(match.row == 0)
        #expect(match.col == 0)
        #expect(match.length == 5)
        #expect(result.totalRows == 1)
    }

    @Test("scan finds a match offset from the start of a line")
    func scanMatchOffsetFromStart() {
        let result = TerminalBufferSearch.scan(bufferText: "hello world", query: "world", caseSensitive: false)
        #expect(result.matches.count == 1)
        let match = result.matches[0]
        #expect(match.row == 0)
        #expect(match.col == 6)
        #expect(match.length == 5)
    }

    @Test("scan finds multiple non-overlapping matches on the same line")
    func scanMultipleMatchesSameLine() {
        let result = TerminalBufferSearch.scan(bufferText: "abc abc abc", query: "abc", caseSensitive: false)
        #expect(result.matches.count == 3)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[1].col == 4)
        #expect(result.matches[2].col == 8)
        for match in result.matches {
            #expect(match.length == 3)
            #expect(match.row == 0)
        }
    }

    @Test("scan matches do not overlap (stepping past the previous match)")
    func scanOverlappingQueryStepsNonOverlapping() {
        // "aaaa" with query "aa": first match at 0..<2, next search resumes at
        // index 2, second match at 2..<4 → exactly 2 matches, not 3.
        let result = TerminalBufferSearch.scan(bufferText: "aaaa", query: "aa", caseSensitive: false)
        #expect(result.matches.count == 2)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[1].col == 2)
        #expect(result.matches[0].length == 2)
        #expect(result.matches[1].length == 2)
    }

    @Test("scan reports matches across multiple rows in reading order")
    func scanAcrossRows() {
        let result = TerminalBufferSearch.scan(
            bufferText: "hello\nhello\nhello",
            query: "hello",
            caseSensitive: false
        )
        #expect(result.matches.count == 3)
        #expect(result.totalRows == 3)
        #expect(result.matches[0].row == 0)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[0].length == 5)
        #expect(result.matches[1].row == 1)
        #expect(result.matches[1].col == 0)
        #expect(result.matches[2].row == 2)
        #expect(result.matches[2].col == 0)
    }

    @Test("scan is case-insensitive by default")
    func scanCaseInsensitiveByDefault() {
        let result = TerminalBufferSearch.scan(
            bufferText: "Hello HELLO hello",
            query: "hello",
            caseSensitive: false
        )
        #expect(result.matches.count == 3)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[1].col == 6)
        #expect(result.matches[2].col == 12)
    }

    @Test("scan respects the case-sensitive flag")
    func scanCaseSensitive() {
        let result = TerminalBufferSearch.scan(
            bufferText: "Hello HELLO hello",
            query: "hello",
            caseSensitive: true
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].row == 0)
        #expect(result.matches[0].col == 12)
        #expect(result.matches[0].length == 5)
    }

    @Test("scan case-sensitive matches only the exact-case occurrences")
    func scanCaseSensitiveMixedCase() {
        let result = TerminalBufferSearch.scan(
            bufferText: "AbC abc ABC",
            query: "abc",
            caseSensitive: true
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].col == 4)
    }

    @Test("scan preserves empty rows in the row index and totalRows count")
    func scanPreservesEmptyRows() {
        // The middle empty row must still count toward totalRows and the row
        // index of the trailing match must be 2 (not 1). This guards the
        // `omittingEmptySubsequences: false` contract.
        let result = TerminalBufferSearch.scan(bufferText: "a\n\nb", query: "b", caseSensitive: false)
        #expect(result.matches.count == 1)
        #expect(result.matches[0].row == 2)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[0].length == 1)
        #expect(result.totalRows == 3)
    }

    @Test("scan treats a trailing newline as an extra empty row")
    func scanTrailingNewline() {
        let result = TerminalBufferSearch.scan(bufferText: "abc\n", query: "abc", caseSensitive: false)
        #expect(result.matches.count == 1)
        #expect(result.matches[0].row == 0)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[0].length == 3)
        #expect(result.totalRows == 2)
    }

    @Test("scan finds a match at the end of a line")
    func scanMatchAtEndOfLine() {
        let result = TerminalBufferSearch.scan(bufferText: "hello", query: "o", caseSensitive: false)
        #expect(result.matches.count == 1)
        #expect(result.matches[0].row == 0)
        #expect(result.matches[0].col == 4)
        #expect(result.matches[0].length == 1)
    }

    @Test("scan returns no matches when the query is longer than the buffer")
    func scanQueryLongerThanLine() {
        let result = TerminalBufferSearch.scan(bufferText: "ab", query: "abcd", caseSensitive: false)
        #expect(result.matches.isEmpty)
        #expect(result.totalRows == 1)
    }

    @Test("scan computes columns by grapheme cluster (String distance)")
    func scanUnicodeColumnsAreGraphemeBased() {
        // Columns come from `String.distance(from:to:)`, which counts Character
        // (grapheme cluster) positions, not UTF-8/UTF-16 units. Each Greek
        // letter is one grapheme, so γ is at column 2.
        let result = TerminalBufferSearch.scan(bufferText: "αβγδε", query: "γ", caseSensitive: false)
        #expect(result.matches.count == 1)
        #expect(result.matches[0].col == 2)
        #expect(result.matches[0].length == 1)
    }

    @Test("scan case-insensitive match keeps the match length equal to the query length")
    func scanCaseInsensitiveLengthMatchesQuery() {
        let result = TerminalBufferSearch.scan(
            bufferText: "HELLO",
            query: "hello",
            caseSensitive: false
        )
        #expect(result.matches.count == 1)
        // Match length is the lowercased-range length, which equals the query.
        #expect(result.matches[0].length == 5)
    }

    @Test("scan matches only whole needle occurrences across a multi-row buffer")
    func scanMultiRowWholeNeedleOnly() {
        let result = TerminalBufferSearch.scan(
            bufferText: "foo\nbar foo\nbaz",
            query: "foo",
            caseSensitive: false
        )
        #expect(result.matches.count == 2)
        #expect(result.matches[0].row == 0)
        #expect(result.matches[0].col == 0)
        #expect(result.matches[1].row == 1)
        #expect(result.matches[1].col == 4)
        #expect(result.totalRows == 3)
    }

    // MARK: - TerminalScrollEventInfo (decision logic via scalar initializer)

    @Test("shouldIntercept is true for a non-zero delta with no phase boundary")
    func interceptNonZeroDelta() {
        let info = TerminalScrollEventInfo(delta: 5, phaseBegan: false, phaseEnded: false, isPrecise: true)
        #expect(info.shouldIntercept)
    }

    @Test("shouldIntercept is true for a negative (scroll-down) delta")
    func interceptNegativeDelta() {
        let info = TerminalScrollEventInfo(delta: -5, phaseBegan: false, phaseEnded: false, isPrecise: true)
        #expect(info.shouldIntercept)
    }

    @Test("shouldIntercept drops inert zero-delta ticks with no phase boundary")
    func interceptDropsInertTick() {
        let info = TerminalScrollEventInfo(delta: 0, phaseBegan: false, phaseEnded: false, isPrecise: true)
        #expect(!info.shouldIntercept)
    }

    @Test("shouldIntercept keeps a zero-delta .began boundary (resets accumulator)")
    func interceptKeepsPhaseBegan() {
        let info = TerminalScrollEventInfo(delta: 0, phaseBegan: true, phaseEnded: false, isPrecise: true)
        #expect(info.shouldIntercept)
    }

    @Test("shouldIntercept keeps a zero-delta .ended boundary (flushes residual)")
    func interceptKeepsPhaseEnded() {
        let info = TerminalScrollEventInfo(delta: 0, phaseBegan: false, phaseEnded: true, isPrecise: true)
        #expect(info.shouldIntercept)
    }

    @Test("shouldIntercept is true when both phase boundaries are set")
    func interceptBothPhases() {
        let info = TerminalScrollEventInfo(delta: 0, phaseBegan: true, phaseEnded: true, isPrecise: false)
        #expect(info.shouldIntercept)
    }

    @Test("scalar initializer stores all resolved fields verbatim")
    func scalarInitializerStoresFields() {
        let info = TerminalScrollEventInfo(delta: -3.5, phaseBegan: true, phaseEnded: false, isPrecise: false)
        #expect(info.delta == -3.5)
        #expect(info.phaseBegan)
        #expect(!info.phaseEnded)
        #expect(!info.isPrecise)
    }

    @Test("a non-zero delta with phase boundaries still intercepts")
    func interceptDeltaAndPhases() {
        let info = TerminalScrollEventInfo(delta: 12, phaseBegan: true, phaseEnded: false, isPrecise: true)
        #expect(info.shouldIntercept)
    }
}
