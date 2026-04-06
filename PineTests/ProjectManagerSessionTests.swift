//
//  ProjectManagerSessionTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectManager Session Tests")
@MainActor
struct ProjectManagerSessionTests {

    private func makeTempProject() throws -> (dir: URL, files: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("main.swift")
        let file2 = dir.appendingPathComponent("model.swift")
        let file3 = dir.appendingPathComponent("view.swift")
        for file in [file1, file2, file3] {
            try "// \(file.lastPathComponent)".write(to: file, atomically: true, encoding: .utf8)
        }
        return (dir, [file1, file2, file3])
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - saveSession basics

    @Test func saveSessionPersistsOpenTabs() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: files[1])
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session != nil)
        #expect(session?.existingFileURLs.count == 2)
        #expect(session?.existingFileURLs.contains(files[0]) == true)
        #expect(session?.existingFileURLs.contains(files[1]) == true)
    }

    @Test func saveSessionPersistsActiveTab() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: files[1])
        // files[1] is active (last opened)
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session?.activeFileURL == files[1])
    }

    @Test func saveSessionFiltersFilesOutsideProject() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Create a file outside the project
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { cleanup(outsideDir) }
        let outsideFile = outsideDir.appendingPathComponent("external.swift")
        try "external".write(to: outsideFile, atomically: true, encoding: .utf8)

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: outsideFile)
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session?.existingFileURLs.count == 1)
        #expect(session?.existingFileURLs.first == files[0])
    }

    @Test func saveSessionNoOpWithoutRootURL() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        // Do NOT call loadDirectory — rootURL stays nil
        pm.primaryTabManager.openTab(url: files[0])
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session == nil)
    }

    @Test func saveSessionOverwritesPreviousSession() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        // First save with 2 tabs
        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: files[1])
        pm.saveSession()

        // Open a third tab and save again
        pm.primaryTabManager.openTab(url: files[2])
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session?.existingFileURLs.count == 3)
    }

    // MARK: - Full lifecycle (integration)

    @Test func fullLifecycleOpenSaveRestore() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Phase 1: open tabs and save
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        pm1.primaryTabManager.openTab(url: files[0])
        pm1.primaryTabManager.openTab(url: files[1])
        pm1.primaryTabManager.openTab(url: files[2])
        // Switch active to middle tab
        if let middleTab = pm1.primaryTabManager.tab(for: files[1]) {
            pm1.primaryTabManager.activeTabID = middleTab.id
        }
        pm1.saveSession()

        // Phase 2: simulate reopen — new PM, load session, restore tabs
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)

        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url)
        }
        if let activeURL = session.activeFileURL,
           let tab = pm2.primaryTabManager.tab(for: activeURL) {
            pm2.primaryTabManager.activeTabID = tab.id
        }

        // Verify restoration
        #expect(pm2.primaryTabManager.tabs.count == 3)
        #expect(pm2.primaryTabManager.activeTab?.url == files[1])
        #expect(pm2.primaryTabManager.tabs.map(\.url) == files)
    }

    // MARK: - Outside-root filtering (issue #170)

    @Test func saveSessionFiltersActiveFileOutsideProject() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { cleanup(outsideDir) }
        let outsideFile = outsideDir.appendingPathComponent("external.swift")
        try "external".write(to: outsideFile, atomically: true, encoding: .utf8)

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: outsideFile)
        // outsideFile is now active (last opened)
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        // Active file outside project root should be cleared
        #expect(session?.activeFilePath == nil)
    }

    @Test func saveSessionFiltersPreviewModesOutsideProject() throws {
        let (dir, _) = try makeTempProject()
        defer { cleanup(dir) }

        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { cleanup(outsideDir) }

        let insideMd = dir.appendingPathComponent("readme.md")
        let outsideMd = outsideDir.appendingPathComponent("notes.md")
        try "# Inside".write(to: insideMd, atomically: true, encoding: .utf8)
        try "# Outside".write(to: outsideMd, atomically: true, encoding: .utf8)

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: insideMd)
        pm.primaryTabManager.openTab(url: outsideMd)
        // Set non-default preview mode on both
        for index in pm.primaryTabManager.tabs.indices where pm.primaryTabManager.tabs[index].isMarkdownFile {
            pm.primaryTabManager.tabs[index].previewMode = .split
        }
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        // Only inside markdown should have preview mode persisted
        #expect(session?.previewModes?.count == 1)
        #expect(session?.previewModes?[insideMd.path] == "split")
        #expect(session?.previewModes?[outsideMd.path] == nil)
    }

    @Test func saveSessionFiltersHighlightingDisabledOutsideProject() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { cleanup(outsideDir) }
        let outsideFile = outsideDir.appendingPathComponent("big.swift")
        try "big".write(to: outsideFile, atomically: true, encoding: .utf8)

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: outsideFile)
        // Disable highlighting on both
        pm.primaryTabManager.tabs[0].syntaxHighlightingDisabled = true
        pm.primaryTabManager.tabs[1].syntaxHighlightingDisabled = true
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        // Only inside file should be persisted
        #expect(session?.highlightingDisabledPaths?.count == 1)
        #expect(session?.highlightingDisabledPaths?.first == files[0].path)
    }

    @Test func saveSessionPersistsHighlightingDisabled() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: files[1])
        // Simulate opening files[1] without highlighting (large file)
        pm.primaryTabManager.tabs[1].syntaxHighlightingDisabled = true
        pm.saveSession()

        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        #expect(session.highlightingDisabledPaths?.count == 1)
        #expect(session.highlightingDisabledPaths?.first == files[1].path)

        // Phase 2: restore — use overload that skips alert
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let disabledSet = Set(session.highlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }

        #expect(pm2.primaryTabManager.tabs[0].syntaxHighlightingDisabled == false)
        #expect(pm2.primaryTabManager.tabs[1].syntaxHighlightingDisabled == true)
    }

    @Test func sessionSurvivedWindowClose() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))

        pm.primaryTabManager.openTab(url: files[0])
        pm.primaryTabManager.openTab(url: files[1])

        // Simulate PR #98 onDisappear behavior: save THEN close
        let canonical = dir.resolvingSymlinksInPath()
        pm.saveSession()
        registry.closeProject(dir)

        // Session must still be loadable after close (PR #98 fix)
        let session = SessionState.load(for: canonical)
        #expect(session != nil)
        #expect(session?.existingFileURLs.count == 2)

        // Simulate reopen from Welcome
        let pm2 = try #require(registry.projectManager(for: dir))
        let restoredSession = try #require(SessionState.load(for: canonical))
        for url in restoredSession.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url)
        }
        #expect(pm2.primaryTabManager.tabs.count == 2)
    }

    // MARK: - Empty editor + terminal layout round-trip

    /// Persist a layout where the editor pane sits empty next to a terminal
    /// pane, then reload it: after restore, `pruneEmptyEditorLeaves` must
    /// collapse the empty editor so the user does not face the same UX bug
    /// twice across app launches.
    @Test func roundTrip_emptyEditorNextToTerminal_isPrunedAfterRestore() throws {
        let (dir, _) = try makeTempProject()
        defer { cleanup(dir) }

        // Phase 1: build "empty editor + terminal" layout and save the session.
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        let editorPaneID = pm1.paneManager.activePaneID
        _ = pm1.paneManager.createTerminalPane(
            relativeTo: editorPaneID, axis: .vertical, workingDirectory: dir
        )
        // Editor pane is intentionally left empty.
        #expect(pm1.paneManager.root.leafCount(ofType: .editor) == 1)
        #expect(pm1.paneManager.root.leafCount(ofType: .terminal) == 1)
        pm1.saveSession()

        // Phase 2: reload session into a fresh ProjectManager and apply the
        // same restore steps that ContentView+Helpers.restoreSessionIfNeeded
        // performs (restoreLayout → populate → pruneEmptyEditorLeaves).
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)

        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))
        let layoutData = try #require(session.paneLayoutData)
        let restoredNode = try #require(try? JSONDecoder().decode(PaneNode.self, from: layoutData))
        pm2.paneManager.restoreLayout(
            from: restoredNode,
            activePaneUUID: session.activePaneID.flatMap { UUID(uuidString: $0) }
        )
        // No tabs to populate — the editor leaf was empty when persisted.
        pm2.paneManager.pruneEmptyEditorLeaves()

        // After prune the empty editor must be gone — only the terminal remains.
        #expect(pm2.paneManager.root.leafCount == 1)
        #expect(pm2.paneManager.root.leafCount(ofType: .editor) == 0)
        #expect(pm2.paneManager.root.leafCount(ofType: .terminal) == 1)
    }
}
