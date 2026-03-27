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

    // MARK: - DiffLine equality

    @Test func diffLineEquality() {
        let line1 = DiffLine(kind: .added, text: "hello")
        let line2 = DiffLine(kind: .added, text: "hello")
        let line3 = DiffLine(kind: .removed, text: "hello")
        let line4 = DiffLine(kind: .added, text: "world")
        // Custom == compares kind + text, ignoring UUID id
        #expect(line1 == line2)
        #expect(line1 != line3)
        #expect(line1 != line4)
        // Different instances have different IDs for Identifiable
        #expect(line1.id != line2.id)
    }

    // MARK: - DiffLine Identifiable distinct IDs

    @Test func diffLineHasDistinctIDs() {
        let a = DiffLine(kind: .context, text: "same")
        let b = DiffLine(kind: .context, text: "same")
        #expect(a == b)
        #expect(a.id != b.id)
    }

    // MARK: - DiffHunk equality

    @Test func diffHunkEqualityByHeaderAndLines() {
        let hunk1 = DiffHunk(header: "@@ -1 +1 @@", lines: [])
        let hunk2 = DiffHunk(header: "@@ -1 +1 @@", lines: [])
        let hunk3 = DiffHunk(header: "@@ -2 +2 @@", lines: [])
        #expect(hunk1 == hunk2)
        #expect(hunk1 != hunk3)
    }

    // MARK: - FileDiff equality

    @Test func fileDiffEqualityByPathAndStaged() {
        let diff1 = FileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff2 = FileDiff(filePath: "a.swift", hunks: [], isStaged: true)
        let diff3 = FileDiff(filePath: "a.swift", hunks: [], isStaged: false)
        #expect(diff1 == diff2)
        #expect(diff1 != diff3)
    }
}
