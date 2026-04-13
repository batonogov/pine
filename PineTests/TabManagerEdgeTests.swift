//
//  TabManagerEdgeTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("TabManager Edge Case Tests")
@MainActor
struct TabManagerEdgeTests {

    private func makeTabManager() -> TabManager {
        let suite = "TabManagerEdgeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create UserDefaults")
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        settings.formatOnSave = false
        let manager = TabManager()
        manager.editorSettings = settings
        return manager
    }

    /// Creates a temp directory. Caller must use `defer { cleanup(dir) }`.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabMgrEdge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempFile(
        in dir: URL,
        name: String = "test.swift",
        content: String = "hello"
    ) -> URL {
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Tab navigation

    @Test func selectTab_validIndex() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.selectTab(at: 0)
        #expect(manager.activeTab?.url == url1)
    }

    @Test func selectTab_negativeIndex_noOp() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: tempFile(in: dir))
        let id = manager.activeTabID
        manager.selectTab(at: -1)
        #expect(manager.activeTabID == id)
    }

    @Test func selectTab_outOfBounds_noOp() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: tempFile(in: dir))
        let id = manager.activeTabID
        manager.selectTab(at: 100)
        #expect(manager.activeTabID == id)
    }

    @Test func selectLastTab() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        let url3 = tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        manager.selectTab(at: 0)
        manager.selectLastTab()
        #expect(manager.activeTab?.url == url3)
    }

    @Test func selectLastTab_emptyTabs_noOp() {
        let manager = makeTabManager()
        manager.selectLastTab()
        #expect(manager.activeTabID == nil)
    }

    @Test func selectNextTab_wraps() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.selectNextTab()
        #expect(manager.activeTab?.url == url1)
    }

    @Test func selectNextTab_emptyTabs_noOp() {
        let manager = makeTabManager()
        manager.selectNextTab()
        #expect(manager.activeTabID == nil)
    }

    @Test func selectPreviousTab_wraps() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.selectTab(at: 0)
        manager.selectPreviousTab()
        #expect(manager.activeTab?.url == url2)
    }

    @Test func selectPreviousTab_emptyTabs_noOp() {
        let manager = makeTabManager()
        manager.selectPreviousTab()
        #expect(manager.activeTabID == nil)
    }

    // MARK: - Pin tabs

    @Test func togglePin_pinsTab() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        #expect(manager.activeTab?.isPinned == true)
        #expect(manager.pinnedTabCount == 1)
    }

    @Test func togglePin_unpinsTab() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.togglePin(id: id)
        #expect(manager.activeTab?.isPinned == false)
        #expect(manager.pinnedTabCount == 0)
    }

    @Test func pinnedTab_resistsClose() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.closeTab(id: id)
        #expect(manager.tabs.count == 1)
    }

    @Test func pinnedTab_closesWhenForced() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.closeTab(id: id, force: true)
        #expect(manager.tabs.isEmpty)
    }

    @Test func restorePinnedState() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.restorePinnedState(pinnedPaths: [url1.path])
        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[1].isPinned == false)
    }

    // MARK: - Close operations

    @Test func closeOtherTabs_keepsPinnedAndTarget() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        let url3 = tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        let id1 = manager.tabs[0].id
        manager.togglePin(id: manager.tabs[1].id)

        manager.closeOtherTabs(keeping: id1, force: true)
        #expect(manager.tabs.count == 2)
    }

    @Test func closeTabsToTheRight() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        let url3 = tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        let id1 = manager.tabs[0].id
        manager.closeTabsToTheRight(of: id1, force: true)
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == url1)
    }

    @Test func closeTabsToTheRight_pinnedPreserved() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        let url3 = tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        let bID = manager.tabs[1].id
        manager.togglePin(id: bID)
        guard let aTab = manager.tabs.first(where: { $0.url == url1 }) else {
            Issue.record("Expected to find a.swift tab")
            return
        }
        manager.closeTabsToTheRight(of: aTab.id, force: true)
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains { $0.isPinned })
    }

    @Test func closeAllTabs_force() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: tempFile(in: dir, name: "a.swift"))
        manager.openTab(url: tempFile(in: dir, name: "b.swift"))

        manager.closeAllTabs(force: true)
        #expect(manager.tabs.isEmpty)
    }

    @Test func dirtyTabsForCloseOthers() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseOthers(keeping: manager.tabs[0].id)
        #expect(dirty.count == 1)
    }

    @Test func dirtyTabsForCloseRight() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseRight(of: manager.tabs[0].id)
        #expect(dirty.count == 1)
    }

    @Test func dirtyTabsForCloseAll() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseAll()
        #expect(dirty.count == 1)
    }

    // MARK: - Tab reordering

    @Test func reorderTab_swapsPositions() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        let id1 = manager.tabs[0].id
        let id2 = manager.tabs[1].id
        manager.reorderTab(draggedID: id1, targetID: id2)

        #expect(manager.tabs[0].id == id2 || manager.tabs[1].id == id1)
    }

    @Test func reorderTab_sameID_noOp() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        let id = manager.tabs[0].id

        manager.reorderTab(draggedID: id, targetID: id)
        #expect(manager.tabs.count == 1)
    }

    @Test func reorderTab_pinnedToUnpinned_blocked() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        let id1 = manager.tabs[0].id
        let id2 = manager.tabs[1].id
        manager.togglePin(id: id1)

        let originalOrder = manager.tabs.map(\.id)
        manager.reorderTab(draggedID: id1, targetID: id2)
        #expect(manager.tabs.map(\.id) == originalOrder)
    }

    // MARK: - moveTab

    @Test func moveTab_fromOffsets() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = tempFile(in: dir, name: "a.swift")
        let url2 = tempFile(in: dir, name: "b.swift")
        let url3 = tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        manager.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(manager.tabs[0].url == url3)
    }

    // MARK: - Line endings

    @Test func convertActiveTabLineEndings_changesToCRLF() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir, content: "line1\nline2\n")
        manager.openTab(url: url)
        manager.convertActiveTabLineEndings(to: .crlf)
        #expect(manager.activeTab?.content.contains("\r\n") == true)
    }

    @Test func convertActiveTabLineEndings_noChangeIfSame() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir, content: "line1\nline2\n")
        manager.openTab(url: url)

        let contentBefore = manager.activeTab?.content
        manager.convertActiveTabLineEndings(to: .lf)
        #expect(manager.activeTab?.content == contentBefore)
    }

    @Test func convertActiveTabLineEndings_noActiveTab() {
        let manager = makeTabManager()
        manager.convertActiveTabLineEndings(to: .crlf)
    }

    // MARK: - File rename handling

    @Test func handleFileRenamed_updatesURL() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let oldURL = tempFile(in: dir, name: "old.swift")
        manager.openTab(url: oldURL)

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("new.swift")
        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs[0].url == newURL)
    }

    @Test func handleFileRenamed_updatesChildPaths() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("oldDir"), withIntermediateDirectories: true
        )
        let childURL = dir.appendingPathComponent("oldDir/child.swift")
        try? "test".write(to: childURL, atomically: true, encoding: .utf8)
        manager.openTab(url: childURL)

        let oldDir = dir.appendingPathComponent("oldDir")
        let newDir = dir.appendingPathComponent("newDir")
        manager.handleFileRenamed(oldURL: oldDir, newURL: newDir)

        #expect(manager.tabs[0].url.path.contains("newDir"))
    }

    // MARK: - Update operations

    @Test func updateFoldState() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)

        let foldState = FoldState()
        manager.updateFoldState(foldState)
        #expect(manager.activeTab?.foldState != nil)
    }

    @Test func updateEditorState() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir, content: "line1\nline2\n")
        manager.openTab(url: url)

        manager.updateEditorState(cursorPosition: 6, scrollOffset: 100)
        #expect(manager.activeTab?.cursorPosition == 6)
        #expect(manager.activeTab?.scrollOffset == 100)
    }

    // MARK: - Preview file detection

    @Test func isPreviewFile_imageIsPreview() {
        let manager = makeTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.png")
        #expect(manager.isPreviewFile(url: url))
    }

    @Test func isPreviewFile_pdfIsPreview() {
        let manager = makeTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        #expect(manager.isPreviewFile(url: url))
    }

    @Test func isPreviewFile_swiftIsNotPreview() {
        let manager = makeTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        #expect(!manager.isPreviewFile(url: url))
    }

    @Test func isPreviewFile_unknownIsNotPreview() {
        let manager = makeTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.xyz_unknown")
        #expect(!manager.isPreviewFile(url: url))
    }

    // MARK: - hasUnsavedChanges / dirtyTabs

    @Test func hasUnsavedChanges_false_whenClean() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        #expect(!manager.hasUnsavedChanges)
        #expect(manager.dirtyTabs.isEmpty)
    }

    @Test func hasUnsavedChanges_true_whenDirty() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        manager.updateContent("changed")
        #expect(manager.hasUnsavedChanges)
        #expect(manager.dirtyTabs.count == 1)
    }

    // MARK: - tabsAffectedByDeletion

    @Test func tabsAffectedByDeletion_exactMatch() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir)
        manager.openTab(url: url)
        let affected = manager.tabsAffectedByDeletion(url: url)
        #expect(affected.count == 1)
    }

    @Test func tabsAffectedByDeletion_childOfDirectory() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true
        )
        let childURL = dir.appendingPathComponent("subdir/child.swift")
        try? "test".write(to: childURL, atomically: true, encoding: .utf8)
        manager.openTab(url: childURL)

        let affected = manager.tabsAffectedByDeletion(url: dir.appendingPathComponent("subdir"))
        #expect(affected.count == 1)
    }

    // MARK: - contentPreparedForSave

    @Test func contentPreparedForSave_allDisabled() {
        let suite = "TestSuite-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = false
        settings.insertFinalNewline = false
        settings.formatOnSave = false

        let result = TabManager.contentPreparedForSave("hello  \n", settings: settings)
        #expect(result == "hello  \n")
    }

    @Test func contentPreparedForSave_stripWhitespace() {
        let suite = "TestSuite-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = true
        settings.insertFinalNewline = false

        let result = TabManager.contentPreparedForSave("hello   \n", settings: settings)
        #expect(result == "hello\n")
    }

    @Test func contentPreparedForSave_insertNewline() {
        let suite = "TestSuite-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = false
        settings.insertFinalNewline = true

        let result = TabManager.contentPreparedForSave("hello", settings: settings)
        #expect(result == "hello\n")
    }

    // MARK: - Markdown preview toggle

    @Test func togglePreviewMode_nonMarkdown_noOp() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir, name: "test.swift")
        manager.openTab(url: url)
        manager.togglePreviewMode()
    }

    // MARK: - openTabAndGoToLine

    @Test func openTabAndGoToLine_setsPendingLine() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = tempFile(in: dir, content: "line1\nline2\nline3")
        manager.openTabAndGoToLine(url: url, line: 2)
        #expect(manager.pendingGoToLine == 2)
    }

    // MARK: - Auto-save

    @Test func autoSaveDelay_default() {
        let manager = makeTabManager()
        #expect(manager.autoSaveDelay == 1.0)
    }

    @Test func setAutoSaveDelay() {
        let manager = makeTabManager()
        manager.setAutoSaveDelay(0.5)
        #expect(manager.autoSaveDelay == 0.5)
    }

    @Test func cancelAutoSave() {
        let manager = makeTabManager()
        manager.cancelAutoSave()
        #expect(!manager.hasScheduledAutoSave)
    }
}
