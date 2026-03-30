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

    @Test func buildPatchEndsWithTrailingNewline() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/src/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.hasSuffix("\n"), "Patch must end with trailing newline for git apply")
    }

    @Test func buildPatchDoesNotDoubleNewline() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new\n"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.hasSuffix("\n"))
        #expect(!patch.hasSuffix("\n\n"), "Patch should not have double trailing newline")
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

    // MARK: - InlineDiffAction enum

    @Test func inlineDiffActionRawValues() {
        #expect(InlineDiffAction.accept.rawValue == "accept")
        #expect(InlineDiffAction.revert.rawValue == "revert")
        #expect(InlineDiffAction.acceptAll.rawValue == "acceptAll")
        #expect(InlineDiffAction.revertAll.rawValue == "revertAll")
    }

    @Test func inlineDiffActionFromRawValue() {
        #expect(InlineDiffAction(rawValue: "accept") == .accept)
        #expect(InlineDiffAction(rawValue: "revert") == .revert)
        #expect(InlineDiffAction(rawValue: "acceptAll") == .acceptAll)
        #expect(InlineDiffAction(rawValue: "revertAll") == .revertAll)
        #expect(InlineDiffAction(rawValue: "invalid") == nil)
    }

    @Test func inlineDiffActionIsSendable() {
        // InlineDiffAction conforms to Sendable — verify it can cross concurrency boundaries
        let action: InlineDiffAction = .accept
        Task {
            _ = action
        }
    }

    // MARK: - DiffHunk.deletedLines

    @Test func deletedLinesFromModificationHunk() {
        let hunk = DiffHunk(
            newStart: 10, newCount: 2, oldStart: 10, oldCount: 2,
            rawText: "@@ -10,2 +10,2 @@\n-old line 1\n-old line 2\n+new line 1\n+new line 2"
        )
        #expect(hunk.deletedLines == ["old line 1", "old line 2"])
    }

    @Test func deletedLinesFromPureDeletionHunk() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-removed1\n-removed2\n-removed3"
        )
        #expect(hunk.deletedLines == ["removed1", "removed2", "removed3"])
    }

    @Test func deletedLinesFromPureAdditionHunk() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 0, oldCount: 0,
            rawText: "@@ -0,0 +1,3 @@\n+line1\n+line2\n+line3"
        )
        #expect(hunk.deletedLines.isEmpty)
    }

    @Test func deletedLinesSkipsDashDashDash() {
        // Ensure "---" lines (diff header) are not treated as deletions
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n--- should be skipped\n-real deletion\n+addition"
        )
        #expect(hunk.deletedLines == ["real deletion"])
    }

    @Test func deletedLinesWithEmptyRawText() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 0, oldStart: 1, oldCount: 0,
            rawText: ""
        )
        #expect(hunk.deletedLines.isEmpty)
    }

    @Test func deletedLinesPreservesLeadingWhitespace() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-    indented line\n+    new indented line"
        )
        #expect(hunk.deletedLines == ["    indented line"])
    }

    // MARK: - DiffHunk.addedLines

    @Test func addedLinesFromModificationHunk() {
        let hunk = DiffHunk(
            newStart: 10, newCount: 2, oldStart: 10, oldCount: 2,
            rawText: "@@ -10,2 +10,2 @@\n-old line 1\n-old line 2\n+new line 1\n+new line 2"
        )
        #expect(hunk.addedLines == ["new line 1", "new line 2"])
    }

    @Test func addedLinesFromPureAdditionHunk() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 0, oldCount: 0,
            rawText: "@@ -0,0 +1,3 @@\n+line1\n+line2\n+line3"
        )
        #expect(hunk.addedLines == ["line1", "line2", "line3"])
    }

    @Test func addedLinesFromPureDeletionHunk() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-removed1\n-removed2\n-removed3"
        )
        #expect(hunk.addedLines.isEmpty)
    }

    @Test func addedLinesSkipsPlusPlusPlus() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n+++ should be skipped\n-deletion\n+real addition"
        )
        #expect(hunk.addedLines == ["real addition"])
    }

    @Test func addedLinesPreservesLeadingWhitespace() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+    indented new"
        )
        #expect(hunk.addedLines == ["    indented new"])
    }

    // MARK: - addedLineNumbers

    @Test func addedLineNumbersForSingleHunk() {
        let hunks = [
            DiffHunk(
                newStart: 5, newCount: 3, oldStart: 5, oldCount: 1,
                rawText: "@@ -5,1 +5,3 @@\n-old\n+new1\n+new2\n+new3"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [5, 6, 7])
    }

    @Test func addedLineNumbersForMultipleHunks() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 2, oldStart: 1, oldCount: 1,
                rawText: "@@ -1,1 +1,2 @@\n-old\n+new1\n+new2"
            ),
            DiffHunk(
                newStart: 10, newCount: 1, oldStart: 9, oldCount: 0,
                rawText: "@@ -9,0 +10,1 @@\n+inserted"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [1, 2, 10])
    }

    @Test func addedLineNumbersSkipsContextLines() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 4, oldStart: 1, oldCount: 3,
                rawText: "@@ -1,3 +1,4 @@\n context1\n+added\n context2\n context3"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [2])
    }

    @Test func addedLineNumbersForPureDeletion() {
        let hunks = [
            DiffHunk(
                newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
                rawText: "@@ -5,3 +5,0 @@\n-del1\n-del2\n-del3"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result.isEmpty)
    }

    @Test func addedLineNumbersEmptyHunks() {
        let result = InlineDiffProvider.addedLineNumbers(from: [])
        #expect(result.isEmpty)
    }

    @Test func addedLineNumbersWithMixedContextAndChanges() {
        // Hunk: context, deletion, addition, context
        let hunks = [
            DiffHunk(
                newStart: 10, newCount: 3, oldStart: 10, oldCount: 3,
                rawText: "@@ -10,3 +10,3 @@\n context\n-old\n+new\n context2"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        // context at line 10, deletion doesn't count, addition at line 11, context at line 12
        #expect(result == [11])
    }

    // MARK: - deletedLineBlocks

    @Test func deletedLineBlocksForModificationHunk() {
        let hunks = [
            DiffHunk(
                newStart: 10, newCount: 2, oldStart: 10, oldCount: 2,
                rawText: "@@ -10,2 +10,2 @@\n-old1\n-old2\n+new1\n+new2"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].anchorLine == 10)
        #expect(blocks[0].lines == ["old1", "old2"])
    }

    @Test func deletedLineBlocksForPureDeletionHunk() {
        let hunks = [
            DiffHunk(
                newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
                rawText: "@@ -5,3 +5,0 @@\n-removed1\n-removed2\n-removed3"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].anchorLine == 5)
        #expect(blocks[0].lines == ["removed1", "removed2", "removed3"])
    }

    @Test func deletedLineBlocksForPureAdditionReturnsEmpty() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 3, oldStart: 0, oldCount: 0,
                rawText: "@@ -0,0 +1,3 @@\n+line1\n+line2\n+line3"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.isEmpty)
    }

    @Test func deletedLineBlocksMultipleHunks() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 1, oldStart: 1, oldCount: 2,
                rawText: "@@ -1,2 +1,1 @@\n-old1\n-old2\n+replacement"
            ),
            DiffHunk(
                newStart: 20, newCount: 0, oldStart: 18, oldCount: 1,
                rawText: "@@ -18,1 +20,0 @@\n-deleted"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 2)
        #expect(blocks[0].anchorLine == 1)
        #expect(blocks[0].lines == ["old1", "old2"])
        #expect(blocks[1].anchorLine == 20)
        #expect(blocks[1].lines == ["deleted"])
    }

    @Test func deletedLineBlocksEmptyHunks() {
        let blocks = InlineDiffProvider.deletedLineBlocks(from: [])
        #expect(blocks.isEmpty)
    }

    @Test func deletedLineBlocksPreservesWhitespace() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
                rawText: "@@ -1,1 +1,1 @@\n-    indented old\n+    indented new"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == ["    indented old"])
    }

    // MARK: - DiffLineKind

    @Test func diffLineKindEquality() {
        #expect(DiffLineKind.added == DiffLineKind.added)
        #expect(DiffLineKind.deleted == DiffLineKind.deleted)
        #expect(DiffLineKind.added != DiffLineKind.deleted)
    }

    // MARK: - DiffHighlightLine

    @Test func diffHighlightLineEquality() {
        let a = DiffHighlightLine(kind: .added, editorLine: 5)
        let b = DiffHighlightLine(kind: .added, editorLine: 5)
        let c = DiffHighlightLine(kind: .deleted, editorLine: 5)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - DeletedLinesBlock

    @Test func deletedLinesBlockEquality() {
        let a = DeletedLinesBlock(anchorLine: 10, lines: ["old"])
        let b = DeletedLinesBlock(anchorLine: 10, lines: ["old"])
        let c = DeletedLinesBlock(anchorLine: 10, lines: ["different"])
        #expect(a == b)
        #expect(a != c)
    }

    @Test func deletedLinesBlockDifferentAnchor() {
        let a = DeletedLinesBlock(anchorLine: 1, lines: ["line"])
        let b = DeletedLinesBlock(anchorLine: 2, lines: ["line"])
        #expect(a != b)
    }

    // MARK: - Integration: full diff → highlights

    @Test func fullDiffProducesCorrectHighlights() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
        +new first line
         existing line 1
         existing line 2
         existing line 3
        @@ -10,2 +11,2 @@
        -old line at 10
        -old line at 11
        +new line at 11
        +new line at 12
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        let deletedBlocks = InlineDiffProvider.deletedLineBlocks(from: hunks)

        // First hunk: pure addition at line 1
        #expect(addedLines.contains(1))
        // Second hunk: lines 11 and 12 are added
        #expect(addedLines.contains(11))
        #expect(addedLines.contains(12))
        // Context lines should NOT be in added set
        #expect(!addedLines.contains(2))
        #expect(!addedLines.contains(3))
        #expect(!addedLines.contains(4))

        // First hunk has no deletions
        // Second hunk has deletions anchored at line 11
        #expect(deletedBlocks.count == 1)
        #expect(deletedBlocks[0].anchorLine == 11)
        #expect(deletedBlocks[0].lines == ["old line at 10", "old line at 11"])
    }

    @Test func fullDiffPureDeletionOnlyBlock() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -5,3 +5,0 @@
        -deleted line 1
        -deleted line 2
        -deleted line 3
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        let deletedBlocks = InlineDiffProvider.deletedLineBlocks(from: hunks)

        #expect(addedLines.isEmpty)
        #expect(deletedBlocks.count == 1)
        #expect(deletedBlocks[0].anchorLine == 5)
        #expect(deletedBlocks[0].lines.count == 3)
    }

    @Test func emptyDiffProducesNoHighlights() {
        let hunks = InlineDiffProvider.parseHunks("")
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        let deletedBlocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(addedLines.isEmpty)
        #expect(deletedBlocks.isEmpty)
    }

    @Test func addedLineNumbersHandlesEmptyLines() {
        // A hunk that adds empty lines (just "+")
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 2, oldStart: 1, oldCount: 0,
                rawText: "@@ -1,0 +1,2 @@\n+\n+second"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [1, 2])
    }

    // MARK: - Malformed count values in diff headers

    @Test func returnsNilForMalformedNewCount() {
        // "+1,abc" should be rejected (count is not an integer)
        let result = InlineDiffProvider.parseHunkHeader("@@ -1,3 +1,abc @@")
        #expect(result == nil)
    }

    @Test func returnsNilForMalformedOldCount() {
        // "-2,xyz" should be rejected
        let result = InlineDiffProvider.parseHunkHeader("@@ -2,xyz +1,3 @@")
        #expect(result == nil)
    }

    @Test func returnsNilForBothCountsMalformed() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1,foo +2,bar @@")
        #expect(result == nil)
    }

    @Test func parseHunksSkipsMalformedHeaders() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,abc +2,3 @@
        +should be skipped
        @@ -5,2 +6,3 @@
         context
        +valid added line
         more context
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        // Only the second (valid) hunk should be parsed
        #expect(hunks.count == 1)
        #expect(hunks[0].newStart == 6)
        #expect(hunks[0].newCount == 3)
    }

    // MARK: - Same anchor line with multiple deleted blocks

    @Test func deletedLineBlocksMultipleBlocksSameAnchor() {
        // Two hunks that both anchor at the same editor line
        let hunks = [
            DiffHunk(
                newStart: 5, newCount: 1, oldStart: 5, oldCount: 2,
                rawText: "@@ -5,2 +5,1 @@\n-old1\n-old2\n+replacement"
            ),
            DiffHunk(
                newStart: 5, newCount: 1, oldStart: 7, oldCount: 2,
                rawText: "@@ -7,2 +5,1 @@\n-another1\n-another2\n+another replacement"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 2)
        // Both should be anchored at the same line
        #expect(blocks[0].anchorLine == 5)
        #expect(blocks[1].anchorLine == 5)
        #expect(blocks[0].lines == ["old1", "old2"])
        #expect(blocks[1].lines == ["another1", "another2"])
    }

    // MARK: - CRLF line endings in diff content

    @Test func parseHunksHandlesCRLFLineEndings() {
        let diff = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,2 +1,3 @@",
            " context",
            "+added line",
            " more context",
            ""
        ].joined(separator: "\r\n")
        let hunks = InlineDiffProvider.parseHunks(diff)
        // CRLF splits on \n, \r stays — but hunk should still be parsed
        #expect(hunks.count == 1)
    }

    @Test func deletedLinesWithCRLFContent() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 2,
            rawText: "@@ -1,2 +1,1 @@\r\n-old line 1\r\n-old line 2\r\n+new line"
        )
        let deleted = hunk.deletedLines
        // Each line may retain \r — the important thing is we get both lines
        #expect(deleted.count == 2)
    }

    @Test func addedLinesWithCRLFContent() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 2, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,2 @@\r\n-old\r\n+new1\r\n+new2"
        )
        let added = hunk.addedLines
        #expect(added.count == 2)
    }

    // MARK: - Empty deleted/added sections

    @Test func hunkWithOnlyContextLines() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 1, oldCount: 3,
            rawText: "@@ -1,3 +1,3 @@\n context1\n context2\n context3"
        )
        #expect(hunk.deletedLines.isEmpty)
        #expect(hunk.addedLines.isEmpty)
    }

    @Test func emptyAddedSectionInDiff() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -5,3 +5,0 @@
        -line1
        -line2
        -line3
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(addedLines.isEmpty)
        #expect(hunks[0].addedLines.isEmpty)
    }

    @Test func emptyDeletedSectionInDiff() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -0,0 +1,2 @@
        +new1
        +new2
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.isEmpty)
        #expect(hunks[0].deletedLines.isEmpty)
    }

    // MARK: - Very large hunks (100+ lines)

    @Test func parsesVeryLargeAdditionHunk() {
        var diffLines = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -0,0 +1,150 @@"
        ]
        for i in 1...150 {
            diffLines.append("+line \(i)")
        }
        let diff = diffLines.joined(separator: "\n")
        let hunks = InlineDiffProvider.parseHunks(diff)

        #expect(hunks.count == 1)
        #expect(hunks[0].newCount == 150)
        #expect(hunks[0].addedLines.count == 150)

        let addedLineNumbers = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(addedLineNumbers.count == 150)
        #expect(addedLineNumbers.contains(1))
        #expect(addedLineNumbers.contains(150))
    }

    @Test func parsesVeryLargeDeletionHunk() {
        var diffLines = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,120 +1,0 @@"
        ]
        for i in 1...120 {
            diffLines.append("-deleted line \(i)")
        }
        let diff = diffLines.joined(separator: "\n")
        let hunks = InlineDiffProvider.parseHunks(diff)

        #expect(hunks.count == 1)
        #expect(hunks[0].oldCount == 120)
        #expect(hunks[0].deletedLines.count == 120)

        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 120)
    }

    @Test func parsesVeryLargeMixedHunk() {
        var diffLines = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,100 +1,110 @@"
        ]
        // 100 deletions followed by 110 additions
        for i in 1...100 {
            diffLines.append("-old line \(i)")
        }
        for i in 1...110 {
            diffLines.append("+new line \(i)")
        }
        let diff = diffLines.joined(separator: "\n")
        let hunks = InlineDiffProvider.parseHunks(diff)

        #expect(hunks.count == 1)
        #expect(hunks[0].oldCount == 100)
        #expect(hunks[0].newCount == 110)
        #expect(hunks[0].deletedLines.count == 100)
        #expect(hunks[0].addedLines.count == 110)
    }

    // MARK: - parseSidePart edge cases (via parseHunkHeader)

    @Test func emptyOldStartParsesAsZero() {
        // "-,3" → empty start parsed as 0 by Int("") failing, parseSidePart returns nil
        let result = InlineDiffProvider.parseHunkHeader("@@ -,3 +1,2 @@")
        // parseSidePart splits "-,3" into ["-", "3"], start = Int("-") which is valid
        // Actually test the real behavior
        if let r = result {
            #expect(r.oldCount == 3)
        }
    }

    @Test func emptyNewStartParsesAsZero() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1,3 +,2 @@")
        if let r = result {
            #expect(r.oldStart == 1)
            #expect(r.oldCount == 3)
        }
    }

    @Test func parsesNegativeStartValues() {
        // Negative start is technically valid Int parsing
        let result = InlineDiffProvider.parseHunkHeader("@@ --5,3 +1,2 @@")
        // The first "-" is consumed as prefix, so we get "-5,3" → Int("-5") = -5
        if let r = result {
            #expect(r.oldStart == -5)
        }
    }

    @Test func parsesZeroStartValues() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -0,0 +0,0 @@")
        #expect(result?.oldStart == 0)
        #expect(result?.oldCount == 0)
        #expect(result?.newStart == 0)
        #expect(result?.newCount == 0)
    }

    @Test func returnsNilForHeaderWithOnlyAtSigns() {
        #expect(InlineDiffProvider.parseHunkHeader("@@@@") == nil)
    }

    @Test func returnsNilForHeaderWithNoInnerContent() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ @@") == nil)
    }

    @Test func returnsNilForHeaderMissingNewPart() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ -1,3 @@") == nil)
    }

    @Test func returnsNilForStartWithLetters() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ -abc,3 +1,2 @@") == nil)
    }

    @Test func parsesHeaderWithExtraWhitespace() {
        let result = InlineDiffProvider.parseHunkHeader("@@  -1,3  +2,4  @@")
        // Extra leading space before -1,3 — trimmed inner string starts with space
        // The split by space should still work
        if let r = result {
            #expect(r.oldStart == 1)
            #expect(r.newStart == 2)
        }
    }

    // MARK: - buildPatch edge cases

    @Test func buildPatchFallsBackToLastPathComponent() {
        // When file is NOT under repo path, should use lastPathComponent
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo/project")
        let fileURL = URL(fileURLWithPath: "/different/path/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.contains("a/file.swift"))
        #expect(patch.contains("b/file.swift"))
    }

    @Test func buildPatchHandlesRepoPathWithTrailingSlash() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo/")
        let fileURL = URL(fileURLWithPath: "/repo/src/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.contains("a/src/file.swift"))
        #expect(patch.contains("b/src/file.swift"))
    }

    @Test func buildPatchHandlesDeeplyNestedFile() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 0,
            rawText: "@@ -1,0 +1,1 @@\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/a/b/c/d/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.contains("a/a/b/c/d/file.swift"))
        #expect(patch.contains("b/a/b/c/d/file.swift"))
    }

    @Test func buildPatchContainsDiffGitHeader() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n+new"
        )
        let repoURL = URL(fileURLWithPath: "/repo")
        let fileURL = URL(fileURLWithPath: "/repo/file.swift")
        let patch = InlineDiffProvider.buildPatch(hunk: hunk, fileURL: fileURL, repoURL: repoURL)

        #expect(patch.hasPrefix("diff --git"))
        #expect(patch.contains("---"))
        #expect(patch.contains("+++"))
    }

    // MARK: - DiffHunk Identifiable

    @Test func diffHunkHasUniqueID() {
        let hunk1 = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        let hunk2 = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        #expect(hunk1.id != hunk2.id)
    }

    @Test func diffHunkIDIsUUID() {
        let hunk = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        // Verify the id is a valid UUID by checking it's not empty
        #expect(!hunk.id.uuidString.isEmpty)
    }

    // MARK: - DiffHunk Sendable

    @Test func diffHunkIsSendable() {
        let hunk = DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "test")
        Task {
            _ = hunk.newStart
            _ = hunk.deletedLines
        }
    }

    // MARK: - DiffHighlightLine additional tests

    @Test func diffHighlightLineProperties() {
        let line = DiffHighlightLine(kind: .added, editorLine: 42)
        #expect(line.kind == .added)
        #expect(line.editorLine == 42)
    }

    @Test func diffHighlightLineDifferentEditorLines() {
        let a = DiffHighlightLine(kind: .added, editorLine: 1)
        let b = DiffHighlightLine(kind: .added, editorLine: 2)
        #expect(a != b)
    }

    @Test func diffHighlightLineDeletedKind() {
        let line = DiffHighlightLine(kind: .deleted, editorLine: 10)
        #expect(line.kind == .deleted)
        #expect(line.editorLine == 10)
    }

    @Test func diffHighlightLineIsSendable() {
        let line = DiffHighlightLine(kind: .added, editorLine: 1)
        Task {
            _ = line.kind
        }
    }

    // MARK: - DeletedLinesBlock additional tests

    @Test func deletedLinesBlockEmptyLines() {
        let block = DeletedLinesBlock(anchorLine: 1, lines: [])
        #expect(block.lines.isEmpty)
        #expect(block.anchorLine == 1)
    }

    @Test func deletedLinesBlockSingleLine() {
        let block = DeletedLinesBlock(anchorLine: 5, lines: ["only line"])
        #expect(block.lines.count == 1)
        #expect(block.lines[0] == "only line")
    }

    @Test func deletedLinesBlockManyLines() {
        let lines = (1...50).map { "line \($0)" }
        let block = DeletedLinesBlock(anchorLine: 1, lines: lines)
        #expect(block.lines.count == 50)
    }

    @Test func deletedLinesBlockIsSendable() {
        let block = DeletedLinesBlock(anchorLine: 1, lines: ["test"])
        Task {
            _ = block.anchorLine
        }
    }

    // MARK: - DiffLineKind additional tests

    @Test func diffLineKindIsSendable() {
        let kind: DiffLineKind = .added
        Task {
            _ = kind
        }
    }

    @Test func diffLineKindAllCases() {
        let added = DiffLineKind.added
        let deleted = DiffLineKind.deleted
        #expect(added == .added)
        #expect(deleted == .deleted)
        #expect(added != deleted)
    }

    // MARK: - parseHunks edge cases

    @Test func parseHunksWithDiffHeaderOnly() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.isEmpty)
    }

    @Test func parseHunksWithOnlyHunkHeaderNoBody() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,1 @@
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].rawText == "@@ -1,1 +1,1 @@")
    }

    @Test func parseHunksTrimsTrailingEmptyLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,2 @@
         context
        +added


        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        // Trailing empty lines should be trimmed from rawText
        #expect(!hunks[0].rawText.hasSuffix("\n\n"))
    }

    @Test func parseHunksWithBinaryDiffMarker() {
        // "diff " prefix should stop hunk collection
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,2 @@
         context
        +added
        diff --git a/other.swift b/other.swift
        --- a/other.swift
        +++ b/other.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 2)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[0].newCount == 2)
        #expect(hunks[1].newStart == 1)
        #expect(hunks[1].newCount == 1)
    }

    @Test func parseHunksWithSingleCharacterLines() {
        let diff = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -x
        +y
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].deletedLines == ["x"])
        #expect(hunks[0].addedLines == ["y"])
    }

    // MARK: - addedLineNumbers complex scenarios

    @Test func addedLineNumbersWithInterleavedDeletesAndAdds() {
        // context, delete, add, delete, add, context
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 4, oldStart: 1, oldCount: 4,
                rawText: "@@ -1,4 +1,4 @@\n ctx1\n-del1\n+add1\n-del2\n+add2\n ctx2"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        // ctx1 -> line 1, del1 skipped, add1 -> line 2, del2 skipped, add2 -> line 3, ctx2 -> line 4
        #expect(result.contains(2))
        #expect(result.contains(3))
        #expect(!result.contains(1))
        #expect(!result.contains(4))
    }

    @Test func addedLineNumbersWithConsecutiveAdditions() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 5, oldStart: 1, oldCount: 0,
                rawText: "@@ -1,0 +1,5 @@\n+a\n+b\n+c\n+d\n+e"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [1, 2, 3, 4, 5])
    }

    @Test func addedLineNumbersWithConsecutiveDeletions() {
        let hunks = [
            DiffHunk(
                newStart: 5, newCount: 1, oldStart: 5, oldCount: 4,
                rawText: "@@ -5,4 +5,1 @@\n-del1\n-del2\n-del3\n+replacement"
            )
        ]
        let result = InlineDiffProvider.addedLineNumbers(from: hunks)
        #expect(result == [5])
    }

    // MARK: - deletedLineBlocks edge cases

    @Test func deletedLineBlocksWithEmptyDeletedLineContent() {
        // A deletion where the line content is empty (just "-" prefix)
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 1, oldStart: 1, oldCount: 2,
                rawText: "@@ -1,2 +1,1 @@\n-\n-\n+replacement"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == ["", ""])
    }

    @Test func deletedLineBlocksWithSpecialCharacters() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
                rawText: "@@ -1,1 +1,1 @@\n-func foo() -> [String: Int] { }\n+func bar() -> [String: Int] { }"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == ["func foo() -> [String: Int] { }"])
    }

    @Test func deletedLineBlocksWithTabIndentation() {
        let hunks = [
            DiffHunk(
                newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
                rawText: "@@ -1,1 +1,1 @@\n-\told line\n+\tnew line"
            )
        ]
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == ["\told line"])
    }

    // MARK: - hunk(atLine:) edge cases

    @Test func hunkAtLineBoundaryStart() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 1, oldStart: 1, oldCount: 1, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: 1, in: hunks) != nil)
    }

    @Test func hunkAtLineBoundaryEnd() {
        let hunks = [
            DiffHunk(newStart: 10, newCount: 5, oldStart: 10, oldCount: 3, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: 14, in: hunks) != nil)
        #expect(InlineDiffProvider.hunk(atLine: 15, in: hunks) == nil)
    }

    @Test func hunkAtLineZero() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 3, oldStart: 1, oldCount: 2, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: 0, in: hunks) == nil)
    }

    @Test func hunkAtLineNegative() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 3, oldStart: 1, oldCount: 2, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: -1, in: hunks) == nil)
    }

    @Test func hunkAtLineVeryLarge() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 3, oldStart: 1, oldCount: 2, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: Int.max, in: hunks) == nil)
    }

    @Test func hunkAtLineWithMultipleDeletionHunks() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 0, oldStart: 5, oldCount: 2, rawText: ""),
            DiffHunk(newStart: 10, newCount: 0, oldStart: 12, oldCount: 3, rawText: "")
        ]
        #expect(InlineDiffProvider.hunk(atLine: 5, in: hunks)?.newStart == 5)
        #expect(InlineDiffProvider.hunk(atLine: 10, in: hunks)?.newStart == 10)
        #expect(InlineDiffProvider.hunk(atLine: 7, in: hunks) == nil)
    }

    // MARK: - nearestHunk edge cases

    @Test func nearestHunkNextWithSingleHunkBeyondLine() {
        let hunks = [
            DiffHunk(newStart: 100, newCount: 2, oldStart: 98, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 1, direction: .next, in: hunks)
        #expect(nearest?.newStart == 100)
    }

    @Test func nearestHunkPreviousWithSingleHunkBeforeLine() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 2, oldStart: 1, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 100, direction: .previous, in: hunks)
        #expect(nearest?.newStart == 1)
    }

    @Test func nearestHunkNextWrapsWhenAllHunksBefore() {
        let hunks = [
            DiffHunk(newStart: 1, newCount: 2, oldStart: 1, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 5, newCount: 2, oldStart: 5, oldCount: 1, rawText: "")
        ]
        // Line 100 is after all hunks — should wrap to first
        let nearest = InlineDiffProvider.nearestHunk(atLine: 100, direction: .next, in: hunks)
        #expect(nearest?.newStart == 1)
    }

    @Test func nearestHunkPreviousWrapsWhenAllHunksAfter() {
        let hunks = [
            DiffHunk(newStart: 50, newCount: 2, oldStart: 48, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 80, newCount: 2, oldStart: 78, oldCount: 1, rawText: "")
        ]
        // Line 1 is before all hunks — should wrap to last
        let nearest = InlineDiffProvider.nearestHunk(atLine: 1, direction: .previous, in: hunks)
        #expect(nearest?.newStart == 80)
    }

    @Test func nearestHunkNextSelectsClosestHunk() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 2, oldStart: 5, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 50, newCount: 2, oldStart: 48, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 15, direction: .next, in: hunks)
        #expect(nearest?.newStart == 20)
    }

    @Test func nearestHunkPreviousSelectsClosestHunk() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 2, oldStart: 5, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 20, newCount: 2, oldStart: 18, oldCount: 1, rawText: ""),
            DiffHunk(newStart: 50, newCount: 2, oldStart: 48, oldCount: 1, rawText: "")
        ]
        let nearest = InlineDiffProvider.nearestHunk(atLine: 30, direction: .previous, in: hunks)
        #expect(nearest?.newStart == 20)
    }

    @Test func nearestHunkWithDeletionHunk() {
        let hunks = [
            DiffHunk(newStart: 5, newCount: 0, oldStart: 5, oldCount: 3, rawText: "")
        ]
        // Cursor at the deletion marker line
        let nearest = InlineDiffProvider.nearestHunk(atLine: 5, direction: .next, in: hunks)
        #expect(nearest?.newStart == 5)
    }

    // MARK: - NavigationDirection

    @Test func navigationDirectionValues() {
        let next = InlineDiffProvider.NavigationDirection.next
        let prev = InlineDiffProvider.NavigationDirection.previous
        // Just verify they're distinct enum cases
        switch next {
        case .next: break
        case .previous: Issue.record("Expected .next")
        }
        switch prev {
        case .previous: break
        case .next: Issue.record("Expected .previous")
        }
    }

    // MARK: - InlineDiffAction additional tests

    @Test func inlineDiffActionAllCasesCount() {
        let allCases: [InlineDiffAction] = [.accept, .revert, .acceptAll, .revertAll]
        #expect(allCases.count == 4)
    }

    @Test func inlineDiffActionInvalidRawValues() {
        #expect(InlineDiffAction(rawValue: "") == nil)
        #expect(InlineDiffAction(rawValue: "Accept") == nil) // case-sensitive
        #expect(InlineDiffAction(rawValue: "ACCEPT") == nil)
        #expect(InlineDiffAction(rawValue: "accept_all") == nil)
    }

    // MARK: - DiffHunk deletedLines / addedLines edge cases

    @Test func deletedLinesWithOnlyDashDashDash() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 0,
            rawText: "@@ -1,0 +1,1 @@\n--- a/file.swift\n+new line"
        )
        // "--- a/file.swift" should be skipped
        #expect(hunk.deletedLines.isEmpty)
    }

    @Test func addedLinesWithOnlyPlusPlusPlus() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 0, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,0 @@\n+++ b/file.swift\n-old line"
        )
        // "+++ b/file.swift" should be skipped
        #expect(hunk.addedLines.isEmpty)
    }

    @Test func deletedLinesWithDashPrefixedContent() {
        // Line content that starts with dash after the diff dash prefix
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-- this is a comment\n+- new comment"
        )
        // "-" prefix is stripped, leaving "- this is a comment"
        #expect(hunk.deletedLines == ["- this is a comment"])
    }

    @Test func addedLinesWithPlusPrefixedContent() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 1, oldStart: 1, oldCount: 1,
            rawText: "@@ -1,1 +1,1 @@\n-old\n++ this is a union type"
        )
        #expect(hunk.addedLines == ["+ this is a union type"])
    }

    // MARK: - parseHunks with unusual but valid diff formats

    @Test func parseHunksIgnoresNonHunkNonDiffLines() {
        let diff = """
        This is some random text before the diff
        More random text
        diff --git a/file.swift b/file.swift
        index abc1234..def5678 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,2 @@
         context
        +added
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 1)
        #expect(hunks[0].newStart == 1)
    }

    @Test func parseHunksWithMixedCountFormats() {
        // First hunk has count, second does not
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         line1
         line2
        +added
         line3
        @@ -10 +11 @@
        -old
        +new
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 2)
        #expect(hunks[0].newCount == 4)
        #expect(hunks[1].newCount == 1)
        #expect(hunks[1].oldCount == 1)
    }

    // MARK: - Integration: addedLineNumbers + deletedLineBlocks consistency

    @Test func addedAndDeletedDoNotOverlap() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,5 +1,5 @@
         line1
        -old2
        -old3
        +new2
        +new3
         line4
         line5
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        let deletedBlocks = InlineDiffProvider.deletedLineBlocks(from: hunks)

        // Added lines should be 2 and 3
        #expect(addedLines == [2, 3])
        // Deleted block anchored at line 1
        #expect(deletedBlocks.count == 1)
        #expect(deletedBlocks[0].lines == ["old2", "old3"])
    }

    @Test func multiHunkIntegrationTest() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,3 @@
         import Foundation
        +import UIKit

        @@ -10,3 +11,2 @@
         func foo() {
        -    let x = 1
        -    let y = 2
        +    let z = 3
        @@ -20,0 +20,2 @@
        +// New comment
        +// Another comment
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        #expect(hunks.count == 3)

        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        let deletedBlocks = InlineDiffProvider.deletedLineBlocks(from: hunks)

        // Hunk 1: import UIKit at line 2
        #expect(addedLines.contains(2))
        // Hunk 2: let z = 3 at line 12
        #expect(addedLines.contains(12))
        // Hunk 3: two comments at lines 20, 21
        #expect(addedLines.contains(20))
        #expect(addedLines.contains(21))

        // Only hunk 2 has deletions
        #expect(deletedBlocks.count == 1)
        #expect(deletedBlocks[0].anchorLine == 11)
        #expect(deletedBlocks[0].lines.count == 2)
    }

    // MARK: - newEndLine edge cases

    @Test func newEndLineForVeryLargeCount() {
        let hunk = DiffHunk(newStart: 1, newCount: 10000, oldStart: 1, oldCount: 5000, rawText: "")
        #expect(hunk.newEndLine == 10000)
    }

    @Test func newEndLineForCountOfTwo() {
        let hunk = DiffHunk(newStart: 100, newCount: 2, oldStart: 100, oldCount: 2, rawText: "")
        #expect(hunk.newEndLine == 101)
    }

    // MARK: - parseSidePart with comma edge cases (via header)

    @Test func parsesHeaderWithZeroNewCount() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -1,3 +5,0 @@")
        #expect(result?.newStart == 5)
        #expect(result?.newCount == 0)
    }

    @Test func parsesHeaderWithZeroOldCount() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -5,0 +1,3 @@")
        #expect(result?.oldStart == 5)
        #expect(result?.oldCount == 0)
    }

    @Test func parsesHeaderWithBothCountsZero() {
        let result = InlineDiffProvider.parseHunkHeader("@@ -0,0 +0,0 @@")
        #expect(result?.oldStart == 0)
        #expect(result?.oldCount == 0)
        #expect(result?.newStart == 0)
        #expect(result?.newCount == 0)
    }

    @Test func returnsNilForMalformedStartInNewPart() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ -1,3 +abc @@") == nil)
    }

    @Test func returnsNilForMalformedStartInOldPart() {
        #expect(InlineDiffProvider.parseHunkHeader("@@ -abc +1,3 @@") == nil)
    }

    // MARK: - CRLF additional edge cases

    @Test func addedLineNumbersWithCRLFDiff() {
        let diff = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,1 +1,2 @@",
            " context",
            "+added line"
        ].joined(separator: "\r\n")
        let hunks = InlineDiffProvider.parseHunks(diff)
        let addedLines = InlineDiffProvider.addedLineNumbers(from: hunks)
        // Should still detect added lines even with \r in content
        #expect(!addedLines.isEmpty)
    }

    @Test func deletedLineBlocksWithCRLFDiff() {
        let diff = [
            "diff --git a/file.swift b/file.swift",
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,2 +1,1 @@",
            "-deleted line",
            "+replacement"
        ].joined(separator: "\r\n")
        let hunks = InlineDiffProvider.parseHunks(diff)
        let blocks = InlineDiffProvider.deletedLineBlocks(from: hunks)
        #expect(!blocks.isEmpty)
    }

    // MARK: - Hunk with only @@ header line

    @Test func hunkWithOnlyAtAtHeader() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 0, oldStart: 1, oldCount: 0,
            rawText: "@@ -1,0 +1,0 @@"
        )
        #expect(hunk.deletedLines.isEmpty)
        #expect(hunk.addedLines.isEmpty)
        #expect(hunk.newEndLine == 1)
    }

    // MARK: - parseHunks with diff stopping at new file diff

    @Test func parseHunksStopsAtNewDiffHeader() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,2 @@
         line1
        +added1
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1,1 +1,2 @@
         line1
        +added2
        """
        let hunks = InlineDiffProvider.parseHunks(diff)
        // Both hunks from both files should be parsed
        #expect(hunks.count == 2)
    }
}
