//
//  InlineDiffProviderTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct InlineDiffProviderTests {

    // MARK: - parseHunkHeader

    @Test func parsesStandardHunkHeader() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -10,5 +12,7 @@ func foo()")
        #expect(result?.oldStart == 10)
        #expect(result?.oldCount == 5)
        #expect(result?.newStart == 12)
        #expect(result?.newCount == 7)
    }

    @Test func parsesHunkHeaderWithoutCount() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1 +1 @@")
        #expect(result?.oldStart == 1)
        #expect(result?.oldCount == 1)
        #expect(result?.newStart == 1)
        #expect(result?.newCount == 1)
    }

    @Test func parsesHunkHeaderZeroCount() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -5,0 +6,3 @@")
        #expect(result?.oldStart == 5)
        #expect(result?.oldCount == 0)
        #expect(result?.newStart == 6)
        #expect(result?.newCount == 3)
    }

    @Test func returnsNilForInvalidHeader() {
        #expect(InlineDiffProvider.parseHunkHeader("not a hunk") == nil)
    }

    @Test func returnsNilForMissingParts() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ -1 @@") == nil)
    }

    @Test func returnsNilForMissingMinusPlus() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ 1,3 2,4 @@") == nil)
    }

    // MARK: - parseHunks

    @Test func parsesEmptyDiff() {
        let hunks = InlineDiffProvider.parseHunks("")
        #expect(hunks.isEmpty)
    }

    @Test func parsesSingleAddedHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[0].newCount == 3)
        #expect(hunks[0].oldStart == 0)
        #expect(hunks[0].oldCount == 0)
    }

    @Test func parsesMultipleHunks() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
        +new first line
         existing line 1
         existing line 2
         existing line 3
        @@ -10,2 +11,3 @@
         context
        +added line
         more context
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 2)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[0].newCount == 4)
        #expect(hunks[1].newStart == 11)
        #expect(hunks[1].newCount == 3)
    }

    @Test func parsesDeletionHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -5,3 +5,0 @@
        -removed1
        -removed2
        -removed3
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].oldCount == 3)
        #expect(hunks[0].newCount == 0)
    }

    @Test func parsesModificationHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -10,2 +10,2 @@
        -old line 1
        -old line 2
        +new line 1
        +new line 2
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].oldStart == 10)
        #expect(hunks[0].oldCount == 2)
        #expect(hunks[0].newStart == 10)
        #expect(hunks[0].newCount == 2)
    }

    // MARK: - DiffHunk properties

    @Test func newEndLineForNonEmptyHunk() {
        let hunk = DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: "")
        #expect(hunk.newEndLine == 7)
    }

    @Test func newEndLineForSingleLineHunk() {
        let hunk = DiffHunk(newStart: 10, newCount: 1, oldStart: 10, oldCount: 1, rawText: "")
        #expect(hunk.newEndLine == 10)
    }

    @Test func newEndLineForDeletionHunk() {
        let hunk = DiffHunk(newStart: 5, newCount: 0, oldStart: 5, oldCount: 3, rawText: "")
        #expect(hunk.newEndLine == 5)
    }

    // MARK: - hunk(atLine:in:)

    @Test func findsHunkContainingLine() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: "")
        ]
        let found = InlineDiffProvider.hunk(atLine: 6, in: hunks)
        #expect(found?.newStart == 5)
    }

    @Test func findsHunkAtStartLine() {
        let hunks = [
            DiffHunk(newStart: 10, newCount: 5, oldStart: 10, oldCount: 3, rawText: "")
        ]
        let found = InlineDiffProvider.hunk(atLine: 10, in: hunks)
        #expect(found?.newStart == 10)
    }

    @Test func findsHunkAtEndLine() {
        let hunks = [
            DiffHunk(newStart: 10, newCount: 5, oldStart: 10, oldCount: 3, rawText: "")
        ]
        let found = InlineDiffProvider.hunk(atLine: 14, in: hunks)
        #expect(found?.newStart == 10)
    }

    @Test func returnsNilForLineOutsideHunks() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: 1, in: hunks) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 9, in: hunks) == nil)
    }

    @Test func findsDeletionHunkAtMarkerLine() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 0, oldStart: 5, oldCount: 3, rawText: "")
        ]
        let found = InlineDiffProvider.hunk(atLine: 5, in: hunks)
        #expect(found?.newStart == 5)
    }

    @Test func returnsNilForEmptyHunks() {
        #expect(InlineDiffProvider.hunk(atLine: 1, in: []) == nil)
    }

    // MARK: - nearestHunk

    @Test func nearestHunkReturnsCurrentWhenInsideHunk() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 6, direction: .next, in: hunks)
        #expect(nearest?.newStart == 5)
    }

    @Test func nearestHunkReturnsNextWhenOutside() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 10, direction: .next, in: hunks)
        #expect(nearest?.newStart == 20)
    }

    @Test func nearestHunkReturnsPreviousWhenOutside() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 10, direction: .previous, in: hunks)
        #expect(nearest?.newStart == 5)
    }

    @Test func nearestHunkWrapsToFirstWhenNoNextExists() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 3, oldStart: 5, oldCount: 2, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 100, direction: .next, in: hunks)
        #expect(nearest?.newStart == 5)
    }

    @Test func nearestHunkWrapsToLastWhenNoPreviousExists() {
        let hunks = [
            DiffHunk(newStart: 50, newCount: 2, oldStart: 48, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 1, direction: .previous, in: hunks)
        #expect(nearest?.newStart == 50)
    }

    @Test func nearestHunkReturnsNilForEmptyHunks() {
        #expect(InlineDiffProvider.nearestHunk(atLine: 1, direction: .next, in: []) == nil)
        #expect(InlineDiffProvider.nearestHunk(atLine: 1, direction: .previous, in: []) == nil)
    }

    // MARK: - buildPatch

    @Test func buildPatchCreatesValidUnifiedDiff() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 0, oldCount: 0,
            rawText: "@@ -0,0 +1,3 @@\n+line1\n+line2\n+line3"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/src/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.contains("diff --git a/src/file.swift b/src/file.swift"))
        #expect(patch.contains("--- a/src/file.swift"))
        #expect(patch.contains("+++ b/src/file.swift"))
        #expect(patch.contains("@@ -0,0 +1,3 @@"))
        #expect(patch.contains("+line1"))
    }

    @Test func buildPatchHandlesFileAtRepoRoot() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.contains("a/file.swift"))
        #expect(patch.contains("b/file.swift"))
    }

    // MARK: - parseSidePart (via parseHunkHeader)

    @Test func parsesHeaderWithLargeNumbers() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1000,50 +1020,60 @@ class Foo")
        #expect(result?.oldStart == 1000)
        #expect(result?.oldCount == 50)
        #expect(result?.newStart == 1020)
        #expect(result?.newCount == 60)
    }

    @Test func parsesHeaderWithTrailingContext() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1,3 +1,4 @@ func bar() {")
        #expect(result?.newStart == 1)
        #expect(result?.newCount == 4)
    }

    // MARK: - DiffHunk Equatable

    @Test func diffHunksWithSameValuesAreNotEqual() {
        // Each DiffHunk gets a unique UUID, so they should not be equal
        let hunk1 = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        let hunk2 = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        #expect(hunk1 != hunk2) // Different UUIDs
    }

    // MARK: - Complex diff scenarios

    @Test func parsesHunksWithNoNewlineAtEnd() {
        let diff = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,3 @@
         first line
        +added line
         last line
        \\ No newline at end of file
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].rawText.contains("No newline"))
    }

    @Test func parsesThreeConsecutiveHunks() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,2 @@
         line1
        +added1
        @@ -5,1 +6,2 @@
         line5
        +added2
        @@ -10,1 +12,2 @@
         line10
        +added3
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 3)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[1].newStart == 6)
        #expect(hunks[2].newStart == 12)
    }
}
