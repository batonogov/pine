//
//  DiffNavigationTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct DiffNavigationTests {

    // MARK: - changeRegionStarts

    @Test func emptyDiffsReturnsNoRegions() {
        let regions = GitLineDiff.changeRegionStarts([])
        #expect(regions.isEmpty)
    }

    @Test func singleDiffReturnsOneRegion() {
        let diffs = [GitLineDiff(line: 5, kind: .added)]
        let regions = GitLineDiff.changeRegionStarts(diffs)
        #expect(regions == [5])
    }

    @Test func consecutiveLinesFormOneRegion() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 6, kind: .added),
            GitLineDiff(line: 7, kind: .added)
        ]
        let regions = GitLineDiff.changeRegionStarts(diffs)
        #expect(regions == [5])
    }

    @Test func nonConsecutiveLinesFormSeparateRegions() {
        let diffs = [
            GitLineDiff(line: 5, kind: .modified),
            GitLineDiff(line: 6, kind: .modified),
            GitLineDiff(line: 20, kind: .added),
            GitLineDiff(line: 21, kind: .added)
        ]
        let regions = GitLineDiff.changeRegionStarts(diffs)
        #expect(regions == [5, 20])
    }

    @Test func deletedLineFormsOwnRegion() {
        let diffs = [
            GitLineDiff(line: 3, kind: .deleted),
            GitLineDiff(line: 10, kind: .added)
        ]
        let regions = GitLineDiff.changeRegionStarts(diffs)
        #expect(regions == [3, 10])
    }

    @Test func unsortedDiffsAreSorted() {
        let diffs = [
            GitLineDiff(line: 20, kind: .added),
            GitLineDiff(line: 5, kind: .modified)
        ]
        let regions = GitLineDiff.changeRegionStarts(diffs)
        #expect(regions == [5, 20])
    }

    // MARK: - nextChangeLine

    @Test func nextChangeFromBeforeFirstRegion() {
        let diffs = [
            GitLineDiff(line: 10, kind: .added),
            GitLineDiff(line: 11, kind: .added),
            GitLineDiff(line: 30, kind: .modified)
        ]
        #expect(GitLineDiff.nextChangeLine(from: 1, in: diffs) == 10)
    }

    @Test func nextChangeFromInsideFirstRegion() {
        let diffs = [
            GitLineDiff(line: 10, kind: .added),
            GitLineDiff(line: 11, kind: .added),
            GitLineDiff(line: 30, kind: .modified)
        ]
        #expect(GitLineDiff.nextChangeLine(from: 10, in: diffs) == 30)
        #expect(GitLineDiff.nextChangeLine(from: 11, in: diffs) == 30)
    }

    @Test func nextChangeFromBetweenRegions() {
        let diffs = [
            GitLineDiff(line: 5, kind: .modified),
            GitLineDiff(line: 20, kind: .added)
        ]
        #expect(GitLineDiff.nextChangeLine(from: 10, in: diffs) == 20)
    }

    @Test func nextChangeWrapsToFirst() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 20, kind: .modified)
        ]
        #expect(GitLineDiff.nextChangeLine(from: 25, in: diffs) == 5)
    }

    @Test func nextChangeReturnsNilForEmptyDiffs() {
        #expect(GitLineDiff.nextChangeLine(from: 1, in: []) == nil)
    }

    // MARK: - previousChangeLine

    @Test func previousChangeFromAfterLastRegion() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 20, kind: .modified)
        ]
        #expect(GitLineDiff.previousChangeLine(from: 25, in: diffs) == 20)
    }

    @Test func previousChangeFromInsideSecondRegion() {
        let diffs = [
            GitLineDiff(line: 5, kind: .modified),
            GitLineDiff(line: 20, kind: .added),
            GitLineDiff(line: 21, kind: .added)
        ]
        #expect(GitLineDiff.previousChangeLine(from: 20, in: diffs) == 5)
        #expect(GitLineDiff.previousChangeLine(from: 21, in: diffs) == 5)
    }

    @Test func previousChangeFromBetweenRegions() {
        let diffs = [
            GitLineDiff(line: 5, kind: .modified),
            GitLineDiff(line: 20, kind: .added)
        ]
        #expect(GitLineDiff.previousChangeLine(from: 10, in: diffs) == 5)
    }

    @Test func previousChangeWrapsToLast() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 20, kind: .modified)
        ]
        #expect(GitLineDiff.previousChangeLine(from: 3, in: diffs) == 20)
    }

    @Test func previousChangeReturnsNilForEmptyDiffs() {
        #expect(GitLineDiff.previousChangeLine(from: 1, in: []) == nil)
    }

    // MARK: - Edge cases

    @Test func singleRegionNextWraps() {
        let diffs = [GitLineDiff(line: 10, kind: .added)]
        // When on the only region, next wraps back to it
        #expect(GitLineDiff.nextChangeLine(from: 10, in: diffs) == 10)
    }

    @Test func singleRegionPreviousWraps() {
        let diffs = [GitLineDiff(line: 10, kind: .added)]
        // When on the only region, previous wraps back to it
        #expect(GitLineDiff.previousChangeLine(from: 10, in: diffs) == 10)
    }

    // MARK: - lineNumber(forOffset:in:)

    @Test func lineNumberAtStartOfFile() {
        let content = "first\nsecond\nthird\n"
        #expect(ContentView.lineNumber(forOffset: 0, in: content) == 1)
    }

    @Test func lineNumberAtSecondLine() {
        let content = "first\nsecond\nthird\n"
        // offset 6 = start of "second"
        #expect(ContentView.lineNumber(forOffset: 6, in: content) == 2)
    }

    @Test func lineNumberAtThirdLine() {
        let content = "first\nsecond\nthird\n"
        // offset 13 = start of "third"
        #expect(ContentView.lineNumber(forOffset: 13, in: content) == 3)
    }

    @Test func lineNumberAtEndOfFile() {
        let content = "first\nsecond\nthird\n"
        let nsContent = content as NSString
        #expect(ContentView.lineNumber(forOffset: nsContent.length, in: content) == 4)
    }

    @Test func lineNumberInEmptyString() {
        #expect(ContentView.lineNumber(forOffset: 0, in: "") == 1)
    }

    @Test func lineNumberWithOffsetBeyondLength() {
        let content = "abc"
        #expect(ContentView.lineNumber(forOffset: 999, in: content) == 1)
    }

    // MARK: - Round-trip: cursorOffset ↔ lineNumber

    @Test func cursorOffsetAndLineNumberRoundTrip() {
        let content = "line1\nline2\nline3\nline4\n"
        for line in 1...4 {
            let offset = ContentView.cursorOffset(forLine: line, in: content)
            let back = ContentView.lineNumber(forOffset: offset, in: content)
            #expect(back == line, "Round-trip failed for line \(line)")
        }
    }

    @Test func roundTripWithSingleLine() {
        let content = "hello"
        let offset = ContentView.cursorOffset(forLine: 1, in: content)
        let back = ContentView.lineNumber(forOffset: offset, in: content)
        #expect(back == 1)
    }
}
