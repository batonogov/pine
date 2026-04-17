//
//  FormatOnSaveHighlightTests.swift
//  PineTests
//
//  Tests that syntax highlighting is refreshed after format-on-save (issue #814).
//

import Testing
import AppKit
@testable import Pine

@Suite("Format-on-save highlight invalidation")
@MainActor
struct FormatOnSaveHighlightTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "FormatOnSaveHighlightTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTempFile(content: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("test-\(UUID().uuidString).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Cache invalidation

    @Test("trySaveTab invalidates highlight cache when format-on-save changes content")
    func trySaveTabInvalidatesCacheOnFormat() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings
        tabManager.fileFormatters = .default

        // Unformatted JSON — formatter will change this
        let unformatted = "{\"a\":1,\"b\":2}"
        let url = try makeTempFile(content: unformatted)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)
        guard let tab = tabManager.activeTab else {
            Issue.record("Expected active tab")
            return
        }

        // Simulate a cached highlight result (from a previous highlight pass)
        let fakeCache = HighlightMatchResult(
            matches: [HighlightMatch(range: NSRange(location: 0, length: 5), scope: "string", priority: 0)],
            repaintRange: NSRange(location: 0, length: unformatted.count),
            multilineFingerprint: []
        )
        tabManager.updateHighlightCache(fakeCache)
        #expect(tabManager.activeTab?.cachedHighlightResult != nil, "Cache should be set")

        // Save — format-on-save will reformat JSON
        try tabManager.trySaveTab(at: 0)

        // After save, content should be formatted (pretty-printed)
        let savedContent = tabManager.tabs[0].content
        #expect(savedContent != unformatted, "Content should have been formatted")

        // Highlight cache should be invalidated
        #expect(tabManager.tabs[0].cachedHighlightResult == nil,
                "Highlight cache should be nil after format-on-save changed content")
    }

    @Test("trySaveTab preserves highlight cache when content unchanged by save transforms")
    func trySaveTabPreservesCacheWhenUnchanged() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings

        let content = "hello world"
        let url = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)

        // Make dirty so trySaveTab actually writes, then set cache AFTER
        // (updateContent clears cache as expected)
        tabManager.updateContent("hello world")

        let fakeCache = HighlightMatchResult(
            matches: [],
            repaintRange: NSRange(location: 0, length: content.count),
            multilineFingerprint: []
        )
        tabManager.updateHighlightCache(fakeCache)
        #expect(tabManager.activeTab?.cachedHighlightResult != nil)

        try tabManager.trySaveTab(at: 0)

        // Content unchanged — cache should still exist
        #expect(tabManager.tabs[0].cachedHighlightResult != nil,
                "Cache should be preserved when save transforms don't change content")
    }

    @Test("trySaveTab invalidates cache when strip-trailing-whitespace changes content")
    func trySaveTabInvalidatesCacheOnWhitespaceStrip() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = true

        let tabManager = TabManager()
        tabManager.editorSettings = settings

        let content = "hello   "
        let url = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)

        let fakeCache = HighlightMatchResult(
            matches: [],
            repaintRange: NSRange(location: 0, length: content.count),
            multilineFingerprint: []
        )
        tabManager.updateHighlightCache(fakeCache)

        try tabManager.trySaveTab(at: 0)

        #expect(tabManager.tabs[0].content == "hello")
        #expect(tabManager.tabs[0].cachedHighlightResult == nil,
                "Cache should be invalidated when content changed by save transform")
    }

    @Test("trySaveTab posts tabReloadedFromDisk when content changed by format")
    func trySaveTabPostsNotificationOnFormat() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings
        tabManager.fileFormatters = .default

        let unformatted = "{\"a\":1}"
        let url = try makeTempFile(content: unformatted)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { note in
            if let noteURL = note.userInfo?["url"] as? URL, noteURL == url {
                notified = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try tabManager.trySaveTab(at: 0)

        // Content should have changed
        #expect(tabManager.tabs[0].content != unformatted)
        // Notification should have been posted
        #expect(notified, "tabReloadedFromDisk should be posted when save changes content")
    }

    @Test("trySaveTab does NOT post tabReloadedFromDisk when content unchanged")
    func trySaveTabNoNotificationWhenUnchanged() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings

        let content = "hello"
        let url = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)
        // Make dirty
        tabManager.updateContent("hello")

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try tabManager.trySaveTab(at: 0)

        #expect(!notified, "tabReloadedFromDisk should NOT be posted when content unchanged")
    }

    @Test("saveActiveTabAs invalidates cache when content changed")
    func saveAsInvalidatesCache() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.insertFinalNewline = true
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings

        let content = "hello"  // no trailing newline — insertFinalNewline will add one
        let url = try makeTempFile(content: content)
        let newURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-saveas-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: newURL)
        }

        tabManager.openTab(url: url)

        let fakeCache = HighlightMatchResult(
            matches: [],
            repaintRange: NSRange(location: 0, length: content.count),
            multilineFingerprint: []
        )
        tabManager.updateHighlightCache(fakeCache)
        #expect(tabManager.activeTab?.cachedHighlightResult != nil)

        try tabManager.saveActiveTabAs(to: newURL)

        #expect(tabManager.tabs[0].cachedHighlightResult == nil,
                "Cache should be invalidated after Save As changed content")
    }
}
