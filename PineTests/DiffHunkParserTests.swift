//
//  DiffHunkParserTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct DiffHunkParserTests {

    // MARK: - parseHunkHeader

    @Test func parsesStandardHunkHeader() {
        let result = GitStatusProvider.parseHunkHeader("@@ -10,5 +10,7 @@ func foo()")
        #expect(result != nil)
        let (oldStart, oldCount, newStart, newCount) = result!
        #expect(oldStart == 10)
        #expect(oldCount == 5)
        #expect(newStart == 10)
        #expect(newCount == 7)
    }

    @Test func parsesHunkHeaderWithoutCount() {
        let result = GitStatusProvider.parseHunkHeader("@@ -1 +1 @@")
        #expect(result != nil)
        let (oldStart, oldCount, newStart, newCount) = result!
        #expect(oldStart == 1)
        #expect(oldCount == 1)
        #expect(newStart == 1)
        #expect(newCount == 1)
    }

    @Test func parsesHunkHeaderMixedCounts() {
        let result = GitStatusProvider.parseHunkHeader("@@ -5,3 +5 @@")
        #expect(result != nil)
        let (_, oldCount, _, newCount) = result!
        #expect(oldCount == 3)
        #expect(newCount == 1)
    }

    @Test func parsesHunkHeaderZeroCount() {
        let result = GitStatusProvider.parseHunkHeader("@@ -0,0 +1,3 @@")
        #expect(result != nil)
        let (oldStart, oldCount, newStart, newCount) = result!
        #expect(oldStart == 0)
        #expect(oldCount == 0)
        #expect(newStart == 1)
        #expect(newCount == 3)
    }

    @Test func returnsNilForInvalidHeader() {
        #expect(GitStatusProvider.parseHunkHeader("not a hunk") == nil)
        #expect(GitStatusProvider.parseHunkHeader("") == nil)
    }

    // MARK: - parseFilePath

    @Test func parsesSimpleFilePath() {
        let path = GitStatusProvider.parseFilePath(from: "diff --git a/Pine/Foo.swift b/Pine/Foo.swift")
        #expect(path == "Pine/Foo.swift")
    }

    @Test func parsesFilePathWithSpaces() {
        let path = GitStatusProvider.parseFilePath(from: "diff --git a/dir/my file.txt b/dir/my file.txt")
        #expect(path == "dir/my file.txt")
    }

    @Test func returnsNilForNonDiffLine() {
        #expect(GitStatusProvider.parseFilePath(from: "not a diff header") == nil)
    }

    // MARK: - parseFullDiff

    @Test func parsesEmptyOutput() {
        let result = GitStatusProvider.parseFullDiff("")
        #expect(result.isEmpty)
    }

    @Test func parsesSingleFileWithOneHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc1234..def5678 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         line1
        +added line
         line2
         line3
        """
        let result = GitStatusProvider.parseFullDiff(diff)
        #expect(result.count == 1)
        #expect(result["file.swift"]?.count == 1)

        let hunk = result["file.swift"]![0]
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 4)
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[1].kind == .added)
        #expect(hunk.lines[1].content == "added line")
        #expect(hunk.lines[2].kind == .context)
        #expect(hunk.lines[3].kind == .context)
    }

    @Test func parsesMultipleHunksInOneFile() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc1234..def5678 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         line1
        +added line
         line2
         line3
        @@ -10,3 +11,2 @@
         line10
        -removed line
         line12
        """
        let result = GitStatusProvider.parseFullDiff(diff)
        #expect(result["file.swift"]?.count == 2)

        let hunk1 = result["file.swift"]![0]
        #expect(hunk1.newStart == 1)
        #expect(hunk1.lines.filter { $0.kind == .added }.count == 1)

        let hunk2 = result["file.swift"]![1]
        #expect(hunk2.oldStart == 10)
        #expect(hunk2.lines.filter { $0.kind == .removed }.count == 1)
    }

    @Test func parsesMultipleFiles() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index abc..def 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,2 +1,3 @@
         line1
        +new
         line2
        diff --git a/bar.swift b/bar.swift
        index abc..def 100644
        --- a/bar.swift
        +++ b/bar.swift
        @@ -5,3 +5,2 @@
         old
        -deleted
         remaining
        """
        let result = GitStatusProvider.parseFullDiff(diff)
        #expect(result.count == 2)
        #expect(result["foo.swift"]?.count == 1)
        #expect(result["bar.swift"]?.count == 1)
    }

    @Test func parsesAddedAndRemovedLines() {
        let diff = """
        diff --git a/test.txt b/test.txt
        index abc..def 100644
        --- a/test.txt
        +++ b/test.txt
        @@ -1,3 +1,3 @@
         keep
        -old line
        +new line
         keep
        """
        let result = GitStatusProvider.parseFullDiff(diff)
        let hunk = result["test.txt"]![0]
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[1].kind == .removed)
        #expect(hunk.lines[1].content == "old line")
        #expect(hunk.lines[2].kind == .added)
        #expect(hunk.lines[2].content == "new line")
        #expect(hunk.lines[3].kind == .context)
    }

    @Test func handlesNoNewlineAtEndOfFile() {
        let diff = """
        diff --git a/test.txt b/test.txt
        index abc..def 100644
        --- a/test.txt
        +++ b/test.txt
        @@ -1,2 +1,2 @@
         line1
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let result = GitStatusProvider.parseFullDiff(diff)
        let hunk = result["test.txt"]![0]
        let contentLines = hunk.lines.filter { $0.kind != .context || !$0.content.isEmpty }
        #expect(contentLines.count >= 3)
    }

    // MARK: - patchForHunk

    @Test func generatesPatchForHunk() {
        let hunk = DiffHunk(
            oldStart: 1,
            oldCount: 3,
            newStart: 1,
            newCount: 4,
            header: "@@ -1,3 +1,4 @@",
            lines: [
                DiffLine(kind: .context, content: "line1"),
                DiffLine(kind: .added, content: "new line"),
                DiffLine(kind: .context, content: "line2"),
                DiffLine(kind: .context, content: "line3")
            ]
        )

        let patch = GitStatusProvider.patchForHunk(hunk, filePath: "test.swift")
        #expect(patch.contains("--- a/test.swift"))
        #expect(patch.contains("+++ b/test.swift"))
        #expect(patch.contains("@@ -1,3 +1,4 @@"))
        #expect(patch.contains("+new line"))
        #expect(patch.contains(" line1"))
    }

    // MARK: - splitStatuses

    @Test func splitsStagedAndUnstagedStatuses() {
        // This tests the parsing logic by examining what splitStatuses returns
        // for known porcelain output
        let output = "M  staged.swift\n M unstaged.swift\nMM both.swift\n?? new.swift\nA  added.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)

        // Verify the combined status view
        #expect(statuses["staged.swift"] == .staged)
        #expect(statuses["unstaged.swift"] == .modified)
        #expect(statuses["both.swift"] == .mixed)
        #expect(statuses["new.swift"] == .untracked)
        #expect(statuses["added.swift"] == .added)
    }
}
