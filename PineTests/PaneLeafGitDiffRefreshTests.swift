//
//  PaneLeafGitDiffRefreshTests.swift
//  PineTests
//
//  Regression coverage for issue #780 — gutter git diff markers stopped
//  updating after the split-panes refactor in PR #707 because the
//  `refreshLineDiffs` call was only wired to `onChange(activeTabID)`.
//  These tests verify the underlying signals that `PaneLeafView` now
//  subscribes to (content edits, git-status changes, branch switches,
//  repository transitions, initial load) actually fire and that
//  `GitStatusProvider.diffForFileAsync` returns the expected diffs
//  across the full save/edit/checkout lifecycle.
//

import Foundation
import Testing

@testable import Pine

@Suite("PaneLeaf Git Diff Refresh Signals (#780)")
@MainActor
struct PaneLeafGitDiffRefreshTests {

    // MARK: - Repo helpers

    private func makeGitRepo() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-paneleaf-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        try runShell("git init -b main", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)
        try "line1\nline2\nline3\n".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'initial'", at: dir)
        return dir
    }

    private func resolveURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    private func runShell(_ command: String, at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ShellError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - Signal 1: content edits (contentVersion increments)

    /// `PaneLeafView` now subscribes to `tabManager.activeTab?.contentVersion`.
    /// This test guards that the signal actually changes on every content edit,
    /// so the SwiftUI `.onChange` hook fires and `refreshLineDiffs` runs.
    @Test("EditorTab.contentVersion increments on every edit — drives onChange")
    func contentVersionIncrementsOnEdit() {
        let manager = TabManager()
        let url = URL(fileURLWithPath: "/tmp/pine-test-\(UUID().uuidString).txt")
        try? "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.openTab(url: url)
        guard let initialVersion = manager.activeTab?.contentVersion else {
            Issue.record("No active tab after openTab")
            return
        }

        manager.updateContent("hello world")
        let afterEdit1 = manager.activeTab?.contentVersion ?? 0
        #expect(afterEdit1 > initialVersion)

        manager.updateContent("hello world!")
        let afterEdit2 = manager.activeTab?.contentVersion ?? 0
        #expect(afterEdit2 > afterEdit1)
    }

    /// Edge case: the same content re-applied MUST still register as an edit
    /// (SwiftUI onChange semantics rely on Equatable; contentVersion bumps
    /// regardless of whether the new string equals the old one).
    @Test("contentVersion bumps even if new content equals old")
    func contentVersionBumpsOnNoOpEdit() {
        let manager = TabManager()
        let url = URL(fileURLWithPath: "/tmp/pine-test-\(UUID().uuidString).txt")
        try? "same".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        manager.openTab(url: url)
        let v0 = manager.activeTab?.contentVersion ?? 0
        manager.updateContent("same")
        let v1 = manager.activeTab?.contentVersion ?? 0
        #expect(v1 > v0, "contentVersion must bump on every updateContent call")
    }

    // MARK: - Signal 2: git state changes (fileStatuses, currentBranch, isGitRepository)

    @Test("GitStatusProvider.fileStatuses changes after a file is modified and refresh() runs")
    func fileStatusesChangesOnModifyAndRefresh() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)
        let initialStatuses = provider.fileStatuses
        #expect(initialStatuses.isEmpty, "clean repo should have no modified files")

        // Modify the tracked file
        try "line1\nLINE-TWO\nline3\n".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        provider.refresh()

        #expect(provider.fileStatuses.isEmpty == false, "modified file should appear in fileStatuses")
        #expect(initialStatuses != provider.fileStatuses,
                "fileStatuses must differ after modification — drives onChange subscription")
    }

    @Test("GitStatusProvider.isGitRepository transitions false→true on setup")
    func isGitRepositoryTransition() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        #expect(provider.isGitRepository == false)

        provider.setup(repositoryURL: dir)
        #expect(provider.isGitRepository == true,
                "isGitRepository must flip true — drives PaneLeafView initial diff load")
    }

    @Test("GitStatusProvider.currentBranch updates on branch checkout")
    func currentBranchUpdatesOnCheckout() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)
        let initialBranch = provider.currentBranch
        #expect(initialBranch.isEmpty == false)

        try runShell("git checkout -b feature", at: dir)
        provider.refresh()

        #expect(provider.currentBranch == "feature")
        #expect(provider.currentBranch != initialBranch,
                "currentBranch must change — drives branch-switch onChange subscription")
    }

    // MARK: - Signal 3: data pipeline behind the subscription

    /// Verifies `diffForFileAsync` returns diffs for an edited tracked file.
    /// This is the exact method `PaneLeafView.refreshLineDiffs` calls when
    /// subscriptions fire.
    @Test("diffForFileAsync returns diffs for edited tracked file")
    func diffForFileAsyncReturnsDiffsAfterEdit() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let fileURL = dir.appendingPathComponent("file.txt")

        // Pre-edit: no diffs
        let before = await provider.diffForFileAsync(at: fileURL)
        #expect(before.isEmpty, "unmodified file should report no diffs")

        // Modify the file on disk (simulates save)
        try "line1\nMODIFIED\nline3\nline4-added\n".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )

        let after = await provider.diffForFileAsync(at: fileURL)
        #expect(after.isEmpty == false, "modified file should report diffs")
    }

    /// Edge case: diffForFileAsync on a non-git directory returns empty.
    @Test("diffForFileAsync returns empty for non-git workspace")
    func diffForFileAsyncEmptyForNonGit() async throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        try "hello\n".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = await provider.diffForFileAsync(at: dir.appendingPathComponent("file.txt"))
        #expect(diffs.isEmpty)
    }

    // MARK: - Signal 4: split-pane scenario — two panes, independent refresh

    /// Verifies that in a split-pane layout each pane's own `TabManager`
    /// exposes its own `activeTab?.contentVersion`, so subscriptions in each
    /// `PaneLeafView` are independent and do not interfere.
    @Test("split panes have independent contentVersion streams per TabManager")
    func splitPanesIndependentContentVersion() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let urlA = URL(fileURLWithPath: "/tmp/pine-split-a-\(UUID().uuidString).txt")
        let urlB = URL(fileURLWithPath: "/tmp/pine-split-b-\(UUID().uuidString).txt")
        try? "A".write(to: urlA, atomically: true, encoding: .utf8)
        try? "B".write(to: urlB, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        manager.tabManager(for: firstPane)?.openTab(url: urlA)
        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        manager.tabManager(for: secondPane)?.openTab(url: urlB)

        guard let tmA = manager.tabManager(for: firstPane),
              let tmB = manager.tabManager(for: secondPane) else {
            Issue.record("TabManagers missing after split")
            return
        }

        let v0A = tmA.activeTab?.contentVersion ?? 0
        let v0B = tmB.activeTab?.contentVersion ?? 0

        // Edit only pane A
        tmA.updateContent("A edited")

        let v1A = tmA.activeTab?.contentVersion ?? 0
        let v1B = tmB.activeTab?.contentVersion ?? 0

        #expect(v1A > v0A, "pane A contentVersion must bump")
        #expect(v1B == v0B, "pane B contentVersion must NOT bump — independent subscriptions")
    }

    // MARK: - Signal 5: integration — full save flow updates diffs

    /// End-to-end: simulates the user editing a file in an editor tab,
    /// saving it, and verifies `diffForFileAsync` (the method called by
    /// the subscription handler) reflects the modification. This is the
    /// exact flow that issue #780 reported as broken.
    @Test("full edit → save → refresh → diffForFileAsync flow")
    func fullEditSaveRefreshFlow() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("file.txt")
        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Open the file in a TabManager
        let tabManager = TabManager()
        tabManager.openTab(url: fileURL)
        #expect(tabManager.activeTab != nil)

        // Edit in memory
        tabManager.updateContent("line1\nEDITED\nline3\n")
        #expect(tabManager.activeTab?.isDirty == true)

        // Save to disk
        let saved = tabManager.saveTab(at: 0)
        #expect(saved == true)
        #expect(tabManager.activeTab?.isDirty == false)

        // Refresh git state (what the fileStatuses onChange subscription triggers)
        provider.refresh()
        #expect(provider.fileStatuses.isEmpty == false,
                "after save, fileStatuses should show the modified file")

        // Fetch diffs — what refreshLineDiffs() ultimately does
        let diffs = await provider.diffForFileAsync(at: fileURL)
        #expect(diffs.isEmpty == false,
                "after save, diffForFileAsync must return diffs — the bug in #780 was that this was never called")
    }
}
