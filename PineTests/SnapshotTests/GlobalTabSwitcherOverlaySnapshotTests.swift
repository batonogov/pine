//
//  GlobalTabSwitcherOverlaySnapshotTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Global Tab Switcher Overlay Snapshots")
@MainActor
struct GlobalTabSwitcherOverlaySnapshotTests {
    /// The overlay uses system materials, symbols, and text whose rasterization
    /// differs by about 3.4% between macOS 26 CI and the macOS 27 reference
    /// host. Keep that bounded cross-version allowance scoped to this view so
    /// the shared snapshot harness and unrelated snapshots remain strict.
    private static let crossVersionTolerance = 0.04

    private struct Harness: View {
        let projectManager: ProjectManager

        var body: some View {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                GlobalTabSwitcherOverlay(announce: { _ in })
                    .environment(projectManager.paneManager)
                    .environment(projectManager.workspace)
            }
            .environment(\.locale, Locale(identifier: "en"))
        }
    }

    private func makeProjectManager() throws -> ProjectManager {
        let projectManager = ProjectManager()
        let paneManager = projectManager.paneManager
        let paneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: paneID))
        let rootURL = URL(fileURLWithPath: "/tmp/Pine Demo")
        projectManager.workspace.rootURL = rootURL

        let files = [
            "Sources/App/main.swift",
            "Tests/App/main.swift",
            "README.md"
        ]
        for path in files {
            let tab = EditorTab(
                url: rootURL.appendingPathComponent(path),
                content: "",
                savedContent: ""
            )
            tabManager.tabs.append(tab)
            paneManager.selectEditorTab(tab.id, in: paneID)
        }

        let terminalPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: rootURL.appendingPathComponent("Sources")
        )
        let terminalState = try #require(
            paneManager.terminalState(for: terminalPane)
        )
        terminalState.activeTab?.name = "main.swift"

        #expect(
            paneManager.beginGlobalTabSwitcherSession(initialOffset: 2)
        )
        return projectManager
    }

    @Test("Overlay renders in light appearance")
    func light() throws {
        try assertSnapshot(
            of: Harness(projectManager: try makeProjectManager()),
            size: NSSize(width: 420, height: 360),
            appearance: .light,
            named: "GlobalTabSwitcherOverlay.light",
            tolerance: Self.crossVersionTolerance
        )
    }

    @Test("Overlay renders in dark appearance")
    func dark() throws {
        try assertSnapshot(
            of: Harness(projectManager: try makeProjectManager()),
            size: NSSize(width: 420, height: 360),
            appearance: .dark,
            named: "GlobalTabSwitcherOverlay.dark",
            tolerance: Self.crossVersionTolerance
        )
    }
}
