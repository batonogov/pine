//
//  GitStatusProviderEdgeTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("GitStatusProvider Edge Case Tests")
@MainActor
struct GitStatusProviderEdgeTests {

    // MARK: - unquoteGitPath

    @Test func unquoteGitPath_plainPath() {
        let result = GitStatusProvider.unquoteGitPath("simple/path.txt")
        #expect(result == "simple/path.txt")
    }

    @Test func unquoteGitPath_quotedPathWithSpaces() {
        let result = GitStatusProvider.unquoteGitPath("\"examples copy/file.txt\"")
        #expect(result == "examples copy/file.txt")
    }

    @Test func unquoteGitPath_escapedBackslash() {
        let result = GitStatusProvider.unquoteGitPath("\"path\\\\file.txt\"")
        #expect(result == "path\\file.txt")
    }

    @Test func unquoteGitPath_escapedQuote() {
        let result = GitStatusProvider.unquoteGitPath("\"he said \\\"hi\\\"\"")
        #expect(result == "he said \"hi\"")
    }

    @Test func unquoteGitPath_escapedNewline() {
        let result = GitStatusProvider.unquoteGitPath("\"line1\\nline2\"")
        #expect(result == "line1\nline2")
    }

    @Test func unquoteGitPath_escapedTab() {
        let result = GitStatusProvider.unquoteGitPath("\"col1\\tcol2\"")
        #expect(result == "col1\tcol2")
    }

    @Test func unquoteGitPath_octalEscape() {
        // \320\241 = Cyrillic С (U+0421)
        let result = GitStatusProvider.unquoteGitPath("\"\\320\\241\"")
        #expect(result == "С")
    }

    @Test func unquoteGitPath_emptyString() {
        let result = GitStatusProvider.unquoteGitPath("")
        #expect(result == "")
    }

    @Test func unquoteGitPath_singleQuoteNotTreated() {
        // Single char is less than 2 chars for quoted check
        let result = GitStatusProvider.unquoteGitPath("\"")
        #expect(result == "\"")
    }

    @Test func unquoteGitPath_emptyQuotedString() {
        let result = GitStatusProvider.unquoteGitPath("\"\"")
        #expect(result == "")
    }

    @Test func unquoteGitPath_escapedBell() {
        let result = GitStatusProvider.unquoteGitPath("\"\\a\"")
        #expect(result == "\u{07}")
    }

    @Test func unquoteGitPath_escapedBackspace() {
        let result = GitStatusProvider.unquoteGitPath("\"\\b\"")
        #expect(result == "\u{08}")
    }

    @Test func unquoteGitPath_escapedFormFeed() {
        let result = GitStatusProvider.unquoteGitPath("\"\\f\"")
        #expect(result == "\u{0C}")
    }

    @Test func unquoteGitPath_escapedCarriageReturn() {
        let result = GitStatusProvider.unquoteGitPath("\"\\r\"")
        #expect(result == "\r")
    }

    @Test func unquoteGitPath_escapedVerticalTab() {
        let result = GitStatusProvider.unquoteGitPath("\"\\v\"")
        #expect(result == "\u{0B}")
    }

    @Test func unquoteGitPath_unknownEscapePreservesBackslash() {
        let result = GitStatusProvider.unquoteGitPath("\"\\z\"")
        #expect(result == "\\z")
    }

    @Test func unquoteGitPath_trailingBackslash() {
        let result = GitStatusProvider.unquoteGitPath("\"foo\\\"")
        #expect(result == "foo\\")
    }

    // MARK: - parseStatusOutput

    @Test func parseStatusOutput_untrackedFile() {
        let output = "?? newfile.txt\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["newfile.txt"] == .untracked)
    }

    @Test func parseStatusOutput_modifiedFile() {
        let output = " M modified.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["modified.swift"] == .modified)
    }

    @Test func parseStatusOutput_stagedFile() {
        let output = "M  staged.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["staged.swift"] == .staged)
    }

    @Test func parseStatusOutput_addedFile() {
        let output = "A  added.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["added.swift"] == .added)
    }

    @Test func parseStatusOutput_deletedFile() {
        let output = "D  deleted.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["deleted.swift"] == .deleted)
    }

    @Test func parseStatusOutput_conflictUU() {
        let output = "UU conflict.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["conflict.swift"] == .conflict)
    }

    @Test func parseStatusOutput_conflictAA() {
        let output = "AA both-added.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["both-added.swift"] == .conflict)
    }

    @Test func parseStatusOutput_conflictDD() {
        let output = "DD both-deleted.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["both-deleted.swift"] == .conflict)
    }

    @Test func parseStatusOutput_mixedFile() {
        let output = "MM mixed.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["mixed.swift"] == .mixed)
    }

    @Test func parseStatusOutput_renamedFile() {
        let output = "R  old.swift -> new.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["new.swift"] == .staged)
    }

    @Test func parseStatusOutput_ignoredFileSkipped() {
        let output = "!! ignored_dir/\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses.isEmpty)
    }

    @Test func parseStatusOutput_shortLineIgnored() {
        let output = "X\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses.isEmpty)
    }

    @Test func parseStatusOutput_emptyOutput() {
        let statuses = GitStatusProvider.parseStatusOutput("")
        #expect(statuses.isEmpty)
    }

    @Test func parseStatusOutput_workTreeDeleted() {
        let output = " D deleted-worktree.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["deleted-worktree.swift"] == .deleted)
    }

    // MARK: - parseIgnoredOutput

    @Test func parseIgnoredOutput_directoryIgnored() {
        let output = "!! build/\n!! node_modules/\n"
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.contains("build"))
        #expect(ignored.contains("node_modules"))
    }

    @Test func parseIgnoredOutput_fileIgnored() {
        let output = "!! secret.env\n"
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.contains("secret.env"))
    }

    @Test func parseIgnoredOutput_nonIgnoredLinesSkipped() {
        let output = " M modified.swift\n!! ignored/\n?? new.txt\n"
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.count == 1)
        #expect(ignored.contains("ignored"))
    }

    @Test func parseIgnoredOutput_emptyOutput() {
        let ignored = GitStatusProvider.parseIgnoredOutput("")
        #expect(ignored.isEmpty)
    }

    // MARK: - parseHunkNewStart

    @Test func parseHunkNewStart_simpleHunk() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -1,3 +5,7 @@")
        #expect(result == 5)
    }

    @Test func parseHunkNewStart_noCountHunk() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -1 +3 @@")
        #expect(result == 3)
    }

    @Test func parseHunkNewStart_invalidHeader() {
        let result = GitStatusProvider.parseHunkNewStart("not a hunk")
        #expect(result == nil)
    }

    @Test func parseHunkNewStart_noPlus() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -1,3 @@")
        #expect(result == nil)
    }

    // MARK: - parseDiff

    @Test func parseDiff_addedLines() {
        let diff = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,5 @@
         context
        +added line 1
        +added line 2
         more context
        """
        let diffs = GitStatusProvider.parseDiff(diff)
        let added = diffs.filter { $0.kind == .added }
        #expect(added.count == 2)
    }

    @Test func parseDiff_deletedLines() {
        let diff = """
        @@ -1,3 +1,1 @@
        -deleted line 1
        -deleted line 2
         context
        """
        let diffs = GitStatusProvider.parseDiff(diff)
        let deleted = diffs.filter { $0.kind == .deleted }
        #expect(deleted.count == 1) // One delete marker
    }

    @Test func parseDiff_modifiedLines() {
        let diff = """
        @@ -1,1 +1,1 @@
        -old line
        +new line
        """
        let diffs = GitStatusProvider.parseDiff(diff)
        let modified = diffs.filter { $0.kind == .modified }
        #expect(modified.count == 1)
    }

    @Test func parseDiff_emptyOutput() {
        let diffs = GitStatusProvider.parseDiff("")
        #expect(diffs.isEmpty)
    }

    // MARK: - parseBlame

    @Test func parseBlame_emptyOutput() {
        let result = GitStatusProvider.parseBlame("")
        #expect(result.isEmpty)
    }

    @Test func parseBlame_singleLine() {
        let hash = String(repeating: "a", count: 40)
        let output = """
        \(hash) 1 1 1
        author Test User
        author-time 1700000000
        summary Initial commit
        \tline content
        """
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
        #expect(result[0].hash == hash)
        #expect(result[0].author == "Test User")
        #expect(result[0].summary == "Initial commit")
        #expect(result[0].finalLine == 1)
    }

    @Test func parseBlame_multipleLines_cachedCommit() {
        let hash = String(repeating: "b", count: 40)
        let output = """
        \(hash) 1 1 2
        author Author Name
        author-time 1700000000
        summary Some message
        \tline 1
        \(hash) 1 2
        \tline 2
        """
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 2)
        #expect(result[0].author == "Author Name")
        #expect(result[1].author == "Author Name") // Cached
        #expect(result[1].finalLine == 2)
    }

    @Test func parseBlame_invalidHashSkipped() {
        let output = "invalid line that is not a hash\n\tanother line\n"
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.isEmpty)
    }

    // MARK: - GitLineDiff navigation

    @Test func changeRegionStarts_emptyDiffs() {
        let starts = GitLineDiff.changeRegionStarts([])
        #expect(starts.isEmpty)
    }

    @Test func changeRegionStarts_singleDiff() {
        let diffs = [GitLineDiff(line: 5, kind: .added)]
        let starts = GitLineDiff.changeRegionStarts(diffs)
        #expect(starts == [5])
    }

    @Test func changeRegionStarts_contiguousRegion() {
        let diffs = [
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 4, kind: .modified),
            GitLineDiff(line: 5, kind: .modified)
        ]
        let starts = GitLineDiff.changeRegionStarts(diffs)
        #expect(starts == [3])
    }

    @Test func changeRegionStarts_multipleRegions() {
        let diffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 2, kind: .added),
            GitLineDiff(line: 10, kind: .modified),
            GitLineDiff(line: 20, kind: .deleted)
        ]
        let starts = GitLineDiff.changeRegionStarts(diffs)
        #expect(starts == [1, 10, 20])
    }

    @Test func nextChangeLine_wrapsAround() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 15, kind: .modified)
        ]
        // From line 20 (after all), wraps to first
        let next = GitLineDiff.nextChangeLine(from: 20, in: diffs)
        #expect(next == 5)
    }

    @Test func nextChangeLine_fromInsideRegion() {
        let diffs = [
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 4, kind: .modified),
            GitLineDiff(line: 10, kind: .added)
        ]
        let next = GitLineDiff.nextChangeLine(from: 3, in: diffs)
        #expect(next == 10)
    }

    @Test func nextChangeLine_emptyDiffs() {
        let next = GitLineDiff.nextChangeLine(from: 1, in: [])
        #expect(next == nil)
    }

    @Test func previousChangeLine_wrapsAround() {
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 15, kind: .modified)
        ]
        // From line 1 (before all), wraps to last
        let prev = GitLineDiff.previousChangeLine(from: 1, in: diffs)
        #expect(prev == 15)
    }

    @Test func previousChangeLine_emptyDiffs() {
        let prev = GitLineDiff.previousChangeLine(from: 1, in: [])
        #expect(prev == nil)
    }

    @Test func previousChangeLine_fromInsideRegion() {
        let diffs = [
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 10, kind: .added),
            GitLineDiff(line: 11, kind: .added)
        ]
        let prev = GitLineDiff.previousChangeLine(from: 10, in: diffs)
        #expect(prev == 3)
    }

    // MARK: - GitFileStatus color coverage

    @Test func gitFileStatus_allHaveColor() {
        let statuses: [GitFileStatus] = [.untracked, .modified, .staged, .added, .deleted, .conflict, .mixed]
        for status in statuses {
            // Just verify we can get a color without crashing
            _ = status.color
        }
    }

    // MARK: - GitStatusProvider observable state

    @Test func applyEmptyState_clearsAll() {
        let provider = GitStatusProvider()
        provider.currentBranch = "main"
        provider.fileStatuses = ["a.swift": .modified]
        provider.isGitRepository = true

        provider.applyEmptyState()

        #expect(provider.currentBranch == "")
        #expect(provider.fileStatuses.isEmpty)
        #expect(provider.isGitRepository == false)
        #expect(provider.branches.isEmpty)
    }

    @Test func applyFetched_setsAll() {
        let provider = GitStatusProvider()
        provider.applyFetched(
            branch: "develop",
            statuses: ["f.swift": .staged],
            ignored: ["build"],
            branches: ["main", "develop"],
            isRepository: true
        )
        #expect(provider.currentBranch == "develop")
        #expect(provider.fileStatuses["f.swift"] == .staged)
        #expect(provider.ignoredPaths.contains("build"))
        #expect(provider.branches == ["main", "develop"])
        #expect(provider.isGitRepository)
    }

    @Test func applyFetched_equalValues_noObservableUpdate() {
        let provider = GitStatusProvider()
        provider.applyFetched(
            branch: "main",
            statuses: ["a.swift": .modified],
            ignored: [],
            branches: ["main"],
            isRepository: true
        )
        let count1 = provider.observableUpdateCount

        // Apply same values again
        provider.applyFetched(
            branch: "main",
            statuses: ["a.swift": .modified],
            ignored: [],
            branches: ["main"],
            isRepository: true
        )
        let count2 = provider.observableUpdateCount
        #expect(count2 == count1)
    }

    @Test func hasUncommittedChanges_trueWhenStatusesExist() {
        let provider = GitStatusProvider()
        provider.applyFetched(
            branch: "main",
            statuses: ["file.swift": .untracked],
            ignored: [],
            branches: [],
            isRepository: true
        )
        #expect(provider.hasUncommittedChanges)
    }

    @Test func hasUncommittedChanges_falseWhenEmpty() {
        let provider = GitStatusProvider()
        provider.applyFetched(
            branch: "main",
            statuses: [:],
            ignored: [],
            branches: [],
            isRepository: true
        )
        #expect(!provider.hasUncommittedChanges)
    }
}
