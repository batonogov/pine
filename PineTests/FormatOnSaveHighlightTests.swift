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

    // MARK: - Content caches (indentation / line ending)

    @Test("trySaveTab recomputes cachedIndentation when format-on-save changes indentation style")
    func trySaveTabRecomputesIndentation() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings
        tabManager.fileFormatters = .default

        // Unformatted JSON with tab indentation — formatter will switch to spaces
        let tabIndented = "{\n\t\"a\": 1,\n\t\"b\": 2\n}"
        let url = try makeTempFile(content: tabIndented)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)
        // Before save, indentation should be detected as tabs
        #expect(tabManager.tabs[0].cachedIndentation == .tabs,
                "Initial indentation should be tabs")

        try tabManager.trySaveTab(at: 0)

        // After format-on-save, JSON formatter uses spaces — cachedIndentation must update
        let savedContent = tabManager.tabs[0].content
        #expect(savedContent != tabIndented, "Content should have been reformatted")
        #expect(tabManager.tabs[0].cachedIndentation != .tabs,
                "cachedIndentation should update from tabs to spaces after format-on-save")
    }

    @Test("saveActiveTabAs recomputes cachedLineEnding when content changes")
    func saveAsRecomputesLineEnding() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.insertFinalNewline = true
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings

        // Content with CRLF line endings and no final newline
        let crlfContent = "line1\r\nline2\r\nline3"
        let url = try makeTempFile(content: crlfContent)
        let newURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-le-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: newURL)
        }

        tabManager.openTab(url: url)
        #expect(tabManager.tabs[0].cachedLineEnding == .crlf,
                "Initial line ending should be CRLF")

        // insertFinalNewline appends "\n" (LF), changing the balance
        try tabManager.saveActiveTabAs(to: newURL)

        // The content changed (final newline added), so caches should be recomputed
        let saved = tabManager.tabs[0].content
        if saved != crlfContent {
            // Caches were recomputed — verify the line ending reflects actual content
            let redetected = LineEnding.detect(in: saved)
            #expect(tabManager.tabs[0].cachedLineEnding == redetected,
                    "cachedLineEnding should match re-detected value after Save As")
        }
    }

    // MARK: - Save-path reentrancy (#1066)

    /// `TabPersistence.saveTabContent` must NOT post `.tabReloadedFromDisk`
    /// itself — the post was relocated to the caller (`TabManager.trySaveTab`)
    /// so it fires AFTER the `inout tabs` exclusive access ends. Posting under
    /// the live inout delivered the synchronous observer back into
    /// `TabManager.tabs` via `updateHighlightCache` → Swift runtime
    /// exclusivity abort (#1066). This pins the relocation: if the post moves
    /// back inside `saveTabContent`, the observer fires here and the test
    /// goes red. Same contract-testing approach as `FoldObserverReentrancyTests`
    /// / `MenuSaveReentrancyTests` (test the mechanism, not the crash).
    @Test("saveTabContent does not post tabReloadedFromDisk (post relocated to caller)")
    func saveTabContentDoesNotPostReloadNotification() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let unformatted = "{\"a\":1}"
        let url = try makeTempFile(content: unformatted)
        defer { try? FileManager.default.removeItem(at: url) }

        var tabs: [EditorTab] = [EditorTab(url: url, content: unformatted, savedContent: unformatted)]

        var posted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let outcome = try TabPersistence.saveTabContent(
            at: 0, tabs: &tabs,
            config: .init(editorSettings: settings, formatters: .default),
            providers: .default
        )

        #expect(outcome.saved, "saveTabContent should write the file")
        #expect(outcome.reload != nil,
                "saveTabContent should report a reload payload when content changed")
        #expect(!posted,
                "saveTabContent must NOT post tabReloadedFromDisk itself (post relocated to caller, #1066)")
    }

    /// Live regression for the macOS 26 exclusivity abort (#1066). When
    /// format-on-save changes content, `trySaveTab` posts
    /// `.tabReloadedFromDisk`; the observer registered here re-enters
    /// `TabManager.tabs` via `updateHighlightCache` — exactly the reentrant
    /// access that aborted when the post fired under `saveTabContent`'s live
    /// `inout tabs`. With the fix the post fires after the inout scope ends,
    /// so the observer's write lands safely. Before the fix this test aborts
    /// the process (exclusivity conflict); completing the assertions below is
    /// the regression signal.
    @Test("trySaveTab survives a reentrant observer writing tabs via updateHighlightCache (#1066)")
    func trySaveTabSurvivesReentrantObserver() throws {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false

        let tabManager = TabManager()
        tabManager.editorSettings = settings
        tabManager.fileFormatters = .default

        let unformatted = "{\"a\":1,\"b\":2}"
        let url = try makeTempFile(content: unformatted)
        defer { try? FileManager.default.removeItem(at: url) }

        tabManager.openTab(url: url)

        let reentrantCache = HighlightMatchResult(
            matches: [HighlightMatch(range: NSRange(location: 0, length: 3), scope: "keyword.reentrancy", priority: 0)],
            repaintRange: NSRange(location: 0, length: 10),
            multilineFingerprint: []
        )
        // The observer re-enters TabManager.tabs storage — the access that
        // collided with the live inout and aborted before #1066. Delivered
        // on .main during the synchronous post, so MainActor.assumeIsolated
        // is valid.
        let observer = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { [weak tabManager] note in
            guard let noteURL = note.userInfo?["url"] as? URL, noteURL == url else { return }
            MainActor.assumeIsolated {
                tabManager?.updateHighlightCache(reentrantCache)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Before the fix this line aborted the process via the exclusivity
        // conflict; reaching the assertions below is the regression proof.
        //
        // Debug-only enforcement note: Swift runtime exclusivity checking is
        // active in Debug (and `-Onone`/unchecked). CI and the standard test
        // scheme run Debug, so this test reproduces the abort there. In a
        // Release build the overlapping access is undefined behaviour and may
        // not abort — so this regression guard is meaningful on CI, not in a
        // release-config run.
        try tabManager.trySaveTab(at: 0)

        #expect(tabManager.tabs[0].cachedHighlightResult?.matches.first?.scope == "keyword.reentrancy",
                "reentrant updateHighlightCache from the reload observer should land safely (#1066)")
    }

    /// Save-As caller responsibility: `saveActiveTabAs` posts
    /// `.tabReloadedFromDisk` (with the NEW url) when save-time transforms
    /// change the content — the post relocated out of `TabPersistence.saveTabAs`.
    @Test("saveActiveTabAs posts tabReloadedFromDisk when content changed")
    func saveActiveTabAsPostsReloadNotification() throws {
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
        let newURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("saveas-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: newURL)
        }

        tabManager.openTab(url: url)

        var postedURL: URL?
        let observer = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { note in postedURL = note.userInfo?["url"] as? URL }
        defer { NotificationCenter.default.removeObserver(observer) }

        try tabManager.saveActiveTabAs(to: newURL)

        #expect(postedURL == newURL,
                "saveActiveTabAs should post tabReloadedFromDisk with the new URL when content changed (#1066)")
    }
}
