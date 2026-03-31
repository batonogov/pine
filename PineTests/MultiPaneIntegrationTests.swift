//
//  MultiPaneIntegrationTests.swift
//  PineTests
//
//  Tests for multi-pane tab management: activeTabManager, allTabs,
//  dirty tracking across panes, save-all, session persistence,
//  and safe moveTab ordering.
//

import Foundation
import Testing

@testable import Pine

@Suite("Multi-Pane Integration Tests")
@MainActor
struct MultiPaneIntegrationTests {

    // MARK: - Helpers

    private func makeTempProject() throws -> (dir: URL, files: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = dir.appendingPathComponent("b.swift")
        let file3 = dir.appendingPathComponent("c.swift")
        for file in [file1, file2, file3] {
            try "// \(file.lastPathComponent)".write(to: file, atomically: true, encoding: .utf8)
        }
        return (dir, [file1, file2, file3])
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - activeTabManager tracks focus

    @Test func activeTabManager_singlePane_returnsPrimaryTabManager() {
        let pm = ProjectManager()
        #expect(pm.activeTabManager === pm.tabManager)
    }

    @Test func activeTabManager_switchesBetweenPanes() {
        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID
        let firstTM = pm.paneManager.tabManager(for: firstPaneID)

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let secondTM = pm.paneManager.tabManager(for: secondPaneID)

        // Active should be second pane after split
        #expect(pm.activeTabManager === secondTM)

        // Switch focus back to first
        pm.paneManager.activePaneID = firstPaneID
        #expect(pm.activeTabManager === firstTM)
    }

    // MARK: - allTabs collects from all panes

    @Test func allTabs_collectsFromAllPanes() {
        let pm = ProjectManager()
        let url1 = URL(fileURLWithPath: "/tmp/test-all-tabs-1.swift")
        let url2 = URL(fileURLWithPath: "/tmp/test-all-tabs-2.swift")

        let firstPaneID = pm.paneManager.activePaneID
        pm.tabManager.openTab(url: url1)

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        pm.paneManager.tabManager(for: secondPaneID)?.openTab(url: url2)

        let allURLs = pm.allTabs.map(\.url)
        #expect(allURLs.contains(url1))
        #expect(allURLs.contains(url2))
        #expect(pm.allTabs.count == 2)
    }

    // MARK: - hasUnsavedChanges across panes

    @Test func hasUnsavedChanges_detectsDirtyInSecondPane() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID
        pm.tabManager.openTab(url: files[0])

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        guard let secondTM = pm.paneManager.tabManager(for: secondPaneID) else {
            Issue.record("tabManager not found for second pane")
            return
        }
        secondTM.openTab(url: files[1])
        secondTM.updateContent("modified content")

        #expect(pm.hasUnsavedChanges == true)
        #expect(pm.allDirtyTabs.count == 1)
        #expect(pm.allDirtyTabs.first?.url == files[1])
    }

    @Test func hasUnsavedChanges_falseWhenAllClean() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.tabManager.openTab(url: files[0])

        #expect(pm.hasUnsavedChanges == false)
        #expect(pm.allDirtyTabs.isEmpty)
    }

    // MARK: - saveAllPaneTabs

    @Test func saveAllPaneTabs_savesAcrossPanes() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID
        pm.tabManager.openTab(url: files[0])
        pm.tabManager.updateContent("// modified a.swift")

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        guard let secondTM = pm.paneManager.tabManager(for: secondPaneID) else {
            Issue.record("tabManager not found for second pane")
            return
        }
        secondTM.openTab(url: files[1])
        secondTM.updateContent("// modified b.swift")

        #expect(pm.hasUnsavedChanges == true)

        let result = pm.saveAllPaneTabs()
        #expect(result == true)
        #expect(pm.hasUnsavedChanges == false)

        // Verify files were written
        let contentA = try String(contentsOf: files[0], encoding: .utf8)
        let contentB = try String(contentsOf: files[1], encoding: .utf8)
        #expect(contentA == "// modified a.swift")
        #expect(contentB == "// modified b.swift")
    }

    // MARK: - Session persistence collects all pane tabs

    @Test func saveSession_includesTabsFromAllPanes() throws {
        let (dir, files) = try makeTempProject()
        defer {
            cleanup(dir)
            SessionState.clear(for: dir)
        }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        let firstPaneID = pm.paneManager.activePaneID
        pm.tabManager.openTab(url: files[0])

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        pm.paneManager.tabManager(for: secondPaneID)?.openTab(url: files[1])
        pm.paneManager.tabManager(for: secondPaneID)?.openTab(url: files[2])

        pm.saveSession()

        let session = SessionState.load(for: dir)
        #expect(session != nil)
        let savedPaths = session?.openFilePaths ?? []
        #expect(savedPaths.count == 3)
        #expect(savedPaths.contains(files[0].path))
        #expect(savedPaths.contains(files[1].path))
        #expect(savedPaths.contains(files[2].path))
    }

    // MARK: - moveTab safe ordering (add first, then remove)

    @Test func moveTab_addsToDestBeforeRemovingFromSource() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        let url = URL(fileURLWithPath: "/tmp/safe-move.swift")
        manager.tabManager(for: firstPane)?.openTab(url: url)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.moveTabBetweenPanes(tabURL: url, from: firstPane, to: secondPane)

        // Tab must exist in destination
        let destTabs = manager.tabManager(for: secondPane)?.tabs ?? []
        #expect(destTabs.contains(where: { $0.url == url }))

        // Source pane was cleaned up (empty → removed)
        // Since the only tab was moved, first pane should be removed
        #expect(manager.tabManagers[firstPane] == nil)
    }

    // MARK: - allTabManagers

    @Test func allTabManagers_returnsAllPaneTabManagers() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        #expect(manager.allTabManagers.count == 1)

        _ = manager.splitPane(firstPane, axis: .horizontal)
        #expect(manager.allTabManagers.count == 2)
    }

    // MARK: - activeTabManager after pane removal

    @Test func activeTabManager_afterRemoval_switchesToRemaining() {
        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID

        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        // Active is second pane
        #expect(pm.paneManager.activePaneID == secondPaneID)

        pm.paneManager.removePane(secondPaneID)

        // Should fall back to first pane
        #expect(pm.activeTabManager === pm.tabManager)
    }
}
