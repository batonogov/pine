//
//  GitChangesViewTests.swift
//  PineTests
//
//  Tests for GitChangesView model states and rendering logic.
//

import Foundation
import Testing
@testable import Pine

struct GitChangesViewTests {

    // MARK: - GitDiffLine prefix/color logic (extracted from GitDiffLineView)

    @Test func diffLineAddedProperties() {
        let line = GitDiffLine(kind: .added, text: "new line")
        #expect(line.kind == .added)
        #expect(line.text == "new line")
    }

    @Test func diffLineRemovedProperties() {
        let line = GitDiffLine(kind: .removed, text: "old line")
        #expect(line.kind == .removed)
        #expect(line.text == "old line")
    }

    @Test func diffLineContextProperties() {
        let line = GitDiffLine(kind: .context, text: "unchanged")
        #expect(line.kind == .context)
        #expect(line.text == "unchanged")
    }

    @Test func diffLineHunkHeaderProperties() {
        let line = GitDiffLine(kind: .hunkHeader, text: "@@ -1,3 +1,4 @@")
        #expect(line.kind == .hunkHeader)
        #expect(line.text == "@@ -1,3 +1,4 @@")
    }

    // MARK: - Change count badge logic

    @Test func changeCountBadgeCountsAddedLines() {
        let hunks = [
            GitDiffHunk(header: "@@ -1 +1 @@", lines: [
                GitDiffLine(kind: .added, text: "a"),
                GitDiffLine(kind: .added, text: "b"),
                GitDiffLine(kind: .context, text: "c"),
                GitDiffLine(kind: .removed, text: "d")
            ])
        ]
        let file = GitFileDiff(filePath: "test.swift", hunks: hunks, isStaged: false)
        let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
        let removed = file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
        #expect(added == 2)
        #expect(removed == 1)
    }

    @Test func changeCountBadgeWithNoChanges() {
        let hunks = [
            GitDiffHunk(header: "@@ -1 +1 @@", lines: [
                GitDiffLine(kind: .context, text: "unchanged")
            ])
        ]
        let file = GitFileDiff(filePath: "test.swift", hunks: hunks, isStaged: false)
        let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
        let removed = file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
        #expect(added == 0)
        #expect(removed == 0)
    }

    @Test func changeCountBadgeAcrossMultipleHunks() {
        let hunks = [
            GitDiffHunk(header: "@@ -1 +1 @@", lines: [
                GitDiffLine(kind: .added, text: "a")
            ]),
            GitDiffHunk(header: "@@ -10 +10 @@", lines: [
                GitDiffLine(kind: .added, text: "b"),
                GitDiffLine(kind: .removed, text: "c"),
                GitDiffLine(kind: .removed, text: "d")
            ])
        ]
        let file = GitFileDiff(filePath: "test.swift", hunks: hunks, isStaged: false)
        let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
        let removed = file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count
        #expect(added == 2)
        #expect(removed == 2)
    }

    // MARK: - File row filename extraction

    @Test func fileRowExtractsLastPathComponent() {
        let filePath = "Pine/Views/Editor/CodeView.swift"
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        #expect(name == "CodeView.swift")
    }

    @Test func fileRowExtractsSimpleFilename() {
        let filePath = "README.md"
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        #expect(name == "README.md")
    }

    @Test func fileRowHandlesEmptyPath() {
        let filePath = ""
        let url = URL(fileURLWithPath: filePath)
        // URL(fileURLWithPath: "") produces current directory
        #expect(!url.lastPathComponent.isEmpty)
    }

    // MARK: - GitDiffProvider state for view rendering

    @Test func emptyProviderShowsEmptyState() {
        let provider = GitDiffProvider()
        let isEmpty = provider.stagedFiles.isEmpty && provider.unstagedFiles.isEmpty
        #expect(isEmpty)
        #expect(!provider.isRefreshing)
    }

    @Test func providerWithStagedFilesShowsStagedSection() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        provider.stagedFiles = [GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: true)]
        #expect(!provider.stagedFiles.isEmpty)
        #expect(provider.unstagedFiles.isEmpty)
    }

    @Test func providerWithUnstagedFilesShowsUnstagedSection() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .removed, text: "x")])
        provider.unstagedFiles = [GitFileDiff(filePath: "b.swift", hunks: [hunk], isStaged: false)]
        #expect(provider.stagedFiles.isEmpty)
        #expect(!provider.unstagedFiles.isEmpty)
    }

    @Test func providerWithBothSectionsShowsBoth() {
        let provider = GitDiffProvider()
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        provider.stagedFiles = [GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: true)]
        provider.unstagedFiles = [GitFileDiff(filePath: "b.swift", hunks: [hunk], isStaged: false)]
        #expect(!provider.stagedFiles.isEmpty)
        #expect(!provider.unstagedFiles.isEmpty)
    }

    @Test func refreshingProviderShowsProgress() {
        let provider = GitDiffProvider()
        provider.isRefreshing = true
        #expect(provider.isRefreshing)
    }

    // MARK: - Section file count for badge display

    @Test func sectionFileCountMatchesFilesArray() {
        let hunk = GitDiffHunk(header: "@@ -1 +1 @@", lines: [GitDiffLine(kind: .added, text: "x")])
        let files = [
            GitFileDiff(filePath: "a.swift", hunks: [hunk], isStaged: false),
            GitFileDiff(filePath: "b.swift", hunks: [hunk], isStaged: false),
            GitFileDiff(filePath: "c.swift", hunks: [hunk], isStaged: false)
        ]
        #expect(files.count == 3)
    }

    // MARK: - Accessibility identifier

    @Test func gitChangesPanelAccessibilityID() {
        #expect(AccessibilityID.gitChangesPanel == "gitChangesPanel")
    }
}
