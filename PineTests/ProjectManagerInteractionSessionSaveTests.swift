//
//  ProjectManagerInteractionSessionSaveTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectManager Interaction Session Save")
@MainActor
struct InteractionSessionSaveTests {
    @Test("Save captures pane-local state and stable global MRU references")
    func savesCompleteInteractionState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSessionSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "PineTests.InteractionSessionSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let firstURL = root.appendingPathComponent("first.swift")
        let secondURL = root.appendingPathComponent("second.swift")
        try Data("let first = 1\n".utf8).write(to: firstURL)
        try Data("let second = 2\n".utf8).write(to: secondURL)

        let projectManager = ProjectManager(sessionDefaults: defaults)
        projectManager.workspace.loadDirectory(url: root)
        let firstPane = projectManager.paneManager.activePaneID
        let firstManager = try #require(
            projectManager.paneManager.tabManager(for: firstPane)
        )
        firstManager.openTab(url: firstURL)
        let firstTab = try #require(firstManager.activeTab)
        firstManager.togglePin(id: firstTab.id)

        let secondPane = try #require(
            projectManager.paneManager.splitPane(firstPane, axis: .horizontal)
        )
        let secondManager = try #require(
            projectManager.paneManager.tabManager(for: secondPane)
        )
        secondManager.openTabAsPreview(url: secondURL)
        let secondTab = try #require(secondManager.activeTab)

        let terminalPane = try #require(
            projectManager.paneManager.createTerminalPane(
                relativeTo: secondPane,
                axis: .vertical,
                workingDirectory: root
            )
        )
        let terminalState = try #require(
            projectManager.paneManager.terminalState(for: terminalPane)
        )
        let secondTerminal = terminalState.addTab(workingDirectory: root)

        projectManager.paneManager.selectEditorTab(firstTab.id, in: firstPane)
        projectManager.paneManager.selectTerminalTab(secondTerminal.id, in: terminalPane)
        projectManager.paneManager.selectEditorTab(secondTab.id, in: secondPane)
        projectManager.saveSession()

        let session = try #require(
            SessionState.load(for: root.resolvingSymlinksInPath(), defaults: defaults)
        )
        #expect(session.activePaneID == secondPane.id.uuidString)
        #expect(session.paneActiveEditorPaths == [
            firstPane.id.uuidString: firstURL.path,
            secondPane.id.uuidString: secondURL.path
        ])
        #expect(session.panePinnedPaths == [
            firstPane.id.uuidString: [firstURL.path]
        ])
        #expect(session.paneTransientPreviewPaths == [
            secondPane.id.uuidString: secondURL.path
        ])
        #expect(session.terminalPaneTabCounts?[terminalPane.id.uuidString] == 2)
        #expect(session.terminalPaneActiveIndices?[terminalPane.id.uuidString] == 1)
        #expect(session.globalTabSwitchOrder?.prefix(3) == [
            .editor(paneID: secondPane, filePath: secondURL.path),
            .terminal(paneID: terminalPane, tabIndex: 1),
            .editor(paneID: firstPane, filePath: firstURL.path)
        ])
    }
}
