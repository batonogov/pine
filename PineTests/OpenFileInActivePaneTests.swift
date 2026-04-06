//
//  OpenFileInActivePaneTests.swift
//  PineTests
//
//  Tests for ProjectManager.openFileInActivePane(url:) — verifies that
//  files opened from sidebar / quick open / search results land in the
//  currently focused pane, not the primary tabManager. Regression for #695.
//

import Foundation
import Testing

@testable import Pine

@Suite("Open File In Active Pane")
@MainActor
struct OpenFileInActivePaneTests {

    private func tmpFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? "// \(name)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Single pane: opens in primary

    @Test func openFile_singlePane_opensInPrimary() {
        let pm = ProjectManager()
        let url = tmpFile("a.swift")

        pm.openFileInActivePane(url: url)

        #expect(pm.tabManager.tabs.contains { $0.url == url })
        #expect(pm.activeTabManager.activeTab?.url == url)
    }

    // MARK: - Two panes: opens in active (second) pane, NOT primary

    @Test func openFile_twoPanes_opensInActivePane() {
        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID
        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed"); return
        }
        // After split, active pane is the new (second) pane.
        #expect(pm.paneManager.activePaneID == secondPaneID)

        let url = tmpFile("b.swift")
        pm.openFileInActivePane(url: url)

        let secondTM = pm.paneManager.tabManager(for: secondPaneID)
        #expect(secondTM?.tabs.contains { $0.url == url } == true)
        // Primary (first) pane must NOT receive the tab
        #expect(pm.tabManager.tabs.contains { $0.url == url } == false)
    }

    // MARK: - Switching active pane back to first opens there

    @Test func openFile_afterRefocusFirstPane_opensInFirst() {
        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID
        guard let secondPaneID = pm.paneManager.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed"); return
        }
        pm.paneManager.activePaneID = firstPaneID

        let url = tmpFile("c.swift")
        pm.openFileInActivePane(url: url)

        #expect(pm.tabManager.tabs.contains { $0.url == url })
        #expect(pm.paneManager.tabManager(for: secondPaneID)?.tabs.contains { $0.url == url } == false)
    }

    // MARK: - Active pane is terminal: falls back to nearest editor pane

    @Test func openFile_terminalPaneActive_fallsBackToEditorPane() {
        let pm = ProjectManager()
        let firstPaneID = pm.paneManager.activePaneID

        // Create a terminal pane and make it active.
        pm.terminal.createTerminalTab(relativeTo: firstPaneID, workingDirectory: nil)

        // Open a file — must land in an editor pane (not crash, not lost).
        let url = tmpFile("d.swift")
        pm.openFileInActivePane(url: url)

        // Some editor TabManager somewhere has the tab.
        let total = pm.allTabs.filter { $0.url == url }.count
        #expect(total >= 1)
    }

    // MARK: - Open same file twice: no duplicate in active pane

    @Test func openFile_twiceInSameActivePane_noDuplicate() {
        let pm = ProjectManager()
        let url = tmpFile("e.swift")

        pm.openFileInActivePane(url: url)
        pm.openFileInActivePane(url: url)

        let count = pm.activeTabManager.tabs.filter { $0.url == url }.count
        #expect(count == 1)
    }
}
