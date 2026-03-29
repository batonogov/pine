//
//  GitDiffProviderTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct GitDiffProviderTests {

    // MARK: - parseFilePath

    @Test func parsesStandardFilePath() {
        let line = "diff --git a/Sources/main.swift b/Sources/main.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "Sources/main.swift")
    }

    @Test func parsesFilePathWithSpaces() {
        let line = "diff --git a/my file.swift b/my file.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "my file.swift")
    }

    @Test func parsesRenamedFilePath() {
        // When a file is renamed, b/ points to the new name
        let line = "diff --git a/old.swift b/new.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "new.swift")
    }

    @Test func parsesDeepNestedPath() {
        let line = "diff --git a/Pine/Views/Editor/CodeView.swift b/Pine/Views/Editor/CodeView.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "Pine/Views/Editor/CodeView.swift")
    }

    // MARK: - parseUnifiedDiff — path with b/ in directory name

    @Test func parsesPathWithBSlashInDirectory() {
        let diff = """
        diff --git a/a/b/file.swift b/a/b/file.swift
        index abc..def 100644
        --- a/a/b/file.swift
        +++ b/a/b/file.swift
        @@ -1,2 +1,2 @@
        -old
        +new
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].filePath == "a/b/file.swift")
    }

    @Test func parsesPathWithMultipleBSlashSegments() {
        let diff = """
        diff --git a/b/b/b/test.swift b/b/b/b/test.swift
        index abc..def 100644
        --- a/b/b/b/test.swift
        +++ b/b/b/b/test.swift
        @@ -1 +1 @@
        -a
        +b
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].filePath == "b/b/b/test.swift")
    }

    // MARK: - parseUnifiedDiff — empty input

    @Test func emptyInputReturnsEmptyArray() {
        let result = GitDiffProvider.parseUnifiedDiff("", isStaged: false)
        #expect(result.isEmpty)
    }

    // MARK: - parseUnifiedDiff — single file, single hunk

    @Test func parsesSingleFileSingleHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc1234..def5678 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         import Foundation
        +import SwiftUI

         struct Foo {
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].filePath == "file.swift")
        #expect(result[0].isStaged == false)
        #expect(result[0].hunks.count == 1)

        let lines = result[0].hunks[0].lines
        #expect(lines.count == 4)
        #expect(lines[0].kind == .context)
        #expect(lines[0].text == "import Foundation")
        #expect(lines[1].kind == .added)
        #expect(lines[1].text == "import SwiftUI")
        #expect(lines[2].kind == .context)
    }

    // MARK: - parseUnifiedDiff — deleted lines

    @Test func parsesDeletedLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,4 +1,3 @@
         line1
        -line2
         line3
         line4
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: true)
        #expect(result.count == 1)
        #expect(result[0].isStaged == true)

        let lines = result[0].hunks[0].lines
        let removed = lines.filter { $0.kind == .removed }
        #expect(removed.count == 1)
        #expect(removed[0].text == "line2")
    }

    // MARK: - parseUnifiedDiff — multiple files

    @Test func parsesMultipleFiles() {
        let diff = """
        diff --git a/a.swift b/a.swift
        index abc..def 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,3 @@
         line1
        +line2
         line3
        diff --git a/b.swift b/b.swift
        index 123..456 100644
        --- a/b.swift
        +++ b/b.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 2)
        #expect(result[0].filePath == "a.swift")
        #expect(result[1].filePath == "b.swift")
    }

    // MARK: - parseUnifiedDiff — multiple hunks in one file

    @Test func parsesMultipleHunksInOneFile() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         line1
        +inserted
         line2
         line3
        @@ -10,3 +11,4 @@
         line10
        +another
         line11
         line12
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].hunks.count == 2)
        #expect(result[0].hunks[0].header.contains("-1,3"))
        #expect(result[0].hunks[1].header.contains("-10,3"))
    }

    // MARK: - parseUnifiedDiff — no newline at end of file

    @Test func handlesNoNewlineMarker() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
        -old line
        +new line
        \\ No newline at end of file
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        let lines = result[0].hunks[0].lines
        // "\ No newline" marker should be skipped
        #expect(lines.count == 2)
        #expect(lines[0].kind == .removed)
        #expect(lines[1].kind == .added)
    }

    // MARK: - parseUnifiedDiff — staged flag propagation

    @Test func stagedFlagPropagates() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1 @@
        -a
        +b
        """
        let staged = GitDiffProvider.parseUnifiedDiff(diff, isStaged: true)
        let unstaged = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(staged[0].isStaged == true)
        #expect(unstaged[0].isStaged == false)
    }

    // MARK: - parseUnifiedDiff — mixed added and removed

    @Test func parsesMixedAddedAndRemoved() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,5 +1,5 @@
         context1
        -removed1
        -removed2
        +added1
        +added2
         context2
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        let lines = result[0].hunks[0].lines
        let removed = lines.filter { $0.kind == .removed }
        let added = lines.filter { $0.kind == .added }
        let context = lines.filter { $0.kind == .context }
        #expect(removed.count == 2)
        #expect(added.count == 2)
        #expect(context.count == 2)
    }

    // MARK: - parseUnifiedDiff — empty diff body

    @Test func emptyDiffBodyNoHunks() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        // File with no hunks should not be included
        #expect(result.isEmpty)
    }

    // MARK: - parseUnifiedDiff — only additions (new file)

    @Test func parsesNewFileAllAdded() {
        let diff = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: true)
        #expect(result.count == 1)
        #expect(result[0].filePath == "new.swift")
        let lines = result[0].hunks[0].lines
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.kind == .added })
    }

    // MARK: - GitDiffLine equality

    @Test func diffLineEquality() {
        let line1 = GitDiffLine(kind: .added, text: "hello")
        let line2 = GitDiffLine(kind: .added, text: "hello")
        let line3 = GitDiffLine(kind: .removed, text: "hello")
        let line4 = GitDiffLine(kind: .added, text: "world")
        // Custom == compares kind + text, ignoring UUID id
        #expect(line1 == line2)
        #expect(line1 != line3)
        #expect(line1 != line4)
        // Different instances have different IDs for Identifiable
        #expect(line1.id != line2.id)
    }

    // MARK: - GitDiffLine Identifiable distinct IDs

    @Test func diffLineHasDistinctIDs() {
        let a = GitDiffLine(kind: .context, text: "same")
        let b = GitDiffLine(kind: .context, text: "same")
        #expect(a == b)
        #expect(a.id != b.id)
    }

    // MARK: - GitDiffHunk equality

    @Test func diffHunkEqualityByHeaderAndLines() {
        let hunk1 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [])
        let hunk2 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [])
        let hunk3 = GitDiffHunk(header: "@@ -2 +2 @@", lines: [])
        #expect(hunk1 == hunk2)
        #expect(hunk1 != hunk3)
    }

    // MARK: - GitFileDiff equality

    @Test func fileDiffEqualityByPathAndStaged() {
        let diff1 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff2 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff3 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: false)
        #expect(diff1 == diff2)
        #expect(diff1 != diff3)
    }

    @Test func fileDiffInequalityByPath() {
        let diff1 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff2 = GitFileDiff(filePath: "b.swift", hunks: [], isStaged: true)
        #expect(diff1 != diff2)
    }

    @Test func fileDiffInequalityByHunks() {
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        let diff1 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff2 = GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: true)
        #expect(diff1 != diff2)
    }

    @Test func fileDiffDistinctIDs() {
        let diff1 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff2 = GitFileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        #expect(diff1 == diff2)
        #expect(diff1.id != diff2.id)
    }

    // MARK: - GitDiffHunk equality with lines

    @Test func diffHunkEqualityWithMatchingLines() {
        let lines = [GitDiffLine(kind: .added, text: "hello"), GitDiffLine(kind: .removed, text: "world")]
        let hunk1 = GitDiffHunk(header: "@@ -1 +1 @@", lines: lines)
        let hunk2 = GitDiffHunk(header: "@@ -1 +1 @@", lines: lines)
        #expect(hunk1 == hunk2)
    }

    @Test func diffHunkInequalityWithDifferentLines() {
        let hunk1 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "a")])
        let hunk2 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "b")])
        #expect(hunk1 != hunk2)
    }

    @Test func diffHunkDistinctIDs() {
        let hunk1 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [])
        let hunk2 = GitDiffHunk(header: "@@ -1 +1 @@", lines: [])
        #expect(hunk1 == hunk2)
        #expect(hunk1.id != hunk2.id)
    }

    // MARK: - GitDiffLineKind — all variants

    @Test func diffLineKindEquality() {
        #expect(GitDiffLineKind.context == GitDiffLineKind.context)
        #expect(GitDiffLineKind.added == GitDiffLineKind.added)
        #expect(GitDiffLineKind.removed == GitDiffLineKind.removed)
        #expect(GitDiffLineKind.hunkHeader == GitDiffLineKind.hunkHeader)
        #expect(GitDiffLineKind.context != GitDiffLineKind.added)
        #expect(GitDiffLineKind.added != GitDiffLineKind.removed)
        #expect(GitDiffLineKind.removed != GitDiffLineKind.hunkHeader)
        #expect(GitDiffLineKind.hunkHeader != GitDiffLineKind.context)
    }

    // MARK: - GitDiffLine with hunkHeader kind

    @Test func diffLineHunkHeaderKind() {
        let line = GitDiffLine(kind: .hunkHeader, text: "@@ -1 +1 @@")
        #expect(line.kind == .hunkHeader)
        #expect(line.text == "@@ -1 +1 @@")
    }

    // MARK: - parseFilePath — additional edge cases

    @Test func parseFilePathWithNoBSlash() {
        // Fallback path when there's no " b/" separator
        let line = "diff --git something"
        let result = GitDiffProvider.parseFilePath(from: line)
        // Should use fallback (after a/)
        #expect(!result.isEmpty)
    }

    @Test func parseFilePathSingleComponent() {
        let line = "diff --git a/README.md b/README.md"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "README.md")
    }

    @Test func parseFilePathWithDotsInName() {
        let line = "diff --git a/some.test.file.swift b/some.test.file.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "some.test.file.swift")
    }

    @Test func parseFilePathWithDashes() {
        let line = "diff --git a/my-great-file.swift b/my-great-file.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "my-great-file.swift")
    }

    @Test func parseFilePathDeepNested() {
        let line = "diff --git a/a/b/c/d/e/f.swift b/a/b/c/d/e/f.swift"
        let result = GitDiffProvider.parseFilePath(from: line)
        #expect(result == "a/b/c/d/e/f.swift")
    }

    // MARK: - parseUnifiedDiff — deleted file (only removals)

    @Test func parsesDeletedFileAllRemoved() {
        let diff = """
        diff --git a/old.swift b/old.swift
        deleted file mode 100644
        index abc1234..0000000
        --- a/old.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -line1
        -line2
        -line3
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].filePath == "old.swift")
        let lines = result[0].hunks[0].lines
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.kind == .removed })
    }

    // MARK: - parseUnifiedDiff — binary file (no hunks)

    @Test func parsesBinaryGitFileDiffNoHunks() {
        let diff = """
        diff --git a/image.png b/image.png
        index abc..def 100644
        Binary files a/image.png and b/image.png differ
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        // Binary files have no hunks, so should not appear in results
        #expect(result.isEmpty)
    }

    @Test func parsesBinaryFileAmongTextFiles() {
        let diff = """
        diff --git a/code.swift b/code.swift
        index abc..def 100644
        --- a/code.swift
        +++ b/code.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/image.png b/image.png
        index 111..222 100644
        Binary files a/image.png and b/image.png differ
        diff --git a/other.swift b/other.swift
        index 333..444 100644
        --- a/other.swift
        +++ b/other.swift
        @@ -1 +1 @@
        -foo
        +bar
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        // Only text files with hunks should appear
        #expect(result.count == 2)
        #expect(result[0].filePath == "code.swift")
        #expect(result[1].filePath == "other.swift")
    }

    // MARK: - parseUnifiedDiff — only context lines (no actual changes)

    @Test func parsesOnlyContextLinesInHunk() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
         line1
         line2
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        let lines = result[0].hunks[0].lines
        #expect(lines.allSatisfy { $0.kind == .context })
    }

    // MARK: - parseUnifiedDiff — garbage input

    @Test func garbageInputReturnsEmpty() {
        let result = GitDiffProvider.parseUnifiedDiff("random garbage text\nno diffs here", isStaged: false)
        #expect(result.isEmpty)
    }

    @Test func singleLineGarbage() {
        let result = GitDiffProvider.parseUnifiedDiff("hello", isStaged: true)
        #expect(result.isEmpty)
    }

    // MARK: - parseUnifiedDiff — whitespace-only input

    @Test func whitespaceOnlyInputReturnsEmpty() {
        let result = GitDiffProvider.parseUnifiedDiff("   \n  \n\t\n", isStaged: false)
        #expect(result.isEmpty)
    }

    // MARK: - parseUnifiedDiff — many files

    @Test func parsesManyFiles() {
        var diff = ""
        for i in 0..<10 {
            diff += """
            diff --git a/file\(i).swift b/file\(i).swift
            index abc..def 100644
            --- a/file\(i).swift
            +++ b/file\(i).swift
            @@ -1 +1 @@
            -old\(i)
            +new\(i)\n
            """
        }
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 10)
        for i in 0..<10 {
            #expect(result[i].filePath == "file\(i).swift")
        }
    }

    // MARK: - parseUnifiedDiff — large hunk with many lines

    @Test func parsesLargeHunk() {
        var diffText = """
        diff --git a/big.swift b/big.swift
        index abc..def 100644
        --- a/big.swift
        +++ b/big.swift
        @@ -1,100 +1,200 @@
        """
        for i in 0..<100 {
            diffText += "\n+added line \(i)"
        }
        let result = GitDiffProvider.parseUnifiedDiff(diffText, isStaged: false)
        #expect(result.count == 1)
        #expect(result[0].hunks[0].lines.count == 100)
        #expect(result[0].hunks[0].lines.allSatisfy { $0.kind == .added })
    }

    // MARK: - allChangedPaths

    @Test func allChangedPathsEmpty() {
        let provider = GitDiffProvider()
        #expect(provider.allChangedPaths.isEmpty)
    }

    @Test func allChangedPathsFromStagedOnly() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        provider.stagedFiles = [
            GitFileDiff(filePath: "b.swift", hunks: [hunk], isStaged: true),
            GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: true)
        ]
        #expect(provider.allChangedPaths == ["a.swift", "b.swift"])
    }

    @Test func allChangedPathsFromUnstagedOnly() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .removed, text: "x")])
        provider.unstagedFiles = [
            GitFileDiff(filePath: "c.swift", hunks: [hunk], isStaged: false)
        ]
        #expect(provider.allChangedPaths == ["c.swift"])
    }

    @Test func allChangedPathsDeduplicatesStagedAndUnstaged() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        provider.stagedFiles = [
            GitFileDiff(filePath: "shared.swift", hunks: [hunk], isStaged: true),
            GitFileDiff(filePath: "staged-only.swift", hunks: [hunk], isStaged: true)
        ]
        provider.unstagedFiles = [
            GitFileDiff(filePath: "shared.swift", hunks: [hunk], isStaged: false),
            GitFileDiff(filePath: "unstaged-only.swift", hunks: [hunk], isStaged: false)
        ]
        let paths = provider.allChangedPaths
        #expect(paths.count == 3)
        #expect(paths == ["shared.swift", "staged-only.swift", "unstaged-only.swift"])
    }

    @Test func allChangedPathsAreSorted() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [])
        provider.stagedFiles = [
            GitFileDiff(filePath: "z.swift", hunks: [hunk], isStaged: true),
            GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: true),
            GitFileDiff(filePath: "m.swift", hunks: [hunk], isStaged: true)
        ]
        #expect(provider.allChangedPaths == ["a.swift", "m.swift", "z.swift"])
    }

    // MARK: - GitDiffProvider initial state

    @Test func initialStateIsEmpty() {
        let provider = GitDiffProvider()
        #expect(provider.stagedFiles.isEmpty)
        #expect(provider.unstagedFiles.isEmpty)
        #expect(provider.isRefreshing == false)
        #expect(provider.allChangedPaths.isEmpty)
    }

    // MARK: - parseUnifiedDiff — mode change without content

    @Test func parsesModeChangeOnly() {
        let diff = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        // Mode-only change has no hunks
        #expect(result.isEmpty)
    }

    // MARK: - parseUnifiedDiff — file with empty lines in diff

    @Test func parsesFileWithEmptyContextLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,4 +1,5 @@
         line1

        +inserted

         line4
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        let lines = result[0].hunks[0].lines
        let addedLines = lines.filter { $0.kind == .added }
        #expect(addedLines.count == 1)
        #expect(addedLines[0].text == "inserted")
    }

    // MARK: - parseUnifiedDiff — rename with content changes

    @Test func parsesRenamedFileWithChanges() {
        let diff = """
        diff --git a/old_name.swift b/new_name.swift
        similarity index 80%
        rename from old_name.swift
        rename to new_name.swift
        index abc..def 100644
        --- a/old_name.swift
        +++ b/new_name.swift
        @@ -1,2 +1,2 @@
        -old content
        +new content
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: true)
        #expect(result.count == 1)
        #expect(result[0].filePath == "new_name.swift")
        #expect(result[0].isStaged == true)
    }

    // MARK: - runGitAsync

    @Test func runGitAsyncReturnsValueFromBackground() async {
        let provider = GitDiffProvider()
        let result = await provider.runGitAsync { 42 }
        #expect(result == 42)
    }

    @Test func runGitAsyncReturnsStringFromBackground() async {
        let provider = GitDiffProvider()
        let result = await provider.runGitAsync { "hello from background" }
        #expect(result == "hello from background")
    }

    @Test func runGitAsyncExecutesClosure() async {
        let provider = GitDiffProvider()
        let result = await provider.runGitAsync {
            let arr = (0..<100).map { $0 * 2 }
            return arr.reduce(0, +)
        }
        // Sum of 0, 2, 4, ..., 198 = 2 * (0+1+...+99) = 2 * 4950 = 9900
        #expect(result == 9900)
    }

    @Test func runGitAsyncReturnsTuple() async {
        let provider = GitDiffProvider()
        let (a, b) = await provider.runGitAsync { (1, "test") }
        #expect(a == 1)
        #expect(b == "test")
    }

    // MARK: - refresh with real git repo

    @Test func refreshInNonGitDirectoryProducesEmptyResults() async {
        let provider = GitDiffProvider()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-no-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        await provider.refresh(at: tmpDir)

        #expect(provider.stagedFiles.isEmpty)
        #expect(provider.unstagedFiles.isEmpty)
        #expect(provider.isRefreshing == false)
    }

    @Test func refreshInGitRepoWithNoChangesProducesEmptyResults() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Init git repo with initial commit
        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        let provider = GitDiffProvider()
        await provider.refresh(at: tmpDir)

        #expect(provider.stagedFiles.isEmpty)
        #expect(provider.unstagedFiles.isEmpty)
        #expect(provider.isRefreshing == false)
    }

    @Test func refreshDetectsUnstagedChanges() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-unstaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        // Make an unstaged change
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)

        let provider = GitDiffProvider()
        await provider.refresh(at: tmpDir)

        #expect(!provider.unstagedFiles.isEmpty)
        #expect(provider.unstagedFiles[0].filePath == "test.txt")
        #expect(provider.stagedFiles.isEmpty)
    }

    @Test func refreshDetectsStagedChanges() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        // Make a staged change
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "test.txt"], at: tmpDir)

        let provider = GitDiffProvider()
        await provider.refresh(at: tmpDir)

        #expect(!provider.stagedFiles.isEmpty)
        #expect(provider.stagedFiles[0].filePath == "test.txt")
    }

    // MARK: - Stage / Unstage / Discard integration

    @Test func stageFileWorksInRealRepo() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        try "modified".write(to: testFile, atomically: true, encoding: .utf8)

        let provider = GitDiffProvider()
        let success = await provider.stageFile("test.txt", at: tmpDir)
        #expect(success)

        // Verify it's now staged
        await provider.refresh(at: tmpDir)
        #expect(!provider.stagedFiles.isEmpty)
    }

    @Test func unstageFileWorksInRealRepo() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-unstage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        try "modified".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "test.txt"], at: tmpDir)

        let provider = GitDiffProvider()
        let success = await provider.unstageFile("test.txt", at: tmpDir)
        #expect(success)

        // Verify it's now unstaged
        await provider.refresh(at: tmpDir)
        #expect(provider.stagedFiles.isEmpty)
        #expect(!provider.unstagedFiles.isEmpty)
    }

    @Test func discardChangesWorksInRealRepo() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        try "modified".write(to: testFile, atomically: true, encoding: .utf8)

        let provider = GitDiffProvider()
        let success = await provider.discardChanges("test.txt", at: tmpDir)
        #expect(success)

        // Verify file is restored
        let content = try String(contentsOf: testFile, encoding: .utf8)
        #expect(content == "hello")
    }

    @Test func stageAllWorksInRealRepo() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-stageall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let file1 = tmpDir.appendingPathComponent("a.txt")
        let file2 = tmpDir.appendingPathComponent("b.txt")
        try "a".write(to: file1, atomically: true, encoding: .utf8)
        try "b".write(to: file2, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        try "a modified".write(to: file1, atomically: true, encoding: .utf8)
        try "b modified".write(to: file2, atomically: true, encoding: .utf8)

        let provider = GitDiffProvider()
        let success = await provider.stageAll(at: tmpDir)
        #expect(success)

        await provider.refresh(at: tmpDir)
        #expect(!provider.stagedFiles.isEmpty)
        #expect(provider.unstagedFiles.isEmpty)
    }

    @Test func unstageAllWorksInRealRepo() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-git-unstageall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = GitStatusProvider.runGit(["init"], at: tmpDir)
        guard initResult.exitCode == 0 else { return }

        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)
        _ = GitStatusProvider.runGit(
            ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
            at: tmpDir
        )

        try "modified".write(to: testFile, atomically: true, encoding: .utf8)
        _ = GitStatusProvider.runGit(["add", "."], at: tmpDir)

        let provider = GitDiffProvider()
        let success = await provider.unstageAll(at: tmpDir)
        #expect(success)

        await provider.refresh(at: tmpDir)
        #expect(provider.stagedFiles.isEmpty)
        #expect(!provider.unstagedFiles.isEmpty)
    }

    // MARK: - parseUnifiedDiff — context line without leading space

    @Test func parsesContextLineWithoutLeadingSpace() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
        noSpaceLine
        +added
         normalContext
         another
        """
        let result = GitDiffProvider.parseUnifiedDiff(diff, isStaged: false)
        #expect(result.count == 1)
        let lines = result[0].hunks[0].lines
        // "noSpaceLine" has no prefix, treated as context
        #expect(lines[0].kind == .context)
        #expect(lines[0].text == "noSpaceLine")
    }
}
