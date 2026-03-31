//
//  FoldStateTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct FoldStateTests {

    private func makeFoldable(start: Int, end: Int, startChar: Int = 0, endChar: Int = 0) -> FoldableRange {
        FoldableRange(startLine: start, endLine: end, startCharIndex: startChar, endCharIndex: endChar, kind: .braces)
    }

    // MARK: - Fold / unfold

    @Test func foldAddsToFoldedRanges() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.fold(range)
        #expect(state.foldedRanges.count == 1)
        #expect(state.foldedRanges[0] == range)
    }

    @Test func foldDuplicateIsIgnored() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.fold(range)
        state.fold(range)
        #expect(state.foldedRanges.count == 1)
    }

    @Test func unfoldRemovesRange() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.fold(range)
        state.unfold(range)
        #expect(state.foldedRanges.isEmpty)
    }

    @Test func unfoldNonexistentIsNoOp() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.unfold(range)
        #expect(state.foldedRanges.isEmpty)
    }

    // MARK: - isFolded

    @Test func isFoldedReturnsTrueForHiddenLines() {
        var state = FoldState()
        // Lines 1-5: start line stays visible, lines 2-4 are hidden, end line stays visible
        state.fold(makeFoldable(start: 1, end: 5))
        #expect(!state.isLineHidden(1)) // Start line visible
        #expect(state.isLineHidden(2))
        #expect(state.isLineHidden(3))
        #expect(state.isLineHidden(4))
        #expect(!state.isLineHidden(5)) // End line visible
        #expect(!state.isLineHidden(6))
    }

    @Test func isLineHiddenWithNoFolds() {
        let state = FoldState()
        #expect(!state.isLineHidden(1))
        #expect(!state.isLineHidden(100))
    }

    // MARK: - Fold all / unfold all

    @Test func foldAll() {
        var state = FoldState()
        let ranges = [
            makeFoldable(start: 1, end: 5),
            makeFoldable(start: 10, end: 15)
        ]
        state.foldAll(ranges)
        #expect(state.foldedRanges.count == 2)
    }

    @Test func unfoldAll() {
        var state = FoldState()
        state.fold(makeFoldable(start: 1, end: 5))
        state.fold(makeFoldable(start: 10, end: 15))
        state.unfoldAll()
        #expect(state.foldedRanges.isEmpty)
    }

    // MARK: - Toggle

    @Test func toggleFoldsWhenUnfolded() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.toggle(range)
        #expect(state.foldedRanges.count == 1)
    }

    @Test func toggleUnfoldsWhenFolded() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        state.fold(range)
        state.toggle(range)
        #expect(state.foldedRanges.isEmpty)
    }

    // MARK: - isFolded for range

    @Test func isFoldedForRange() {
        var state = FoldState()
        let range = makeFoldable(start: 1, end: 5)
        #expect(!state.isFolded(range))
        state.fold(range)
        #expect(state.isFolded(range))
    }

    // MARK: - Nested folds

    @Test func nestedFoldHiddenLines() {
        var state = FoldState()
        // Outer: 1-10, Inner: 3-7
        state.fold(makeFoldable(start: 1, end: 10))
        state.fold(makeFoldable(start: 3, end: 7))
        // Lines 2-9 are hidden (from outer fold)
        #expect(state.isLineHidden(2))
        #expect(state.isLineHidden(5))
        #expect(state.isLineHidden(9))
        #expect(!state.isLineHidden(1))
        #expect(!state.isLineHidden(10))
    }

    @Test func unfoldOuterKeepsInnerFolded() {
        var state = FoldState()
        let outer = makeFoldable(start: 1, end: 10)
        let inner = makeFoldable(start: 3, end: 7)
        state.fold(outer)
        state.fold(inner)
        state.unfold(outer)
        // Inner fold should remain
        #expect(state.foldedRanges.count == 1)
        #expect(state.isLineHidden(4))
        #expect(!state.isLineHidden(2))
    }

    // MARK: - Hidden line count

    @Test func hiddenLineCount() {
        var state = FoldState()
        state.fold(makeFoldable(start: 1, end: 5))
        // Lines 2,3,4 are hidden = 3 lines
        #expect(state.hiddenLineCount(for: makeFoldable(start: 1, end: 5)) == 3)
    }

    @Test func hiddenLineCountForUnfolded() {
        let state = FoldState()
        #expect(state.hiddenLineCount(for: makeFoldable(start: 1, end: 5)) == 3)
    }

    // MARK: - Adjacent folds

    @Test func twoAdjacentFoldsHideCorrectLines() {
        var state = FoldState()
        // First block: lines 1-4, second block: lines 5-8
        let first = makeFoldable(start: 1, end: 4)
        let second = makeFoldable(start: 5, end: 8)
        state.fold(first)
        state.fold(second)

        // First fold hides lines 2-3
        #expect(!state.isLineHidden(1))
        #expect(state.isLineHidden(2))
        #expect(state.isLineHidden(3))
        #expect(!state.isLineHidden(4))

        // Second fold hides lines 6-7
        #expect(!state.isLineHidden(5))
        #expect(state.isLineHidden(6))
        #expect(state.isLineHidden(7))
        #expect(!state.isLineHidden(8))

        // Line 9+ not hidden
        #expect(!state.isLineHidden(9))
    }

    @Test func foldSecondAfterFirst() {
        var state = FoldState()
        let first = makeFoldable(start: 1, end: 4)
        let second = makeFoldable(start: 5, end: 8)
        state.fold(first)

        // After folding first, second should still be foldable
        #expect(!state.isFolded(second))
        #expect(!state.isLineHidden(5))

        state.fold(second)
        #expect(state.isFolded(second))
        #expect(state.isLineHidden(6))
    }
}
