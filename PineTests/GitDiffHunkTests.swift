//
//  GitDiffHunkTests.swift
//  PineTests
//
//  Unit tests for GitDiffHunk models and GitStatusProvider hunk-parsing / file-diff methods.
//

import Foundation
import Testing
@testable import Pine

struct GitDiffHunkTests {

    // MARK: - parseHunkBounds

    @Test func parsesSimpleHunkBounds() throws {
        let result = try #require(GitStatusProvider.parseHunkBounds("@@ -1,3 +5,4 @@"))
        #expect(result.0 == 1)
        #expect(result.1 == 3)
        #expect(result.2 == 5)
        #expect(result.3 == 4)
    }

    @Test func parsesHunkBoundsWithoutCounts() throws {
        // @@ -10 +10 @@ means single line (count defaults to 1)
        let result = try #require(GitStatusProvider.parseHunkBounds("@@ -10 +10 @@"))
        #expect(result.0 == 10)
        #expect(result.2 == 10)
    }

    @Test func parsesHunkBoundsForNewFile() throws {
        let result = try #require(GitStatusProvider.parseHunkBounds("@@ -0,0 +1,5 @@"))
        #expect(result.0 == 0)
        #expect(result.1 == 0)
        #expect(result.2 == 1)
        #expect(result.3 == 5)
    }

    @Test func returnsNilForInvalidHunkBounds() {
        #expect(GitStatusProvider.parseHunkBounds("not a hunk") == nil)
        #expect(GitStatusProvider.parseHunkBounds("") == nil)
    }

    // MARK: - parseDiffHunks

    @Test func parsesAddedLinesAsHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let hunks = GitStatusProvider.parseDiffHunks(diff, filePath: "file.swift")
        #expect(hunks.count == 1)
        let hunk = hunks[0]
        #expect(hunk.oldStart == 0)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 3)
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines.allSatisfy { $0.kind == .added })
        #expect(hunk.filePath == "file.swift")
    }

    @Test func parsesDeletedLinesAsHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -1,2 +1,0 @@
        -old line 1
        -old line 2
        """
        let hunks = GitStatusProvider.parseDiffHunks(diff, filePath: "file.swift")
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.count == 2)
        #expect(hunks[0].lines.allSatisfy { $0.kind == .deleted })
    }

    @Test func parsesContextLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -1,5 +1,5 @@
         context1
         context2
        -old
        +new
         context3
         context4
        """
        let hunks = GitStatusProvider.parseDiffHunks(diff, filePath: "file.swift")
        #expect(hunks.count == 1)
        let lines = hunks[0].lines
        #expect(lines.count == 6)
        #expect(lines[0].kind == .context)
        #expect(lines[1].kind == .context)
        #expect(lines[2].kind == .deleted)
        #expect(lines[3].kind == .added)
        #expect(lines[4].kind == .context)
        #expect(lines[5].kind == .context)
    }

    @Test func parsesMultipleHunks() {
        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -1,1 +1,1 @@
        -old1
        +new1
        @@ -20,0 +20,2 @@
        +added1
        +added2
        """
        let hunks = GitStatusProvider.parseDiffHunks(diff, filePath: "file.swift")
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.count == 2)
        #expect(hunks[1].lines.count == 2)
        #expect(hunks[1].lines.allSatisfy { $0.kind == .added })
    }

    @Test func assignsCorrectLineNumbers() {
        let diff = """
        diff --git a/f.swift b/f.swift
        @@ -5,3 +5,3 @@
         context
        -deleted
        +added
         context2
        """
        let hunks = GitStatusProvider.parseDiffHunks(diff, filePath: "f.swift")
        #expect(hunks.count == 1)
        let lines = hunks[0].lines
        // context on old line 5, new line 5
        #expect(lines[0].oldLineNumber == 5)
        #expect(lines[0].newLineNumber == 5)
        // deleted on old line 6
        #expect(lines[1].oldLineNumber == 6)
        #expect(lines[1].newLineNumber == nil)
        // added on new line 6
        #expect(lines[2].oldLineNumber == nil)
        #expect(lines[2].newLineNumber == 6)
        // context on old line 7, new line 7
        #expect(lines[3].oldLineNumber == 7)
        #expect(lines[3].newLineNumber == 7)
    }

    @Test func parsesEmptyDiffAsNoHunks() {
        let hunks = GitStatusProvider.parseDiffHunks("", filePath: "file.swift")
        #expect(hunks.isEmpty)
    }

    // MARK: - GitDiffLine.rawLine

    @Test func rawLineAdded() {
        let line = GitDiffLine(kind: .added, content: "hello", oldLineNumber: nil, newLineNumber: 1)
        #expect(line.rawLine == "+hello")
    }

    @Test func rawLineDeleted() {
        let line = GitDiffLine(kind: .deleted, content: "world", oldLineNumber: 1, newLineNumber: nil)
        #expect(line.rawLine == "-world")
    }

    @Test func rawLineContext() {
        let line = GitDiffLine(kind: .context, content: "ctx", oldLineNumber: 1, newLineNumber: 1)
        #expect(line.rawLine == " ctx")
    }

    // MARK: - GitDiffHunk.buildPatch

    @Test func buildPatchContainsFilePath() {
        let hunk = GitDiffHunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            lines: [
                GitDiffLine(kind: .deleted, content: "old", oldLineNumber: 1, newLineNumber: nil),
                GitDiffLine(kind: .added, content: "new", oldLineNumber: nil, newLineNumber: 1)
            ],
            filePath: "Sources/Foo.swift"
        )
        let patch = hunk.buildPatch()
        #expect(patch.contains("a/Sources/Foo.swift"))
        #expect(patch.contains("b/Sources/Foo.swift"))
        #expect(patch.contains("@@ -1,1 +1,1 @@"))
        #expect(patch.contains("-old"))
        #expect(patch.contains("+new"))
    }

    @Test func buildPatchEndsWithNewline() {
        let hunk = GitDiffHunk(
            header: "@@ -0,0 +1,1 @@",
            oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
            lines: [GitDiffLine(kind: .added, content: "line", oldLineNumber: nil, newLineNumber: 1)],
            filePath: "file.txt"
        )
        #expect(hunk.buildPatch().hasSuffix("\n"))
    }

    // MARK: - parseFileDiffs

    @Test func parsesFileDiffsMultipleFiles() {
        let output = """
        diff --git a/A.swift b/A.swift
        index 0000000..1111111 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        diff --git a/B.swift b/B.swift
        index 0000000..2222222 100644
        --- a/B.swift
        +++ b/B.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let diffs = GitStatusProvider.parseFileDiffs(output, isStaged: false)
        #expect(diffs.count == 2)
        #expect(diffs[0].filePath == "A.swift")
        #expect(diffs[1].filePath == "B.swift")
        #expect(diffs[0].hunks.count == 1)
        #expect(diffs[1].hunks.count == 1)
        #expect(diffs[0].isStaged == false)
    }

    @Test func parsesFileDiffsIsStaged() {
        let output = """
        diff --git a/Foo.swift b/Foo.swift
        index abc..def 100644
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let diffs = GitStatusProvider.parseFileDiffs(output, isStaged: true)
        #expect(diffs.count == 1)
        #expect(diffs[0].isStaged == true)
        #expect(diffs[0].status == .staged)
    }

    @Test func parsesNewFileStatus() {
        let output = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let diffs = GitStatusProvider.parseFileDiffs(output, isStaged: true)
        #expect(diffs.count == 1)
        #expect(diffs[0].status == .added)
    }

    @Test func parsesDeletedFileStatus() {
        let output = """
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        index abc1234..0000000
        --- a/Old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let diffs = GitStatusProvider.parseFileDiffs(output, isStaged: true)
        #expect(diffs.count == 1)
        #expect(diffs[0].status == .deleted)
    }

    @Test func parsesEmptyOutputAsEmptyArray() {
        let diffs = GitStatusProvider.parseFileDiffs("", isStaged: false)
        #expect(diffs.isEmpty)
    }

    // MARK: - extractFilePath

    @Test func extractsFilePathFromPathLine() {
        #expect(GitStatusProvider.extractFilePath(from: "a/Sources/Foo.swift b/Sources/Foo.swift")
                == "Sources/Foo.swift")
    }

    @Test func extractsFilePathWithSpaces() {
        #expect(GitStatusProvider.extractFilePath(from: "a/examples copy/file.swift b/examples copy/file.swift")
                == "examples copy/file.swift")
    }

    // MARK: - GitFileDiff.fileName

    @Test func fileNameReturnsLastPathComponent() {
        let diff = GitFileDiff(
            filePath: "Sources/Models/Foo.swift",
            isStaged: false,
            status: .modified,
            hunks: []
        )
        #expect(diff.fileName == "Foo.swift")
    }
}
