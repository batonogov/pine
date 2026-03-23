//
//  TabManagerTests.swift
//  PineTests
//
//  Created by Claude on 12.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("TabManager Tests")
struct TabManagerTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Open tab loads content and activates it")
    func openTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "let x = 1")

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == url)
        #expect(manager.activeTab?.content == "let x = 1")
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("Open duplicate tab activates existing tab")
    func openDuplicateTab() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        let firstID = manager.activeTabID

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTabID == firstID)
    }

    @Test("Close tab selects adjacent tab")
    func closeTabSelectsAdjacent() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Active is url3 (last opened). Close it.
        guard let closedID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        manager.closeTab(id: closedID)

        #expect(manager.tabs.count == 2)
        // Should select the tab at the same index (clamped), which is url2
        #expect(manager.activeTab?.url == url2)
    }

    @Test("Close last remaining tab clears activeTabID")
    func closeLastTab() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        manager.closeTab(id: tabID)

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTabID == nil)
    }

    @Test("Update content marks tab as dirty")
    func updateContentMarksDirty() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        #expect(manager.activeTab?.isDirty == false)

        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)
        #expect(manager.activeTab?.content == "modified")
    }

    @Test("Save tab writes to disk and clears dirty state")
    func saveTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)

        let success = manager.saveActiveTab()
        #expect(success == true)
        #expect(manager.activeTab?.isDirty == false)

        // Verify file on disk
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "modified")
    }

    @Test("trySaveTab throws for non-writable path and leaves tab dirty")
    func saveTabFailsForBadPath() {
        let manager = TabManager()
        let badURL = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)/file.txt")

        let tab = EditorTab(url: badURL, content: "data", savedContent: "")
        manager.tabs.append(tab)
        manager.activeTabID = tab.id

        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }
        // Tab must remain dirty after failed save
        #expect(manager.activeTab?.isDirty == true)
        #expect(manager.activeTab?.content == "data")
    }

    @Test("Handle file renamed updates tab URL preserving identity")
    func handleFileRenamed() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldURL = dir.appendingPathComponent("old.swift")
        let newURL = dir.appendingPathComponent("new.swift")
        try? "content".write(to: oldURL, atomically: true, encoding: .utf8)

        manager.openTab(url: oldURL)
        let originalID = manager.activeTabID

        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == newURL)
        // Tab identity (UUID) must be preserved — no new tab created
        #expect(manager.activeTabID == originalID)
    }

    @Test("Rename updates inactive tab without changing activeTabID target")
    func renameInactiveTab() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = dir.appendingPathComponent("b.swift")
        let renamedFile1 = dir.appendingPathComponent("a_renamed.swift")
        try? "x".write(to: file1, atomically: true, encoding: .utf8)
        try? "y".write(to: file2, atomically: true, encoding: .utf8)

        manager.openTab(url: file1)
        manager.openTab(url: file2) // file2 is now active

        let activeURL = manager.activeTab?.url
        manager.handleFileRenamed(oldURL: file1, newURL: renamedFile1)

        // Active tab should still be file2
        #expect(manager.activeTab?.url == activeURL)
        // Renamed tab should have new URL
        #expect(manager.tabs[0].url == renamedFile1)
    }

    @Test("Tabs affected by deletion")
    func tabsAffectedByDeletion() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subdir = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = subdir.appendingPathComponent("b.swift")
        let file3 = dir.appendingPathComponent("c.swift")
        for f in [file1, file2, file3] {
            try? "x".write(to: f, atomically: true, encoding: .utf8)
        }

        manager.openTab(url: file1)
        manager.openTab(url: file2)
        manager.openTab(url: file3)

        // Deleting the subdir should affect file2
        let affected = manager.tabsAffectedByDeletion(url: subdir)
        #expect(affected.count == 1)
        #expect(affected.first?.url == file2)
    }

    @Test("Close tabs for deleted file removes affected tabs")
    func closeTabsForDeletedFile() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = dir.appendingPathComponent("b.swift")
        try? "x".write(to: file1, atomically: true, encoding: .utf8)
        try? "y".write(to: file2, atomically: true, encoding: .utf8)

        manager.openTab(url: file1)
        manager.openTab(url: file2)
        #expect(manager.tabs.count == 2)

        manager.closeTabsForDeletedFile(url: file1)
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == file2)
    }

    @Test("hasUnsavedChanges reflects dirty state")
    func hasUnsavedChanges() {
        let manager = TabManager()
        let url = tempFileURL(content: "clean")

        manager.openTab(url: url)
        #expect(manager.hasUnsavedChanges == false)

        manager.updateContent("dirty")
        #expect(manager.hasUnsavedChanges == true)
    }

    @Test("Move tab reorders correctly")
    func moveTab() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Move first tab to end
        manager.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(manager.tabs[0].url == url2)
        #expect(manager.tabs[1].url == url3)
        #expect(manager.tabs[2].url == url1)
    }

    @Test("Close non-active tab preserves activeTabID")
    func closeNonActiveTabPreservesActive() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // url3 is active; close url1 (non-active)
        let url1ID = manager.tabs[0].id
        manager.closeTab(id: url1ID)

        #expect(manager.tabs.count == 2)
        #expect(manager.activeTab?.url == url3) // active unchanged
    }

    @Test("Tab for URL returns correct tab")
    func tabForURL() {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)

        #expect(manager.tab(for: url)?.url == url)
        #expect(manager.tab(for: URL(fileURLWithPath: "/no-such-file")) == nil)
    }

    @Test("Update editor state persists cursor and scroll")
    func updateEditorState() {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)

        #expect(manager.activeTab?.cursorPosition == 0)
        #expect(manager.activeTab?.scrollOffset == 0)

        manager.updateEditorState(cursorPosition: 42, scrollOffset: 128.5)

        #expect(manager.activeTab?.cursorPosition == 42)
        #expect(manager.activeTab?.scrollOffset == 128.5)
    }

    @Test("Cursor position uses UTF-16 semantics consistent with NSRange")
    func cursorPositionUTF16Semantics() {
        let manager = TabManager()
        // 🎉 is a single Swift Character but 2 UTF-16 code units
        let emojiContent = "🎉 hello"
        let url = tempFileURL(content: emojiContent)

        manager.openTab(url: url)

        // Simulate NSTextView placing cursor after "🎉 " (4 UTF-16 units: 2 for emoji + 1 space + next char)
        let nsLength = (emojiContent as NSString).length
        let swiftCount = emojiContent.count
        // Verify the premise: these differ for emoji content
        #expect(nsLength != swiftCount, "emoji content should have different NSString.length vs Character count")
        #expect(nsLength == 8) // 🎉(2) + " "(1) + "hello"(5)
        #expect(swiftCount == 7) // 🎉(1) + " "(1) + "hello"(5)

        // Store a cursor position that's valid in UTF-16 but > Character count
        // (e.g. cursor at end of string in NSTextView terms)
        manager.updateEditorState(cursorPosition: nsLength, scrollOffset: 0)
        #expect(manager.activeTab?.cursorPosition == nsLength)

        // The restore clamp in CodeEditorView uses (text as NSString).length,
        // so nsLength should be within bounds. If it used text.count, this
        // position would be incorrectly clamped to 7 instead of 8.
        let restoredPosition = min(nsLength, (emojiContent as NSString).length)
        #expect(restoredPosition == nsLength)

        // Verify the bug scenario: clamping via text.count would truncate
        let brokenPosition = min(nsLength, swiftCount)
        #expect(brokenPosition != nsLength, "text.count clamp would lose cursor position on emoji content")
    }

    // MARK: - Save All

    @Test("Save all tabs saves every dirty tab")
    func saveAllTabs() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")
        let url3 = tempFileURL(name: "c.swift", content: "original3")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Make first and third dirty
        manager.activeTabID = manager.tabs[0].id
        manager.updateContent("modified1")
        manager.activeTabID = manager.tabs[2].id
        manager.updateContent("modified3")

        #expect(manager.dirtyTabs.count == 2)

        try manager.trySaveAllTabs()
        #expect(manager.hasUnsavedChanges == false)

        // Verify disk contents
        let disk1 = try? String(contentsOf: url1, encoding: .utf8)
        let disk2 = try? String(contentsOf: url2, encoding: .utf8)
        let disk3 = try? String(contentsOf: url3, encoding: .utf8)
        #expect(disk1 == "modified1")
        #expect(disk2 == "original2") // was clean — should not be rewritten
        #expect(disk3 == "modified3")
    }

    @Test("Save all tabs throws on first failure")
    func saveAllTabsStopsOnFailure() {
        let manager = TabManager()
        let goodURL = tempFileURL(name: "good.swift", content: "original")
        let badURL = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)/bad.swift")

        manager.openTab(url: goodURL)
        // Manually add bad tab
        let badTab = EditorTab(url: badURL, content: "data", savedContent: "")
        manager.tabs.append(badTab)

        // Make good tab dirty
        manager.activeTabID = manager.tabs[0].id
        manager.updateContent("modified")

        #expect(manager.dirtyTabs.count == 2)

        #expect(throws: (any Error).self) {
            try manager.trySaveAllTabs()
        }
        // At least one tab should still be dirty (the bad one)
        #expect(manager.hasUnsavedChanges == true)
    }

    @Test("Save all tabs succeeds when no dirty tabs")
    func saveAllTabsNoDirtyTabs() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "clean")
        manager.openTab(url: url)

        try manager.trySaveAllTabs()
        #expect(manager.hasUnsavedChanges == false)
    }

    // MARK: - Dirty Tabs

    @Test("dirtyTabs returns only modified tabs")
    func dirtyTabsFiltering() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "clean.swift", content: "clean")
        let url2 = tempFileURL(name: "dirty.swift", content: "original")

        manager.openTab(url: url1)
        manager.openTab(url: url2)

        // Make only url2 dirty
        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("changed")

        let dirty = manager.dirtyTabs
        #expect(dirty.count == 1)
        #expect(dirty[0].url == url2)
    }

    // MARK: - Save As

    @Test("Save tab as writes to new URL and updates tab")
    func saveTabAs() throws {
        let manager = TabManager()
        let url = tempFileURL(name: "original.swift", content: "hello")
        manager.openTab(url: url)
        manager.updateContent("modified content")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newURL = dir.appendingPathComponent("saved_as.swift")

        let success = try manager.saveActiveTabAs(to: newURL)
        #expect(success == true)

        // Tab URL should be updated
        #expect(manager.activeTab?.url == newURL)
        // Tab should be clean
        #expect(manager.activeTab?.isDirty == false)
        // Content on disk at new URL
        let onDisk = try String(contentsOf: newURL, encoding: .utf8)
        #expect(onDisk == "modified content")
        // Tab identity preserved
        #expect(manager.tabs.count == 1)
    }

    @Test("Save tab as preserves tab identity (UUID)")
    func saveTabAsPreservesIdentity() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "data")
        manager.openTab(url: url)
        let originalID = manager.activeTabID

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newURL = dir.appendingPathComponent("new.swift")

        try manager.saveActiveTabAs(to: newURL)

        #expect(manager.activeTabID == originalID)
    }

    @Test("Save tab as throws for non-writable path")
    func saveTabAsFailsForBadPath() {
        let manager = TabManager()
        let url = tempFileURL(content: "data")
        manager.openTab(url: url)

        let badURL = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)/file.swift")

        #expect(throws: (any Error).self) {
            try manager.saveActiveTabAs(to: badURL)
        }
        // Tab should remain at original URL
        #expect(manager.activeTab?.url == url)
    }

    // MARK: - Duplicate

    @Test("Duplicate active tab creates copy with Finder naming")
    func duplicateActiveTab() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.swift")
        try "content".write(to: url, atomically: true, encoding: .utf8)

        manager.openTab(url: url)
        let originalID = manager.activeTabID

        let duplicated = manager.duplicateActiveTab()
        #expect(duplicated == true)

        // Should have 2 tabs now
        #expect(manager.tabs.count == 2)
        // Active tab should be the duplicate
        #expect(manager.activeTabID != originalID)
        // Duplicate URL should follow Finder naming: "file copy.swift"
        #expect(manager.activeTab?.url.lastPathComponent == "file copy.swift")
        // Duplicate should have same content
        #expect(manager.activeTab?.content == "content")
        // Duplicate should be clean (saved to disk)
        #expect(manager.activeTab?.isDirty == false)
        // File should exist on disk
        if let activeTab = manager.activeTab {
            #expect(FileManager.default.fileExists(atPath: activeTab.url.path))
        } else {
            Issue.record("activeTab should not be nil after duplicate")
        }
    }

    @Test("Duplicate uses incremented name when copy exists")
    func duplicateActiveTabIncrementsName() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.swift")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        // Create "file copy.swift" so the first name is taken
        let copyURL = dir.appendingPathComponent("file copy.swift")
        try "existing".write(to: copyURL, atomically: true, encoding: .utf8)

        manager.openTab(url: url)
        let duplicated = manager.duplicateActiveTab()
        #expect(duplicated == true)
        #expect(manager.activeTab?.url.lastPathComponent == "file copy 2.swift")
    }

    @Test("Duplicate file without extension uses Finder naming")
    func duplicateFileWithoutExtension() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Makefile")
        try "all:".write(to: url, atomically: true, encoding: .utf8)

        manager.openTab(url: url)
        let duplicated = manager.duplicateActiveTab()
        #expect(duplicated == true)
        #expect(manager.activeTab?.url.lastPathComponent == "Makefile copy")
    }

    @Test("Duplicate returns false when no active tab")
    func duplicateNoActiveTab() {
        let manager = TabManager()
        let result = manager.duplicateActiveTab()
        #expect(result == false)
    }

    @Test("tryDuplicateActiveTab succeeds and creates copy")
    func tryDuplicateActiveTabSuccess() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.swift")
        try "content".write(to: url, atomically: true, encoding: .utf8)

        manager.openTab(url: url)
        let originalID = manager.activeTabID

        let success = try manager.tryDuplicateActiveTab()
        #expect(success == true)
        #expect(manager.tabs.count == 2)
        #expect(manager.activeTabID != originalID)
        #expect(manager.activeTab?.url.lastPathComponent == "file copy.swift")
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("tryDuplicateActiveTab throws for non-writable path")
    func duplicateActiveTabThrowsForBadPath() {
        let manager = TabManager()
        let badDir = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)")
        let badURL = badDir.appendingPathComponent("file.swift")

        let tab = EditorTab(url: badURL, content: "data", savedContent: "data")
        manager.tabs.append(tab)
        manager.activeTabID = tab.id

        #expect(throws: (any Error).self) {
            try manager.tryDuplicateActiveTab()
        }
        // Original tab should remain unchanged
        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == badURL)
    }

    @Test("tryDuplicateActiveTab blocks files outside project root")
    func duplicateActiveTabBlockedOutsideRoot() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabMgrProject-\(UUID().uuidString)")
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabMgrOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let outsideFile = outsideDir.appendingPathComponent("secret.txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: outsideFile)

        #expect(throws: (any Error).self) {
            try manager.tryDuplicateActiveTab(projectRoot: projectDir)
        }
        // No copy should exist
        let copyPath = outsideDir.appendingPathComponent("secret copy.txt").path
        #expect(FileManager.default.fileExists(atPath: copyPath) == false)
    }

    // MARK: - Preview file detection

    @Test("isPreviewFile returns true for images")
    func isPreviewFileImages() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("photo.png")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("image.jpg")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("icon.gif")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("icon.webp")) == true)
    }

    @Test("isPreviewFile returns true for PDF and fonts")
    func isPreviewFilePDFAndFonts() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("doc.pdf")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("font.ttf")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("font.otf")) == true)
    }

    @Test("isPreviewFile returns true for audio and video")
    func isPreviewFileAudioVideo() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("song.mp3")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("video.mp4")) == true)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("movie.mov")) == true)
    }

    @Test("isPreviewFile returns false for text and source code")
    func isPreviewFileTextFiles() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("main.swift")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("readme.txt")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("config.json")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("style.css")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("index.html")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("app.js")) == false)
    }

    @Test("isPreviewFile returns false for files with no extension")
    func isPreviewFileNoExtension() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("Makefile")) == false)
    }

    @Test("isPreviewFile returns false for unrecognized plain-text extensions")
    func isPreviewFileUnrecognizedExtensions() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("main.go")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("go.mod")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("go.sum")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("coverage.out")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("Cargo.toml")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("Cargo.lock")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent(".gitignore")) == false)
        #expect(manager.isPreviewFile(url: dir.appendingPathComponent("Dockerfile")) == false)
    }

    @Test("openTab for image creates preview tab")
    func openTabPreviewFile() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.png")
        // Create a minimal PNG file (1x1 pixel)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try? pngData.write(to: url)

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.kind == .preview)
        #expect(manager.activeTab?.isDirty == false)
        #expect(manager.activeTab?.content == "")
    }

    @Test("Preview tabs are never dirty")
    func previewTabNeverDirty() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.png"), kind: .preview)
        #expect(tab.isDirty == false)
    }

    // MARK: - Markdown preview mode

    @Test("Toggle preview mode cycles for markdown file")
    func togglePreviewModeCyclesForMarkdown() {
        let manager = TabManager()
        let url = tempFileURL(name: "readme.md", content: "# Hello")

        manager.openTab(url: url)
        #expect(manager.activeTab?.previewMode == .source)

        manager.togglePreviewMode()
        #expect(manager.activeTab?.previewMode == .split)

        manager.togglePreviewMode()
        #expect(manager.activeTab?.previewMode == .preview)

        manager.togglePreviewMode()
        #expect(manager.activeTab?.previewMode == .source)
    }

    @Test("Toggle preview mode ignores non-markdown file")
    func togglePreviewModeIgnoresNonMarkdown() {
        let manager = TabManager()
        let url = tempFileURL(name: "main.swift", content: "let x = 1")

        manager.openTab(url: url)
        #expect(manager.activeTab?.previewMode == .source)

        manager.togglePreviewMode()
        #expect(manager.activeTab?.previewMode == .source)
    }

    @Test("Preview mode preserved across tab switch")
    func previewModePreservedAcrossTabSwitch() {
        let manager = TabManager()
        let mdURL = tempFileURL(name: "readme.md", content: "# Hello")
        let swiftURL = tempFileURL(name: "main.swift", content: "let x = 1")

        manager.openTab(url: mdURL)
        manager.togglePreviewMode() // → split
        #expect(manager.activeTab?.previewMode == .split)

        manager.openTab(url: swiftURL)
        #expect(manager.activeTab?.url == swiftURL)

        // Switch back to markdown tab
        manager.activeTabID = manager.tabs[0].id
        #expect(manager.activeTab?.previewMode == .split)
    }

    // MARK: - Large file detection

    @Test("isLargeFile returns true for files >= 1 MB")
    func isLargeFileAboveThreshold() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("large.log")
        // Create a file exactly at the threshold (1 MB)
        let data = Data(count: TabManager.largeFileThreshold)
        try data.write(to: url)

        #expect(manager.isLargeFile(url: url) == true)
    }

    @Test("isLargeFile returns false for files < 1 MB")
    func isLargeFileBelowThreshold() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("small.swift")
        let data = Data(count: TabManager.largeFileThreshold - 1)
        try data.write(to: url)

        #expect(manager.isLargeFile(url: url) == false)
    }

    @Test("isLargeFile returns false for nonexistent file")
    func isLargeFileNonexistent() {
        let manager = TabManager()
        let url = URL(fileURLWithPath: "/nonexistent_\(UUID().uuidString)/file.txt")
        #expect(manager.isLargeFile(url: url) == false)
    }

    @Test("Open small file has syntaxHighlightingDisabled == false")
    func openSmallFileHasHighlighting() {
        let manager = TabManager()
        let url = tempFileURL(content: "let x = 1")

        manager.openTab(url: url)

        #expect(manager.activeTab?.syntaxHighlightingDisabled == false)
    }

    @Test("EditorTab with syntaxHighlightingDisabled creates correctly")
    func editorTabWithDisabledHighlighting() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/large.log"), content: "data", savedContent: "data")
        tab.syntaxHighlightingDisabled = true

        #expect(tab.syntaxHighlightingDisabled == true)
        #expect(tab.isDirty == false)
    }

    @Test("Rename preserves editor state")
    func renamePreservesEditorState() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldURL = dir.appendingPathComponent("old.swift")
        let newURL = dir.appendingPathComponent("new.swift")
        try? "content".write(to: oldURL, atomically: true, encoding: .utf8)

        manager.openTab(url: oldURL)
        manager.updateEditorState(cursorPosition: 15, scrollOffset: 200)

        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.activeTab?.cursorPosition == 15)
        #expect(manager.activeTab?.scrollOffset == 200)
    }

    @Test("openTabAndGoToLine opens tab and sets pending line")
    func openTabAndGoToLine() {
        let manager = TabManager()
        let url = tempFileURL(content: "line 1\nline 2\nline 3")

        manager.openTabAndGoToLine(url: url, line: 3)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == url)
        #expect(manager.pendingGoToLine == 3)
    }

    @Test("openTabAndGoToLine on already open tab sets pending line")
    func openTabAndGoToLineExistingTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "line 1\nline 2")

        manager.openTab(url: url)
        #expect(manager.pendingGoToLine == nil)

        manager.openTabAndGoToLine(url: url, line: 2)
        #expect(manager.tabs.count == 1)
        #expect(manager.pendingGoToLine == 2)
    }

    // MARK: - Auto-save

    @Test("scheduleAutoSave saves dirty tab after delay")
    func autoSaveSavesDirtyTabAfterDelay() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.1)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)

        manager.scheduleAutoSave()

        // Wait for debounce + save
        try await Task.sleep(for: .milliseconds(300))

        #expect(manager.activeTab?.isDirty == false)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "modified")
    }

    @Test("scheduleAutoSave skips read-only file")
    func autoSaveSkipsReadOnlyFile() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.1)
        let url = tempFileURL(content: "original")

        // Make file read-only
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path
            )
        }

        manager.openTab(url: url)
        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)

        manager.scheduleAutoSave()

        try await Task.sleep(for: .milliseconds(300))

        // Should still be dirty — auto-save skipped
        #expect(manager.activeTab?.isDirty == true)
    }

    @Test("scheduleAutoSave debounces multiple rapid changes")
    func autoSaveDebounces() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.2)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)

        // Rapid changes — only the last one should be saved
        manager.updateContent("change1")
        manager.scheduleAutoSave()
        try await Task.sleep(for: .milliseconds(50))

        manager.updateContent("change2")
        manager.scheduleAutoSave()
        try await Task.sleep(for: .milliseconds(50))

        manager.updateContent("change3")
        manager.scheduleAutoSave()

        try await Task.sleep(for: .milliseconds(400))

        #expect(manager.activeTab?.isDirty == false)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "change3")
    }

    @Test("cancelAutoSave prevents pending save")
    func cancelAutoSavePreventsPlannedSave() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.2)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")

        manager.scheduleAutoSave()
        manager.cancelAutoSave()

        try await Task.sleep(for: .milliseconds(400))

        // Should still be dirty — auto-save was cancelled
        #expect(manager.activeTab?.isDirty == true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "original")
    }

    @Test("Auto-save handles tab switch — saves correct tab")
    func autoSaveHandlesTabSwitch() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.1)
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")

        manager.openTab(url: url1)
        manager.updateContent("modified1")

        // Schedule auto-save explicitly, then switch tab
        manager.scheduleAutoSave()

        manager.openTab(url: url2)

        try await Task.sleep(for: .milliseconds(300))

        // Tab 1 should have been saved
        let disk1 = try String(contentsOf: url1, encoding: .utf8)
        #expect(disk1 == "modified1")
        #expect(manager.tabs[0].isDirty == false)

        // Tab 2 should be untouched
        let disk2 = try String(contentsOf: url2, encoding: .utf8)
        #expect(disk2 == "original2")
    }

    @Test("Manual save cancels pending auto-save")
    func manualSaveCancelsAutoSave() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.3)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")

        manager.scheduleAutoSave()

        // Manual save should cancel the pending auto-save
        manager.saveActiveTab()
        #expect(manager.activeTab?.isDirty == false)
        #expect(manager.hasScheduledAutoSave == false)
    }

    @Test("closeTab cancels pending auto-save for that tab")
    func closeTabCancelsAutoSave() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.3)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")

        manager.scheduleAutoSave()
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        manager.closeTab(id: tabID)

        #expect(manager.hasScheduledAutoSave == false)
    }

    // MARK: - Strip trailing whitespace on save

    @Test("Save strips trailing whitespace from all lines")
    func saveStripsTrailingWhitespace() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("hello   \nworld\t\t\nfoo  bar  \n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "hello\nworld\nfoo  bar\n")
        #expect(manager.activeTab?.content == "hello\nworld\nfoo  bar\n")
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("Save preserves content with no trailing whitespace")
    func savePreservesCleanContent() {
        let manager = TabManager()
        let url = tempFileURL(content: "clean")

        manager.openTab(url: url)
        manager.updateContent("no trailing\nwhitespace here\n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "no trailing\nwhitespace here\n")
    }

    @Test("Save strips trailing whitespace but preserves empty lines")
    func savePreservesEmptyLines() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("line1  \n\nline3\t\n\n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "line1\n\nline3\n\n")
    }

    @Test("Save strips trailing whitespace with CRLF line endings")
    func saveStripsCRLF() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("hello   \r\nworld\t\r\n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "hello\r\nworld\r\n")
    }

    @Test("Save strips trailing whitespace — tabs and mixed spaces")
    func saveStripsMixedWhitespace() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("code \t \n\t  data  \t\n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "code\n\t  data\n")
    }

    @Test("trySaveTab also strips trailing whitespace")
    func trySaveTabStripsWhitespace() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("test   \n")

        try manager.trySaveTab(at: 0)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "test\n")
        #expect(manager.activeTab?.content == "test\n")
    }

    @Test("saveAllTabs strips trailing whitespace from all dirty tabs")
    func saveAllTabsStripsWhitespace() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")

        manager.openTab(url: url1)
        manager.updateContent("hello   \n")
        manager.openTab(url: url2)
        manager.updateContent("world\t\t\n")

        let success = manager.saveAllTabs()
        #expect(success == true)

        let disk1 = try? String(contentsOf: url1, encoding: .utf8)
        let disk2 = try? String(contentsOf: url2, encoding: .utf8)
        #expect(disk1 == "hello\n")
        #expect(disk2 == "world\n")
    }

    @Test("Failed save preserves original content with trailing whitespace")
    func failedSavePreservesContent() {
        let manager = TabManager()
        let badURL = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)/file.txt")

        let tab = EditorTab(url: badURL, content: "hello   \nworld\t\n", savedContent: "")
        manager.tabs.append(tab)
        manager.activeTabID = tab.id

        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }
        // Content must NOT be trimmed after failed write
        #expect(manager.activeTab?.content == "hello   \nworld\t\n")
        #expect(manager.activeTab?.isDirty == true)
    }

    @Test("Save As strips trailing whitespace")
    func saveAsStripsTrailingWhitespace() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")
        let dir = url.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent("saved_as.swift")

        manager.openTab(url: url)
        manager.updateContent("code   \nmore\t\n")

        try manager.saveActiveTabAs(to: newURL)

        let onDisk = try String(contentsOf: newURL, encoding: .utf8)
        #expect(onDisk == "code\nmore\n")
        #expect(manager.activeTab?.content == "code\nmore\n")
        #expect(manager.activeTab?.url == newURL)
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("Duplicate tab strips trailing whitespace")
    func duplicateStripsTrailingWhitespace() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.swift")
        try "hello".write(to: url, atomically: true, encoding: .utf8)

        manager.openTab(url: url)
        manager.updateContent("code   \nmore\t\n")
        // Save original first so duplicate reads current content
        manager.saveActiveTab()

        // Re-add trailing whitespace
        manager.updateContent("dup   \ntest\t\n")

        let duplicated = manager.duplicateActiveTab()
        #expect(duplicated == true)

        // The duplicate tab (now active) should have trimmed content
        guard let dupURL = manager.activeTab?.url else {
            Issue.record("activeTab should not be nil after duplicate")
            return
        }
        let onDisk = try String(contentsOf: dupURL, encoding: .utf8)
        #expect(onDisk == "dup\ntest\n")
        #expect(manager.activeTab?.content == "dup\ntest\n")
    }

    @Test("Strip trailing whitespace with mixed LF and CRLF")
    func stripMixedLineEndings() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("line1   \nline2\t\r\nline3  \n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "line1\nline2\r\nline3\n")
    }

    @Test("Save file with no trailing newline strips whitespace")
    func saveNoTrailingNewline() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("hello   ")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "hello")
    }

    @Test("Save whitespace-only file produces empty lines")
    func saveWhitespaceOnlyFile() {
        let manager = TabManager()
        let url = tempFileURL(content: "hello")

        manager.openTab(url: url)
        manager.updateContent("   \n\t\t\n")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "\n\n")
    }

    @Test("Auto-save strips trailing whitespace")
    func autoSaveStripsTrailingWhitespace() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.1)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("hello   \nworld\t\n")
        #expect(manager.activeTab?.isDirty == true)

        manager.scheduleAutoSave()

        try await Task.sleep(for: .milliseconds(300))

        #expect(manager.activeTab?.isDirty == false)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "hello\nworld\n")
        #expect(manager.activeTab?.content == "hello\nworld\n")
    }

    // MARK: - Huge file partial load

    /// Creates a temporary file of the given size filled with repeating text.
    private func tempHugeFileURL(name: String = "huge.log", size: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let line = String(repeating: "x", count: 99) + "\n" // 100 bytes per line
        let lineData = Data(line.utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var written = 0
        while written < size {
            handle.write(lineData)
            written += lineData.count
        }
        handle.closeFile()
        return url
    }

    @Test("Huge file is opened with partial load and truncation flag")
    func hugeFilePartialLoad() throws {
        let manager = TabManager()
        let size = TabManager.hugeFileThreshold + 1000
        let url = try tempHugeFileURL(size: size)

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        let tab = manager.activeTab
        #expect(tab != nil)
        #expect(tab?.isTruncated == true)
        #expect(tab?.syntaxHighlightingDisabled == true)
        // File size may be slightly larger due to chunk rounding
        #expect(tab?.fileSizeBytes ?? 0 >= size)
        // Content should be around 1 MB + truncation notice, not the full file
        let contentLength = tab?.content.count ?? 0
        #expect(contentLength < 2_000_000) // well under the full file size
        #expect(tab?.content.contains("truncated") == true)
    }

    @Test("Huge file tab is not dirty")
    func hugeFileNotDirty() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold + 1000)

        manager.openTab(url: url)

        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("trySaveTab throws for truncated tab")
    func trySaveTruncatedTabThrows() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold + 1000)

        manager.openTab(url: url)

        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }
    }

    @Test("trySaveTab error message mentions truncation")
    func trySaveTruncatedTabErrorMessage() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold + 1000)

        manager.openTab(url: url)

        do {
            _ = try manager.trySaveTab(at: 0)
            #expect(Bool(false), "Should have thrown")
        } catch {
            #expect(error.localizedDescription.contains("truncated"))
        }
    }

    @Test("File just below huge threshold opens normally with large file path")
    func fileBelowHugeThresholdNotTruncated() {
        let manager = TabManager()
        // Create a file just below the huge threshold but above the large threshold
        // We use openTab(url:syntaxHighlightingDisabled:) to skip the alert dialog
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("medium.log")
        let content = String(repeating: "a", count: TabManager.hugeFileThreshold - 1)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        manager.openTab(url: url, syntaxHighlightingDisabled: true)

        #expect(manager.activeTab?.isTruncated == false)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("Session restore of huge file does partial load")
    func sessionRestoreHugeFilePartialLoad() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold + 1000)

        // Simulate session restore path
        manager.openTab(url: url, syntaxHighlightingDisabled: false)

        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("Duplicate open of huge file activates existing tab")
    func hugeFileDeduplicate() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold + 1000)

        manager.openTab(url: url)
        let firstID = manager.activeTabID

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTabID == firstID)
    }

    @Test("File exactly at huge threshold triggers partial load")
    func fileExactlyAtHugeThreshold() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold)

        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)
    }

    @Test("Truncated tab content does not exceed partial load size significantly")
    func truncatedContentSizeBounded() throws {
        let manager = TabManager()
        let url = try tempHugeFileURL(size: TabManager.hugeFileThreshold * 5)

        manager.openTab(url: url)

        let contentBytes = (manager.activeTab?.content ?? "").utf8.count
        // Content should be ~1MB partial + small truncation notice, never near full size
        #expect(contentBytes < TabManager.hugeFilePartialLoadSize + 1000)
    }

    @Test("isAutoSaving resets after auto-save completes")
    func isAutoSavingResetsAfterSave() async throws {
        let manager = TabManager()
        manager.setAutoSaveDelay(0.05)
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")

        #expect(manager.isAutoSaving == false)

        manager.scheduleAutoSave()
        try await Task.sleep(for: .milliseconds(200))

        // After save completes, flag resets immediately
        #expect(manager.isAutoSaving == false)
        #expect(manager.activeTab?.isDirty == false)
    }
}
