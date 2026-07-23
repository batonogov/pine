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

        var body: some View {
            EditorTabBar(
                tabManager: tabManager,
                onCloseTab: { _ in },
                overridePaneID: paneID
            )
            .environment(paneManager)
            .overlay(alignment: .topLeading) {
                TabInsertionIndicator(x: 164)
            }
        }
    }

    private struct TerminalHarness: View {
        let paneManager: PaneManager
        let paneID: PaneID
        let terminalState: TerminalPaneState

        var body: some View {
            TerminalPaneTabBar(
                paneID: paneID,
                terminalState: terminalState
            )
            .environment(paneManager)
            .overlay(alignment: .topLeading) {
                TabInsertionIndicator(x: 164)
            }
        }
    }

    private static let renderSize = NSSize(width: 360, height: 30)

    @Test("Overflowing editor strip hosts in light and dark appearances")
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
        tabManager.activeTabID = tabManager.tabs[3].id

        for appearance in [SnapshotAppearance.light, .dark] {
            try assertHostedRender(
                EditorHarness(
                    paneManager: paneManager,
                    paneID: paneID,
                    tabManager: tabManager
                ),
                appearance: appearance
            )
        }
    }

    @Test("Overflowing terminal strip hosts in light and dark appearances")
    func terminalOverflow() throws {
        let paneManager = PaneManager()
        let paneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let terminalState = try #require(paneManager.terminalState(for: paneID))
        for _ in 0..<7 {
            terminalState.addTab(workingDirectory: nil)
        }
        terminalState.activeTerminalID = terminalState.terminalTabs[3].id

        for appearance in [SnapshotAppearance.light, .dark] {
            try assertHostedRender(
                TerminalHarness(
                    paneManager: paneManager,
                    paneID: paneID,
                    terminalState: terminalState
                ),
                appearance: appearance
            )
        }
    }

    private func assertHostedRender<Content: View>(
        _ view: Content,
        appearance: SnapshotAppearance
    ) throws {
        guard !SnapshotHarness.isHeadless else { return }
        let bitmap = try SnapshotHarness.render(
            view: view,
            size: Self.renderSize,
            appearance: appearance
        )
        #expect(bitmap.pixelsWide == Int(Self.renderSize.width))
        #expect(bitmap.pixelsHigh == Int(Self.renderSize.height))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 500)
    }
}
