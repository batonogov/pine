//
//  TabStripOverflowHostedTests.swift
//  PineTests
//
//  Hosted light/dark smoke coverage for overflowing editor and terminal strips.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Tab Strip Overflow Hosted Rendering")
@MainActor
struct TabStripOverflowHostedTests {
    private struct EditorHarness: View {
        let paneManager: PaneManager
        let paneID: PaneID
        let tabManager: TabManager
        var indicatorX: CGFloat = 164

        var body: some View {
            EditorTabBar(
                tabManager: tabManager,
                onCloseTab: { _ in },
                overridePaneID: paneID
            )
            .environment(paneManager)
            .overlay(alignment: .topLeading) {
                TabInsertionIndicator(x: indicatorX)
            }
        }
    }

    private struct TerminalHarness: View {
        let paneManager: PaneManager
        let projectRegistry: ProjectRegistry
        let paneID: PaneID
        let terminalState: TerminalPaneState

        var body: some View {
            TerminalPaneTabBar(
                paneID: paneID,
                terminalState: terminalState
            )
            .environment(paneManager)
            .environment(projectRegistry)
            .overlay(alignment: .topLeading) {
                TabInsertionIndicator(x: 164)
            }
        }
    }

    private static let renderSize = NSSize(width: 360, height: 30)
    // macOS 26 and 27 rasterize the terminal SF Symbol slightly differently.
    // Keep the hosted layout snapshot strict enough to catch structural drift
    // while allowing that bounded cross-OS glyph delta in the preview lane.
    private static let terminalCrossVersionTolerance = 0.02

    @Test("Overflowing editor strip snapshots pinned, preview, active, and indicator states")
    func editorOverflow() throws {
        let paneManager = PaneManager()
        let paneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: paneID))
        tabManager.tabs = (0..<8).map { index in
            EditorTab(
                url: URL(fileURLWithPath: "/project/file-\(index).swift"),
                content: "",
                savedContent: ""
            )
        }
        tabManager.tabs[0].isPinned = true
        tabManager.tabs[1].isTransientPreview = true
        tabManager.activeTabID = tabManager.tabs[3].id

        for appearance in [SnapshotAppearance.light, .dark] {
            try assertSnapshot(
                of: EditorHarness(
                    paneManager: paneManager,
                    paneID: paneID,
                    tabManager: tabManager
                ),
                size: Self.renderSize,
                appearance: appearance,
                named: "TabStrip.editorOverflow.\(appearance.suffix)"
            )
        }
    }

    @Test("Overflowing terminal strip snapshots active and indicator states")
    func terminalOverflow() throws {
        let paneManager = PaneManager()
        let projectRegistry = ProjectRegistry()
        let paneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let terminalState = try #require(paneManager.terminalState(for: paneID))
        terminalState.terminalTabs = (1...7).map { TerminalTab(name: "Terminal \($0)") }
        terminalState.activeTerminalID = terminalState.terminalTabs[3].id

        for appearance in [SnapshotAppearance.light, .dark] {
            try assertSnapshot(
                of: TerminalHarness(
                    paneManager: paneManager,
                    projectRegistry: projectRegistry,
                    paneID: paneID,
                    terminalState: terminalState
                ),
                size: Self.renderSize,
                appearance: appearance,
                named: "TabStrip.terminalOverflow.\(appearance.suffix)",
                tolerance: Self.terminalCrossVersionTolerance
            )
        }
    }

    @Test("Empty editor strip snapshots its sole insertion gap")
    func emptyEditorStrip() throws {
        let paneManager = PaneManager()
        let paneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: paneID))

        for appearance in [SnapshotAppearance.light, .dark] {
            try assertSnapshot(
                of: EditorHarness(
                    paneManager: paneManager,
                    paneID: paneID,
                    tabManager: tabManager,
                    indicatorX: 4
                ),
                size: Self.renderSize,
                appearance: appearance,
                named: "TabStrip.editorEmpty.\(appearance.suffix)"
            )
        }
    }
}
