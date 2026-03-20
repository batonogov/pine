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
}
