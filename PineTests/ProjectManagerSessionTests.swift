//
//  ProjectManagerSessionTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectManager Session Tests")
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

        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: files[1])
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

        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: files[1])
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

        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: outsideFile)
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
        pm.tabManager.openTab(url: files[0])
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
        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: files[1])
        pm.saveSession()

        // Open a third tab and save again
        pm.tabManager.openTab(url: files[2])
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
        pm1.tabManager.openTab(url: files[0])
        pm1.tabManager.openTab(url: files[1])
        pm1.tabManager.openTab(url: files[2])
        // Switch active to middle tab
        if let middleTab = pm1.tabManager.tab(for: files[1]) {
            pm1.tabManager.activeTabID = middleTab.id
        }
        pm1.saveSession()

        // Phase 2: simulate reopen — new PM, load session, restore tabs
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)

        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        for url in session.existingFileURLs {
            pm2.tabManager.openTab(url: url)
        }
        if let activeURL = session.activeFileURL,
           let tab = pm2.tabManager.tab(for: activeURL) {
            pm2.tabManager.activeTabID = tab.id
        }

        // Verify restoration
        #expect(pm2.tabManager.tabs.count == 3)
        #expect(pm2.tabManager.activeTab?.url == files[1])
        #expect(pm2.tabManager.tabs.map(\.url) == files)
    }

    @Test func saveSessionPersistsHighlightingDisabled() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: files[1])
        // Simulate opening files[1] without highlighting (large file)
        pm.tabManager.tabs[1].syntaxHighlightingDisabled = true
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
            pm2.tabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }

        #expect(pm2.tabManager.tabs[0].syntaxHighlightingDisabled == false)
        #expect(pm2.tabManager.tabs[1].syntaxHighlightingDisabled == true)
    }

    @Test func sessionSurvivedWindowClose() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))

        pm.tabManager.openTab(url: files[0])
        pm.tabManager.openTab(url: files[1])

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
            pm2.tabManager.openTab(url: url)
        }
        #expect(pm2.tabManager.tabs.count == 2)
    }
}
