import Foundation
import Testing
@testable import Pine

@Suite("Project session fixed-layout migration")
@MainActor
struct ProjectSessionRestorerTests {
    private func fixture(files: [String]) throws -> (URL, [String: URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for name in files {
            let url = root.appendingPathComponent(name)
            try "// \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            urls[name] = url
        }
        return (root, urls)
    }

    @Test("Legacy multi-pane documents and terminal sessions merge without loss")
    func restoresMergedLegacyLayout() throws {
        let (root, urls) = try fixture(files: ["a.swift", "b.swift", "c.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let editorA = PaneID()
        let editorB = PaneID()
        let terminalA = PaneID()
        let terminalB = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(editorA, .editor), second: .leaf(terminalA, .terminal), ratio: 0.5),
            second: .split(.vertical, first: .leaf(editorB, .editor), second: .leaf(terminalB, .terminal), ratio: 0.5),
            ratio: 0.5
        )
        let a = try #require(urls["a.swift"])
        let b = try #require(urls["b.swift"])
        let c = try #require(urls["c.swift"])
        let folded = PerTabEditorState.SerializableFoldRange(
            startLine: 1,
            endLine: 2,
            startCharIndex: 0,
            endCharIndex: 5,
            kind: "braces"
        )
        let session = SessionState(
            projectPath: root.path,
            openFilePaths: [a, b, c].map(\.path),
            activeFilePath: b.path,
            editorStates: [
                a.path: PerTabEditorState(
                    cursorPosition: 3,
                    scrollOffset: 42,
                    foldedRanges: [folded]
                ),
            ],
            paneLayoutData: try JSONEncoder().encode(layout),
            paneTabAssignments: [
                editorA.id.uuidString: [a.path],
                editorB.id.uuidString: [b.path, c.path],
            ],
            activePaneID: terminalB.id.uuidString,
            paneActiveEditorPaths: [editorB.id.uuidString: b.path],
            panePinnedPaths: [
                editorA.id.uuidString: [a.path],
                editorB.id.uuidString: [b.path],
            ],
            paneTransientPreviewPaths: [editorB.id.uuidString: c.path],
            globalTabSwitchOrder: [
                .editor(paneID: editorA, filePath: a.path),
            ],
            terminalPaneTabCounts: [
                terminalA.id.uuidString: 2,
                terminalB.id.uuidString: 3,
            ],
            terminalPaneActiveIndices: [
                terminalA.id.uuidString: 0,
                terminalB.id.uuidString: 1,
            ]
        )
        let project = ProjectManager()

        let result = ProjectSessionRestorer.restore(
            session,
            into: project,
            rootURL: root
        )

        #expect(result.didRestoreEditorTabs)
        #expect(result.restoredTerminalPanes)
        #expect(project.paneManager.root.leafCount == 2)
        #expect(project.paneManager.tabManagers.count == 1)
        #expect(project.paneManager.terminalStates.count == 1)
        let tabs = project.primaryTabManager.tabs
        #expect(tabs.map(\.fileURL) == [a, b, c])
        #expect(tabs.filter(\.isPinned).map(\.fileURL) == [a, b])
        #expect(project.primaryTabManager.activeTab?.fileURL == b)
        #expect(tabs.first(where: { $0.fileURL == c })?.isTransientPreview == true)
        #expect(tabs.first(where: { $0.fileURL == a })?.cursorPosition == 3)
        #expect(tabs.first(where: { $0.fileURL == a })?.scrollOffset == 42)
        #expect(tabs.first(where: { $0.fileURL == a })?.content == "// a.swift\n")
        #expect(project.paneManager.activePaneID == migrationEditorID(session: session))
        let terminal = try #require(project.paneManager.terminalStates.values.first)
        #expect(terminal.tabCount == 5)
        // Merged layout keeps the active source's tab first, mirroring the
        // editor merge order above ([a, b, c]).
        #expect(terminal.terminalTabs.firstIndex(where: {
            $0.id == terminal.activeTerminalID
        }) == 1)
    }

    @Test("Missing pane assignments fall back to the saved document union")
    func preservesDocumentUnion() throws {
        let (root, urls) = try fixture(files: ["a.swift", "b.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let editorA = PaneID()
        let editorB = PaneID()
        let layout = PaneNode.split(
            .horizontal,
            first: .leaf(editorA, .editor),
            second: .leaf(editorB, .editor),
            ratio: 0.5
        )
        let a = try #require(urls["a.swift"])
        let b = try #require(urls["b.swift"])
        let session = SessionState(
            projectPath: root.path,
            openFilePaths: [a, b].map(\.path),
            paneLayoutData: try JSONEncoder().encode(layout),
            paneTabAssignments: [editorA.id.uuidString: [a.path]],
            activePaneID: editorA.id.uuidString
        )
        let project = ProjectManager()

        ProjectSessionRestorer.restore(session, into: project, rootURL: root)

        #expect(Set(project.primaryTabManager.tabs.compactMap(\.fileURL)) == [a, b])
    }

    @Test("Terminal-only legacy layout restores and can reveal the retained editor")
    func restoresTerminalOnlyLayout() throws {
        let (root, _) = try fixture(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = PaneID()
        let session = SessionState(
            projectPath: root.path,
            openFilePaths: [],
            paneLayoutData: try JSONEncoder().encode(PaneNode.leaf(terminal, .terminal)),
            activePaneID: terminal.id.uuidString,
            terminalPaneTabCounts: [terminal.id.uuidString: 2],
            terminalPaneActiveIndices: [terminal.id.uuidString: 1]
        )
        let project = ProjectManager()

        ProjectSessionRestorer.restore(session, into: project, rootURL: root)

        #expect(project.paneManager.root.leafCount == 1)
        #expect(project.paneManager.root.firstLeafID == terminal)
        #expect(project.paneManager.terminalState(for: terminal)?.tabCount == 2)
        #expect(project.paneManager.activePaneID == terminal)
        _ = project.paneManager.ensureEditorPane()
        #expect(project.paneManager.root.leafCount == 2)
    }

    @Test("Pre-pane editor and terminal fields still restore")
    func restoresLegacySingleEditorAndTerminal() throws {
        let (root, urls) = try fixture(files: ["a.swift", "b.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try #require(urls["a.swift"])
        let b = try #require(urls["b.swift"])
        let session = SessionState(
            projectPath: root.path,
            openFilePaths: [a, b].map(\.path),
            activeFilePath: b.path,
            terminalTabCount: 2,
            activeTerminalIndex: 1,
            isTerminalVisible: true
        )
        let project = ProjectManager()

        ProjectSessionRestorer.restore(session, into: project, rootURL: root)

        #expect(project.primaryTabManager.tabs.map(\.fileURL) == [a, b])
        #expect(project.primaryTabManager.activeTab?.fileURL == b)
        #expect(project.paneManager.terminalStates.values.first?.tabCount == 2)
        #expect(project.paneManager.terminalStates.values.first?.activeTerminalID
            == project.paneManager.terminalStates.values.first?.terminalTabs[1].id)
    }

    private func migrationEditorID(session: SessionState) -> PaneID? {
        session.activePaneID
            .flatMap(UUID.init(uuidString:))
            .map(PaneID.init(id:))
    }
}
