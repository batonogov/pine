//
//  StatusBarViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for StatusBarView in light and dark appearances.
//  Tests both empty state and state with an active text tab.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("StatusBarView Snapshots")
@MainActor
struct StatusBarViewSnapshotTests {

    private static let barSize = NSSize(width: 600, height: 28)

    /// Creates a TabManager with a deterministic active tab.
    private func makeTabManagerWithActiveTab() -> TabManager {
        let tm = TabManager()
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/test/main.swift"),
            content: "let x = 1\nlet y = 2\n",
            savedContent: "let x = 1\nlet y = 2\n"
        )
        tab.cursorLine = 2
        tab.cursorColumn = 8
        tab.fileSizeBytes = 1024
        tab.recomputeContentCaches()
        tm.tabs = [tab]
        tm.activeTabID = tab.id
        return tm
    }

    /// Creates a GitStatusProvider with deterministic file statuses.
    private func makeGitProviderWithStatuses() -> GitStatusProvider {
        let provider = GitStatusProvider()
        provider.isGitRepository = true
        provider.currentBranch = "main"
        provider.fileStatuses = [
            "/test/modified.swift": .modified,
            "/test/new.swift": .added,
            "/test/unknown.txt": .untracked
        ]
        return provider
    }

    // MARK: - With active tab

    @Test("StatusBar with active tab renders in light appearance")
    func withActiveTabLight() throws {
        let tm = makeTabManagerWithActiveTab()
        let pm = PaneManager(existingTabManager: tm)
        let view = StatusBarView(
            gitProvider: GitStatusProvider(),
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .light,
            named: "StatusBarView.activeTab.light"
        )
    }

    @Test("StatusBar with active tab renders in dark appearance")
    func withActiveTabDark() throws {
        let tm = makeTabManagerWithActiveTab()
        let pm = PaneManager(existingTabManager: tm)
        let view = StatusBarView(
            gitProvider: GitStatusProvider(),
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .dark,
            named: "StatusBarView.activeTab.dark"
        )
    }

    // MARK: - With git statuses

    @Test("StatusBar with git statuses renders in light appearance")
    func withGitStatusesLight() throws {
        let tm = makeTabManagerWithActiveTab()
        let pm = PaneManager(existingTabManager: tm)
        let gitProvider = makeGitProviderWithStatuses()
        let view = StatusBarView(
            gitProvider: gitProvider,
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .light,
            named: "StatusBarView.gitStatuses.light"
        )
    }

    @Test("StatusBar with git statuses renders in dark appearance")
    func withGitStatusesDark() throws {
        let tm = makeTabManagerWithActiveTab()
        let pm = PaneManager(existingTabManager: tm)
        let gitProvider = makeGitProviderWithStatuses()
        let view = StatusBarView(
            gitProvider: gitProvider,
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .dark,
            named: "StatusBarView.gitStatuses.dark"
        )
    }

    // MARK: - Empty state (no active tab)

    @Test("StatusBar empty state renders in light appearance")
    func emptyStateLight() throws {
        let tm = TabManager()
        let pm = PaneManager(existingTabManager: tm)
        let view = StatusBarView(
            gitProvider: GitStatusProvider(),
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .light,
            named: "StatusBarView.empty.light"
        )
    }

    @Test("StatusBar empty state renders in dark appearance")
    func emptyStateDark() throws {
        let tm = TabManager()
        let pm = PaneManager(existingTabManager: tm)
        let view = StatusBarView(
            gitProvider: GitStatusProvider(),
            paneManager: pm,
            tabManager: tm
        )
        try assertSnapshot(
            of: view,
            size: Self.barSize,
            appearance: .dark,
            named: "StatusBarView.empty.dark"
        )
    }
}
