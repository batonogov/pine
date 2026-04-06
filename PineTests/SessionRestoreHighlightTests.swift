//
//  SessionRestoreHighlightTests.swift
//  PineTests
//
//  Tests for issue #671 — session-restored tabs must have an active tab
//  set so that git diff refresh and syntax highlighting are triggered.
//

import Foundation
import Testing

@testable import Pine

@Suite("Session Restore Highlight Tests")
@MainActor
struct SessionRestoreHighlightTests {

    // MARK: - Helpers

    private func makeTempProject(fileCount: Int = 3) throws -> (dir: URL, files: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var files: [URL] = []
        for i in 0..<fileCount {
            let file = dir.appendingPathComponent("file\(i).swift")
            try "// content of file\(i)".write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
        }
        return (dir, files)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Active tab after session restore

    @Test func restoredSessionHasActiveTab() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Phase 1: save session with 3 tabs, middle one active
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        for file in files { pm1.primaryTabManager.openTab(url: file) }
        if let middleTab = pm1.primaryTabManager.tab(for: files[1]) {
            pm1.primaryTabManager.activeTabID = middleTab.id
        }
        pm1.saveSession()

        // Phase 2: restore into fresh TabManager
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }
        if let activeURL = session.activeFileURL,
           let tab = pm2.primaryTabManager.tab(for: activeURL) {
            pm2.primaryTabManager.activeTabID = tab.id
        }

        // The active tab must exist and match the saved one
        #expect(pm2.primaryTabManager.activeTab != nil)
        #expect(pm2.primaryTabManager.activeTab?.url == files[1])
        // Verify content was loaded (precondition for syntax highlighting)
        #expect(pm2.primaryTabManager.activeTab?.content.isEmpty == false)
    }

    @Test func restoredSingleTabIsActive() throws {
        let (dir, files) = try makeTempProject(fileCount: 1)
        defer { cleanup(dir) }

        // Save with one tab
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        pm1.primaryTabManager.openTab(url: files[0])
        pm1.saveSession()

        // Restore
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

        // Single tab must be active — this is the case where onChange(activeTabID)
        // might not fire if the value was already set by openTab.
        #expect(pm2.primaryTabManager.activeTab != nil)
        #expect(pm2.primaryTabManager.activeTab?.url == files[0])
    }

    @Test func restoredLastTabAsActiveDoesNotChangeID() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Save with last tab active (which is the default after opening)
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        for file in files { pm1.primaryTabManager.openTab(url: file) }
        // Last tab (files[2]) is already active — don't explicitly set it
        pm1.saveSession()

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url)
        }

        // Track the activeTabID before the explicit set
        let idBeforeExplicitSet = pm2.primaryTabManager.activeTabID

        if let activeURL = session.activeFileURL,
           let tab = pm2.primaryTabManager.tab(for: activeURL) {
            pm2.primaryTabManager.activeTabID = tab.id
        }

        // The explicit set should be a no-op because last tab was already active.
        // This is the edge case where onChange(activeTabID) would NOT fire,
        // so the caller must explicitly trigger refreshLineDiffs.
        #expect(pm2.primaryTabManager.activeTabID == idBeforeExplicitSet)
        #expect(pm2.primaryTabManager.activeTab?.url == files[2])
    }

    @Test func restoredTabsHaveContentForHighlighting() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Write distinct content to each file
        for (i, file) in files.enumerated() {
            try "func example\(i)() { return \(i) }".write(to: file, atomically: true, encoding: .utf8)
        }

        // Save and restore
        let pm1 = ProjectManager()
        pm1.workspace.loadDirectory(url: dir)
        for file in files { pm1.primaryTabManager.openTab(url: file) }
        pm1.saveSession()

        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }

        // All tabs must have content loaded from disk
        for (i, tab) in pm2.primaryTabManager.tabs.enumerated() {
            #expect(!tab.content.isEmpty, "Tab \(i) (\(tab.fileName)) has empty content")
            #expect(tab.content.contains("example\(i)"),
                    "Tab \(i) content should match file content")
        }
    }

    @Test func restoredTabsHaveCorrectLanguage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }

        let swiftFile = dir.appendingPathComponent("main.swift")
        let jsFile = dir.appendingPathComponent("app.js")
        let pyFile = dir.appendingPathComponent("script.py")
        try "let x = 1".write(to: swiftFile, atomically: true, encoding: .utf8)
        try "const x = 1".write(to: jsFile, atomically: true, encoding: .utf8)
        try "x = 1".write(to: pyFile, atomically: true, encoding: .utf8)

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)

        for url in [swiftFile, jsFile, pyFile] {
            pm.primaryTabManager.openTab(url: url)
        }
        pm.saveSession()

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url)
        }

        // Language extension must be preserved for syntax highlighting grammar selection
        let languages = pm2.primaryTabManager.tabs.map(\.language)
        #expect(languages.contains("swift"))
        #expect(languages.contains("js"))
        #expect(languages.contains("py"))
    }

    @Test func restoredTabsSyntaxHighlightingNotDisabledByDefault() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)
        for file in files { pm.primaryTabManager.openTab(url: file) }
        pm.saveSession()

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }

        // No tabs should have highlighting disabled for normal-sized files
        for tab in pm2.primaryTabManager.tabs {
            #expect(tab.syntaxHighlightingDisabled == false,
                    "\(tab.fileName) should not have highlighting disabled")
        }
    }

    @Test func restoredTabPreservesHighlightingDisabled() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Save with one tab having highlighting disabled
        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)
        for file in files { pm.primaryTabManager.openTab(url: file) }
        pm.primaryTabManager.tabs[1].syntaxHighlightingDisabled = true
        pm.saveSession()

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }

        #expect(pm2.primaryTabManager.tabs[0].syntaxHighlightingDisabled == false)
        #expect(pm2.primaryTabManager.tabs[1].syntaxHighlightingDisabled == true)
        #expect(pm2.primaryTabManager.tabs[2].syntaxHighlightingDisabled == false)
    }

    @Test func restoreEmptySessionDoesNotSetActiveTab() throws {
        let (dir, _) = try makeTempProject(fileCount: 0)
        defer { cleanup(dir) }

        // Save empty session
        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)
        pm.saveSession()

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)

        // Session exists but has no files
        if let session {
            for url in session.existingFileURLs {
                pm2.primaryTabManager.openTab(url: url)
            }
        }

        // No tabs, no active tab — refreshLineDiffs should be a no-op
        #expect(pm2.primaryTabManager.tabs.isEmpty)
        #expect(pm2.primaryTabManager.activeTabID == nil)
    }

    @Test func deletedFilesSkippedDuringRestore() throws {
        let (dir, files) = try makeTempProject()
        defer { cleanup(dir) }

        // Save session
        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)
        for file in files { pm.primaryTabManager.openTab(url: file) }
        if let middleTab = pm.primaryTabManager.tab(for: files[1]) {
            pm.primaryTabManager.activeTabID = middleTab.id
        }
        pm.saveSession()

        // Delete the active file before restore
        try FileManager.default.removeItem(at: files[1])

        // Restore
        let pm2 = ProjectManager()
        pm2.workspace.loadDirectory(url: dir)
        let canonical = dir.resolvingSymlinksInPath()
        let session = try #require(SessionState.load(for: canonical))

        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        for url in session.existingFileURLs {
            pm2.primaryTabManager.openTab(url: url, syntaxHighlightingDisabled: disabledSet.contains(url.path))
        }
        // Active file was deleted, so activeFileURL returns nil
        if let activeURL = session.activeFileURL,
           let tab = pm2.primaryTabManager.tab(for: activeURL) {
            pm2.primaryTabManager.activeTabID = tab.id
        }

        // Only 2 tabs restored (deleted file skipped by existingFileURLs)
        #expect(pm2.primaryTabManager.tabs.count == 2)
        // activeTab should still be set (fallback to last opened)
        #expect(pm2.primaryTabManager.activeTab != nil)
    }
}
