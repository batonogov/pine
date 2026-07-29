//
//  TabManagerEdgeTests.swift
//  PineTests
//

import AppKit
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
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabMgrEdge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempFile(
        in dir: URL,
        name: String = "test.swift",
        content: String = "hello"
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: - Tab navigation

    @Test func selectTab_validIndex() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.selectTab(at: 0)
        #expect(manager.activeTab?.url == url1)
    }

    @Test func selectTab_negativeIndex_noOp() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: try tempFile(in: dir))
        let id = manager.activeTabID
        manager.selectTab(at: -1)
        #expect(manager.activeTabID == id)
    }

    @Test func selectTab_outOfBounds_noOp() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: try tempFile(in: dir))
        let id = manager.activeTabID
        manager.selectTab(at: 100)
        #expect(manager.activeTabID == id)
    }

    @Test func selectLastTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        let url3 = try tempFile(in: dir, name: "c.swift")
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

    @Test func selectNextTab_wraps() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
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

    @Test func selectPreviousTab_wraps() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
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

    @Test func togglePin_pinsTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        #expect(manager.activeTab?.isPinned == true)
        #expect(manager.pinnedTabCount == 1)
    }

    @Test func togglePin_unpinsTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.togglePin(id: id)
        #expect(manager.activeTab?.isPinned == false)
        #expect(manager.pinnedTabCount == 0)
    }

    @Test func pinnedTab_resistsClose() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.closeTab(id: id)
        #expect(manager.tabs.count == 1)
    }

    @Test func pinnedTab_closesWhenForced() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        guard let id = manager.activeTabID else { return }

        manager.togglePin(id: id)
        manager.closeTab(id: id, force: true)
        #expect(manager.tabs.isEmpty)
    }

    @Test func restorePinnedState() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.restorePinnedState(pinnedPaths: [url1.path])
        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[1].isPinned == false)
    }

    // MARK: - Close operations

    @Test func closeOtherTabs_keepsPinnedAndTarget() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        let url3 = try tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        let id1 = manager.tabs[0].id
        manager.togglePin(id: manager.tabs[1].id)

        manager.closeOtherTabs(keeping: id1, force: true)
        #expect(manager.tabs.count == 2)
    }

    @Test func closeTabsToTheRight() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        let url3 = try tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        let id1 = manager.tabs[0].id
        manager.closeTabsToTheRight(of: id1, force: true)
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == url1)
    }

    @Test func closeTabsToTheRight_pinnedPreserved() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        let url3 = try tempFile(in: dir, name: "c.swift")
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

    @Test func closeAllTabs_force() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        manager.openTab(url: try tempFile(in: dir, name: "a.swift"))
        manager.openTab(url: try tempFile(in: dir, name: "b.swift"))

        manager.closeAllTabs(force: true)
        #expect(manager.tabs.isEmpty)
    }

    @Test func dirtyTabsForCloseOthers() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseOthers(keeping: manager.tabs[0].id)
        #expect(dirty.count == 1)
    }

    @Test func dirtyTabsForCloseRight() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseRight(of: manager.tabs[0].id)
        #expect(dirty.count == 1)
    }

    @Test func dirtyTabsForCloseAll() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        manager.updateContent("changed")

        let dirty = manager.dirtyTabsForCloseAll()
        #expect(dirty.count == 1)
    }

    // MARK: - Tab reordering

    @Test func reorderTab_swapsPositions() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)

        let id1 = manager.tabs[0].id
        let id2 = manager.tabs[1].id
        manager.reorderTab(draggedID: id1, targetID: id2)

        #expect(manager.tabs[0].id == id2 && manager.tabs[1].id == id1)
    }

    @Test func reorderTab_sameID_noOp() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        let id = manager.tabs[0].id

        manager.reorderTab(draggedID: id, targetID: id)
        #expect(manager.tabs.count == 1)
    }

    @Test func reorderTab_pinnedToUnpinned_blocked() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
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

    @Test func moveTab_fromOffsets() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url1 = try tempFile(in: dir, name: "a.swift")
        let url2 = try tempFile(in: dir, name: "b.swift")
        let url3 = try tempFile(in: dir, name: "c.swift")
        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        manager.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(manager.tabs[0].url == url3)
    }

    // MARK: - Line endings

    @Test func convertActiveTabLineEndings_changesToCRLF() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir, content: "line1\nline2\n")
        manager.openTab(url: url)
        manager.convertActiveTabLineEndings(to: .crlf)
        #expect(manager.activeTab?.content.contains("\r\n") == true)
    }

    @Test func convertActiveTabLineEndings_noChangeIfSame() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir, content: "line1\nline2\n")
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

    @Test func handleFileRenamed_updatesURL() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let oldURL = try tempFile(in: dir, name: "old.swift")
        manager.openTab(url: oldURL)

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("new.swift")
        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs[0].url == newURL)
    }

    @Test func handleFileRenamed_updatesChildPaths() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("oldDir"), withIntermediateDirectories: true
        )
        let childURL = dir.appendingPathComponent("oldDir/child.swift")
        try "test".write(to: childURL, atomically: true, encoding: .utf8)
        manager.openTab(url: childURL)

        let oldDir = dir.appendingPathComponent("oldDir")
        let newDir = dir.appendingPathComponent("newDir")
        manager.handleFileRenamed(oldURL: oldDir, newURL: newDir)

        #expect(manager.tabs[0].url.path.contains("newDir"))
    }

    // MARK: - Update operations

    @Test func updateFoldState() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)

        let foldState = FoldState()
        manager.updateFoldState(foldState)
        #expect(manager.activeTab?.foldState != nil)
    }

    @Test func updateEditorState() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir, content: "line1\nline2\n")
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

    @Test func hasUnsavedChanges_false_whenClean() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        #expect(!manager.hasUnsavedChanges)
        #expect(manager.dirtyTabs.isEmpty)
    }

    @Test func hasUnsavedChanges_true_whenDirty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        manager.updateContent("changed")
        #expect(manager.hasUnsavedChanges)
        #expect(manager.dirtyTabs.count == 1)
    }

    // MARK: - tabsAffectedByDeletion

    @Test func tabsAffectedByDeletion_exactMatch() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir)
        manager.openTab(url: url)
        let affected = manager.tabsAffectedByDeletion(url: url)
        #expect(affected.count == 1)
    }

    @Test func tabsAffectedByDeletion_childOfDirectory() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true
        )
        let childURL = dir.appendingPathComponent("subdir/child.swift")
        try "test".write(to: childURL, atomically: true, encoding: .utf8)
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

        let result = TabManager.contentPreparedForSave(
            "hello  \n",
            url: URL(fileURLWithPath: "/dev/null"),
            settings: settings,
            formatters: FileFormatterRegistry(formatters: [])
        )
        #expect(result == "hello  \n")
    }

    @Test func contentPreparedForSave_stripWhitespace() {
        let suite = "TestSuite-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = true
        settings.insertFinalNewline = false

        let result = TabManager.contentPreparedForSave(
            "hello   \n",
            url: URL(fileURLWithPath: "/dev/null"),
            settings: settings,
            formatters: FileFormatterRegistry(formatters: [])
        )
        #expect(result == "hello\n")
    }

    @Test func contentPreparedForSave_insertNewline() {
        let suite = "TestSuite-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = false
        settings.insertFinalNewline = true

        let result = TabManager.contentPreparedForSave(
            "hello",
            url: URL(fileURLWithPath: "/dev/null"),
            settings: settings,
            formatters: FileFormatterRegistry(formatters: [])
        )
        #expect(result == "hello\n")
    }

    // MARK: - Markdown preview toggle

    @Test func togglePreviewMode_nonMarkdown_noOp() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir, name: "test.swift")
        manager.openTab(url: url)
        manager.togglePreviewMode()
    }

    // MARK: - openTabAndGoToLine

    @Test func openTabAndGoToLine_setsPendingLine() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(in: dir, content: "line1\nline2\nline3")
        manager.openTabAndGoToLine(url: url, line: 2)
        #expect(manager.pendingGoToLine == 2)
    }

    @Test func openTabAndGoToLine_cancelledLargeFileDoesNotRouteLine() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let content = String(
            repeating: "a",
            count: TabManager.largeFileThreshold + 1
        )
        let url = try tempFile(in: dir, content: content)
        manager.pendingGoToLine = 99
        var completionResult: TabManager.OpenRequestResult?

        let request = manager.openTabAndGoToLine(
            url: url,
            line: 2,
            context: DialogPresentationContext.unscoped,
            completion: { completionResult = $0 }
        )
        #expect(request == .pending)
        #expect(await waitUntil { completionResult != nil })

        #expect(manager.tabs.isEmpty)
        #expect(manager.pendingGoToLine == nil)
        #expect(completionResult == .cancelled)
    }

    @Test func explicitLargeFileOpenUpgradesQueuedPreviewAndRoutesLine() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let content = String(
            repeating: "a",
            count: TabManager.largeFileThreshold + 1
        )
        let url = try tempFile(in: dir, content: content)
        let (responses, responseContinuation) = AsyncStream.makeStream(
            of: NSApplication.ModalResponse.self
        )
        var presentationCount = 0
        var completionResults: [TabManager.OpenRequestResult] = []
        manager.largeFileAlertPresenter = { _, _, _ in
            presentationCount += 1
            for await response in responses {
                return response
            }
            return .abort
        }

        let previewRequest = manager.openTabAsPreview(
            url: url,
            context: DialogPresentationContext.unscoped,
            completion: { completionResults.append($0) }
        )
        let explicitRequest = manager.openTabAndGoToLine(
            url: url,
            line: 7,
            context: DialogPresentationContext.unscoped,
            completion: { completionResults.append($0) }
        )

        #expect(previewRequest == .pending)
        #expect(explicitRequest == .pending)
        #expect(manager.tabs.isEmpty)
        #expect(manager.pendingGoToLine == nil)
        responseContinuation.yield(.alertSecondButtonReturn)
        responseContinuation.finish()
        #expect(await waitUntil { !manager.tabs.isEmpty })

        let openedTab = try #require(manager.activeTab)
        #expect(manager.tabs.count == 1)
        #expect(openedTab.url == url)
        #expect(openedTab.isTransientPreview == false)
        #expect(openedTab.syntaxHighlightingDisabled == false)
        #expect(manager.pendingGoToLine == 7)
        #expect(presentationCount == 1)
        #expect(
            completionResults == [
                .opened(tabID: openedTab.id),
                .opened(tabID: openedTab.id)
            ]
        )
    }

    @Test func lspLargeFileNavigationWaitsForOpenAndPreservesLocation() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let sourceURL = try tempFile(
            in: dir,
            name: "source.swift",
            content: "let source = true"
        )
        manager.openTab(url: sourceURL)
        let sourceTabID = try #require(manager.activeTabID)
        let targetLine = "😀target\n"
        let targetURL = try tempFile(
            in: dir,
            name: "definition.swift",
            content: String(
                repeating: targetLine,
                count: (TabManager.largeFileThreshold / 11) + 1
            )
        )
        let (responses, responseContinuation) = AsyncStream.makeStream(
            of: NSApplication.ModalResponse.self
        )
        var completionResult: TabManager.OpenRequestResult?
        manager.largeFileAlertPresenter = { _, _, _ in
            for await response in responses {
                return response
            }
            return .abort
        }

        let request = PaneLeafView.openLSPFile(
            url: targetURL,
            line: 0,
            character: 2,
            in: manager,
            completion: { completionResult = $0 }
        )

        #expect(request == .pending)
        #expect(manager.activeTabID == sourceTabID)
        #expect(manager.pendingGoToLocation == nil)

        responseContinuation.yield(.alertSecondButtonReturn)
        responseContinuation.finish()
        #expect(await waitUntil { completionResult != nil })

        let targetTabID = try #require(manager.activeTabID)
        #expect(manager.activeTab?.url == targetURL)
        #expect(
            manager.pendingGoToLocation ==
                EditorNavigationLocation(line: 1, column: 3)
        )
        #expect(completionResult == .opened(tabID: targetTabID))
        #expect(
            ContentView.cursorOffset(
                forLine: 1,
                column: 3,
                in: manager.activeTab?.content ?? ""
            ) == 2
        )
    }

    @Test func lspImmediateNavigationUsesUTF16CharacterOffsets() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let content = "😀x\nsecond"
        let url = try tempFile(
            in: dir,
            name: "emoji.swift",
            content: content
        )

        let result = PaneLeafView.openLSPFile(
            url: url,
            line: 0,
            character: 2,
            in: manager
        )

        let activeTabID = try #require(manager.activeTabID)
        #expect(result == .opened(tabID: activeTabID))
        #expect(
            manager.pendingGoToLocation ==
                EditorNavigationLocation(line: 1, column: 3)
        )
        #expect(
            ContentView.cursorOffset(
                forLine: 1,
                column: 3,
                in: content
            ) == 2
        )
    }

    @Test func lspCancelledLargeFileDoesNotRouteOrChangeSelection() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let sourceURL = try tempFile(
            in: dir,
            name: "source.swift",
            content: "let source = true"
        )
        manager.openTab(url: sourceURL)
        let sourceTabID = try #require(manager.activeTabID)
        let targetURL = try tempFile(
            in: dir,
            name: "cancelled.swift",
            content: String(
                repeating: "x",
                count: TabManager.largeFileThreshold + 1
            )
        )
        let (responses, responseContinuation) = AsyncStream.makeStream(
            of: NSApplication.ModalResponse.self
        )
        var presentationCount = 0
        var completionResult: TabManager.OpenRequestResult?
        manager.largeFileAlertPresenter = { _, _, _ in
            presentationCount += 1
            for await response in responses {
                return response
            }
            return .abort
        }

        let result = PaneLeafView.openLSPFile(
            url: targetURL,
            line: 4,
            character: 7,
            in: manager,
            completion: { completionResult = $0 }
        )

        #expect(result == .pending)
        #expect(await waitUntil { presentationCount == 1 })
        #expect(manager.activeTabID == sourceTabID)
        #expect(manager.pendingGoToLocation == nil)

        responseContinuation.yield(.abort)
        responseContinuation.finish()
        #expect(await waitUntil { completionResult != nil })
        #expect(completionResult == .cancelled)
        #expect(manager.activeTabID == sourceTabID)
        #expect(manager.pendingGoToLocation == nil)
        #expect(!manager.tabs.contains { $0.url == targetURL })
    }

    @Test func lspCoordinatesClampNegativeAndSaturateAtIntMax() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = makeTabManager()
        let url = try tempFile(
            in: dir,
            name: "extreme.swift",
            content: "value"
        )

        _ = PaneLeafView.openLSPFile(
            url: url,
            line: .max,
            character: .max,
            in: manager
        )
        #expect(
            manager.pendingGoToLocation ==
                EditorNavigationLocation(line: .max, column: .max)
        )

        _ = PaneLeafView.openLSPFile(
            url: url,
            line: -1,
            character: .min,
            in: manager
        )
        #expect(
            manager.pendingGoToLocation ==
                EditorNavigationLocation(line: 1, column: 1)
        )
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
