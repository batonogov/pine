//
//  ProjectManagerTabManagerWiringTests.swift
//  PineTests
//
//  Regression coverage for project services on editor groups created after
//  the primary pane (issue #1169).
//

import Foundation
import Testing

@testable import Pine

@Suite("Project Manager TabManager Wiring")
@MainActor
struct ProjectManagerTabManagerWiringTests {
    @Test("Restored editor groups inherit context and recovery services")
    func restoredManagersAreConfigured() throws {
        let project = ProjectManager()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        project.setupRecovery(projectURL: directory)

        let firstPaneID = PaneID()
        let secondPaneID = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .leaf(firstPaneID, .editor),
            second: .leaf(secondPaneID, .editor),
            ratio: 0.5
        )
        project.paneManager.restoreLayout(
            from: layout,
            activePaneUUID: secondPaneID.id
        )

        // The fixed single-editor workspace collapses the legacy split into
        // the active editor leaf and retains its configured TabManager.
        #expect(project.paneManager.root.leafCount(ofType: .editor) == 1)
        #expect(project.paneManager.tabManager(for: firstPaneID) == nil)
        let tabManager = try #require(
            project.paneManager.tabManager(for: secondPaneID)
        )
        #expect(tabManager === project.primaryTabManager)
        #expect(tabManager.recoveryManager === project.recoveryManager)
        #expect(tabManager.onEditorContextChanged != nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectManagerTabManagerWiringTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
