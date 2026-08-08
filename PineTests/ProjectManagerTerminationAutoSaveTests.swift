//
//  ProjectManagerTerminationAutoSaveTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Project Manager Termination Auto-Save Tests", .serialized)
@MainActor
struct ProjectManagerTerminationAutoSaveTests {
    @Test("editor managers created during Quit inherit the auto-save freeze")
    func newEditorManagerInheritsTerminationFreeze() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("late-pane.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let project = ProjectManager()
        let initialPane = project.paneManager.activePaneID
        project.freezeAutoSaveForTermination()
        let newPane = try #require(project.paneManager.splitPane(
            initialPane,
            axis: .horizontal
        ))
        let tabs = try #require(project.paneManager.tabManager(for: newPane))
        tabs.openTab(url: file)
        tabs.autoSavePreferenceProvider = { true }
        tabs.setAutoSaveDelay(0.05)
        tabs.updateContent("must remain unsaved during Quit")

        #expect(tabs.activeTab?.isDirty == true)
        #expect(!tabs.hasScheduledAutoSave)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")

        project.cancelAutoSaveTerminationFreeze()
        #expect(tabs.hasScheduledAutoSave)
        tabs.cancelAutoSave()
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }
}
