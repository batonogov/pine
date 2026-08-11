//
//  ProjectSessionRestorerTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Complete Pane Session Restoration")
@MainActor
struct ProjectSessionRestorerTests {
    private func fixture(files: [String]) throws -> (URL, [String: URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSessionRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for name in files {
            let url = root.appendingPathComponent(name)
            try Data("// \(name)\n".utf8).write(to: url)
            urls[name] = url
        }
        return (root, urls)
    }

    @Test("Restores pane-local active, pinned, preview, terminal, focus, and MRU state")
    func restoresCompleteState() throws {
        let (root, files) = try fixture(files: ["a.swift", "b.swift", "c.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = try #require(files["a.swift"])
        let fileB = try #require(files["b.swift"])
        let fileC = try #require(files["c.swift"])

        let editorA = PaneID()
        let editorB = PaneID()
        let terminal = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .leaf(editorA, .editor),
            second: .split(
                .vertical,
                first: .leaf(editorB, .editor),
                second: .leaf(terminal, .terminal),
                ratio: 0.7
            ),
            ratio: 0.45
        )

        var session = SessionState(
            projectPath: root.path,
            openFilePaths: [fileA.path, fileB.path, fileC.path]
        )
        session.paneLayoutData = try JSONEncoder().encode(layout)
        session.paneTabAssignments = [
            editorA.id.uuidString: [fileA.path, fileB.path],
            editorB.id.uuidString: [fileA.path, fileC.path]
        ]
        session.activePaneID = editorB.id.uuidString
        session.paneActiveEditorPaths = [
            editorA.id.uuidString: fileB.path,
            editorB.id.uuidString: fileC.path
        ]
        session.panePinnedPaths = [
            editorA.id.uuidString: [fileA.path],
            editorB.id.uuidString: [fileC.path]
        ]
        session.paneTransientPreviewPaths = [
            editorB.id.uuidString: fileA.path
        ]
        session.terminalPaneTabCounts = [terminal.id.uuidString: 3]
        session.terminalPaneActiveIndices = [terminal.id.uuidString: 1]
        session.globalTabSwitchOrder = [
            .editor(paneID: editorB, filePath: fileC.path),
            .terminal(paneID: terminal, tabIndex: 1),
            .editor(paneID: editorA, filePath: fileB.path),
            .editor(paneID: editorA, filePath: root.appendingPathComponent("gone.swift").path),
            .editor(paneID: editorB, filePath: fileC.path)
        ]

        let projectManager = ProjectManager()
        let result = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        #expect(result == ProjectSessionRestoreResult(
            didRestoreEditorTabs: true,
            restoredTerminalPanes: true
        ))
        #expect(projectManager.paneManager.root == layout)
        #expect(projectManager.paneManager.activePaneID == editorB)
        #expect(projectManager.terminal.lastActiveTerminalPaneID == terminal)

        let managerA = try #require(projectManager.paneManager.tabManager(for: editorA))
        let managerB = try #require(projectManager.paneManager.tabManager(for: editorB))
        #expect(managerA.tabs.map(\.url) == [fileA, fileB])
        #expect(managerA.tabs.map(\.isPinned) == [true, false])
        #expect(managerA.activeTab?.url == fileB)

        #expect(managerB.tabs.map(\.url) == [fileC, fileA])
        #expect(managerB.tabs.map(\.isPinned) == [true, false])
        #expect(managerB.tabs.first(where: { $0.url == fileA })?.isTransientPreview == true)
        #expect(managerB.activeTab?.url == fileC)
        #expect(managerB.pendingFocusTabID == managerB.activeTabID)

        let terminalState = try #require(
            projectManager.paneManager.terminalState(for: terminal)
        )
        #expect(terminalState.terminalTabs.count == 3)
        #expect(terminalState.activeTerminalID == terminalState.terminalTabs[1].id)
        #expect(projectManager.terminal.lastActiveTerminalPaneID == terminal)

        let order = projectManager.paneManager.validGlobalTabSwitchOrder()
        #expect(order.count == 7)
        #expect(editorPath(for: order[0], in: projectManager.paneManager) == fileC.path)
        #expect(order[1].paneID == terminal)
        #expect(order[1].tabID == terminalState.terminalTabs[1].id)
        #expect(editorPath(for: order[2], in: projectManager.paneManager) == fileB.path)
        #expect(Set(order).count == order.count)
    }

    @Test("Restores a single terminal pane instead of falling back to an editor")
    func restoresSingleTerminalPane() throws {
        let (root, _) = try fixture(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalPane = PaneID()
        var session = SessionState(projectPath: root.path, openFilePaths: [])
        session.paneLayoutData = try JSONEncoder().encode(
            PaneNode.leaf(terminalPane, .terminal)
        )
        session.activePaneID = terminalPane.id.uuidString
        session.terminalPaneTabCounts = [terminalPane.id.uuidString: 2]
        session.terminalPaneActiveIndices = [terminalPane.id.uuidString: 0]

        let projectManager = ProjectManager()
        let result = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        #expect(result.didRestoreEditorTabs == false)
        #expect(result.restoredTerminalPanes)
        #expect(projectManager.paneManager.root == .leaf(terminalPane, .terminal))
        #expect(projectManager.paneManager.activePaneID == terminalPane)
        let state = try #require(projectManager.paneManager.terminalState(for: terminalPane))
        #expect(state.terminalTabs.count == 2)
        #expect(state.activeTerminalID == state.terminalTabs[0].id)
        #expect(state.pendingFocusTabID == state.activeTerminalID)
        #expect(projectManager.terminal.lastActiveTerminalPaneID == terminalPane)
        #expect(projectManager.paneManager.validGlobalTabSwitchOrder().count == 2)
    }

    @Test("Legacy terminal fields populate a restored terminal leaf without adding a pane")
    func migratesLegacyTerminalStateIntoRestoredPane() throws {
        let (root, _) = try fixture(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalPane = PaneID()
        var session = SessionState(projectPath: root.path, openFilePaths: [])
        session.paneLayoutData = try JSONEncoder().encode(
            PaneNode.leaf(terminalPane, .terminal)
        )
        session.activePaneID = terminalPane.id.uuidString
        session.isTerminalVisible = true
        session.terminalTabCount = 2
        session.activeTerminalIndex = 1

        let projectManager = ProjectManager()
        _ = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        #expect(projectManager.paneManager.root == .leaf(terminalPane, .terminal))
        let state = try #require(
            projectManager.paneManager.terminalState(for: terminalPane)
        )
        #expect(state.terminalTabs.count == 2)
        #expect(state.activeTerminalID == state.terminalTabs[1].id)
        #expect(projectManager.terminal.lastActiveTerminalPaneID == terminalPane)
    }

    @Test("Legacy active file selects its owning non-primary pane")
    func restoresLegacyActiveFileAcrossPanes() throws {
        let (root, files) = try fixture(files: ["left.swift", "right.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let leftURL = try #require(files["left.swift"])
        let rightURL = try #require(files["right.swift"])
        let leftPane = PaneID()
        let rightPane = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .leaf(leftPane, .editor),
            second: .leaf(rightPane, .editor),
            ratio: 0.5
        )
        var session = SessionState(
            projectPath: root.path,
            openFilePaths: [leftURL.path, rightURL.path],
            activeFilePath: rightURL.path
        )
        session.paneLayoutData = try JSONEncoder().encode(layout)
        session.paneTabAssignments = [
            leftPane.id.uuidString: [leftURL.path],
            rightPane.id.uuidString: [rightURL.path]
        ]
        session.activePaneID = rightPane.id.uuidString

        let projectManager = ProjectManager()
        _ = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        #expect(projectManager.paneManager.activePaneID == rightPane)
        #expect(projectManager.terminal.lastActiveTerminalPaneID == nil)
        #expect(projectManager.paneManager.tabManager(for: rightPane)?.activeTab?.url == rightURL)
    }

    @Test("Editor-focused restore chooses the first valid terminal without stealing focus")
    func terminalDestinationFallbackUsesStableOrderWithoutFocusTheft() throws {
        let (root, files) = try fixture(files: ["focused.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try #require(files["focused.swift"])
        let editor = PaneID()
        let firstTerminal = PaneID()
        let secondTerminal = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .leaf(editor, .editor),
            second: .split(
                .vertical,
                first: .leaf(firstTerminal, .terminal),
                second: .leaf(secondTerminal, .terminal),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        var session = SessionState(
            projectPath: root.path,
            openFilePaths: [file.path]
        )
        session.paneLayoutData = try JSONEncoder().encode(layout)
        session.paneTabAssignments = [editor.id.uuidString: [file.path]]
        session.paneActiveEditorPaths = [editor.id.uuidString: file.path]
        session.activePaneID = editor.id.uuidString
        session.terminalPaneTabCounts = [
            firstTerminal.id.uuidString: 1,
            secondTerminal.id.uuidString: 1,
        ]

        let projectManager = ProjectManager()
        _ = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        #expect(projectManager.paneManager.activePaneID == editor)
        #expect(
            projectManager.paneManager.tabManager(for: editor)?
                .pendingFocusTabID
                == projectManager.paneManager.tabManager(for: editor)?
                    .activeTabID
        )
        #expect(
            projectManager.terminal.lastActiveTerminalPaneID
                == firstTerminal
        )
    }

    @Test("Pinned and preview state is pane-scoped for duplicate file paths")
    func paneScopedStateForDuplicatePaths() throws {
        let (root, files) = try fixture(files: ["shared.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try #require(files["shared.swift"])
        let firstPane = PaneID()
        let secondPane = PaneID()
        var session = SessionState(projectPath: root.path, openFilePaths: [shared.path])
        session.paneLayoutData = try JSONEncoder().encode(
            PaneNode.split(
                .horizontal,
                first: .leaf(firstPane, .editor),
                second: .leaf(secondPane, .editor),
                ratio: 0.5
            )
        )
        session.paneTabAssignments = [
            firstPane.id.uuidString: [shared.path],
            secondPane.id.uuidString: [shared.path]
        ]
        // The pane-local map is authoritative for new sessions. A missing
        // pane entry means "no pins", not "fall back to the legacy global
        // set" (which would incorrectly pin the duplicate in both panes).
        session.pinnedPaths = [shared.path]
        session.panePinnedPaths = [firstPane.id.uuidString: [shared.path]]
        session.paneTransientPreviewPaths = [secondPane.id.uuidString: shared.path]

        let projectManager = ProjectManager()
        _ = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: root
        )

        let first = try #require(projectManager.paneManager.tabManager(for: firstPane)?.tabs.first)
        let second = try #require(projectManager.paneManager.tabManager(for: secondPane)?.tabs.first)
        #expect(first.isPinned)
        #expect(!first.isTransientPreview)
        #expect(!second.isPinned)
        #expect(second.isTransientPreview)
    }

    private func editorPath(
        for identity: GlobalTabIdentity,
        in paneManager: PaneManager
    ) -> String? {
        paneManager.tabManager(for: identity.paneID)?.tabs
            .first(where: { $0.id == identity.tabID })?.url.path
    }
}
