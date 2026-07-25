//
//  SessionInteractionStateTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Session Interaction State")
@MainActor
struct SessionInteractionStateTests {
    @Test("Pane-local interaction fields round-trip without runtime tab UUIDs")
    func interactionFieldsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineInteractionState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let pane = PaneID()
        let terminalPane = PaneID()
        let suiteName = "PineInteractionState.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SessionState.save(
            projectURL: root,
            openFileURLs: [file],
            paneActiveEditorPaths: [pane.id.uuidString: file.path],
            panePinnedPaths: [pane.id.uuidString: [file.path]],
            paneTransientPreviewPaths: [pane.id.uuidString: file.path],
            globalTabSwitchOrder: [
                .editor(paneID: pane, filePath: file.path),
                .terminal(paneID: terminalPane, tabIndex: 2)
            ],
            defaults: defaults
        )

        let loaded = try #require(SessionState.load(for: root, defaults: defaults))
        #expect(loaded.paneActiveEditorPaths == [pane.id.uuidString: file.path])
        #expect(loaded.panePinnedPaths == [pane.id.uuidString: [file.path]])
        #expect(loaded.paneTransientPreviewPaths == [pane.id.uuidString: file.path])
        #expect(loaded.globalTabSwitchOrder == [
            .editor(paneID: pane, filePath: file.path),
            .terminal(paneID: terminalPane, tabIndex: 2)
        ])
    }

    @Test("Older sessions decode with interaction fields absent")
    func backwardsCompatibleDecode() throws {
        let json = """
        {
          "projectPath": "/tmp/project",
          "openFilePaths": []
        }
        """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(state.paneActiveEditorPaths == nil)
        #expect(state.panePinnedPaths == nil)
        #expect(state.paneTransientPreviewPaths == nil)
        #expect(state.globalTabSwitchOrder == nil)
    }
}
