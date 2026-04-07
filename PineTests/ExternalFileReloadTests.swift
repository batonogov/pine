//
//  ExternalFileReloadTests.swift
//  PineTests
//
//  Regression tests for issue #734: external file changes were detected
//  and a toast was shown, but the editor's NSTextView did not actually
//  resync from disk until the tab was closed and reopened.
//
//  These tests cover both the TabManager pipeline (data layer) and the
//  CodeEditorView.Coordinator notification path (view layer) that
//  guarantees the NSTextView reflects disk state.
//

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import Pine

@MainActor
struct ExternalFileReloadTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func tempFile(content: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.txt")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func touch(_ url: URL, secondsInFuture: TimeInterval = 2) {
        let date = Date().addingTimeInterval(secondsInFuture)
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }

    /// Builds a minimal text system stack matching CodeEditorView.makeNSView.
    private func makeTextStack(text: String) -> (NSScrollView, NSTextView) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    // MARK: - TabManager pipeline

    @Test("checkExternalChanges posts .tabReloadedFromDisk for clean tab")
    func postsNotificationForCleanReload() throws {
        let url = tempFile(content: "v1")
        let manager = TabManager()
        manager.openTab(url: url)

        var received: (URL, String)?
        let token = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { note in
            if let u = note.userInfo?["url"] as? URL,
               let t = note.userInfo?["text"] as? String {
                received = (u, t)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try "v2 from disk".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let result = manager.checkExternalChanges()

        #expect(result.reloadedFileNames.count == 1)
        #expect(received?.0 == url)
        #expect(received?.1 == "v2 from disk")
        #expect(manager.activeTab?.content == "v2 from disk")
    }

    @Test("checkExternalChanges does NOT post for dirty tab — conflict instead")
    func dirtyTabNoNotification() throws {
        let url = tempFile(content: "v1")
        let manager = TabManager()
        manager.openTab(url: url)
        manager.updateContent("user edits")

        var fired = false
        let token = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(token) }

        try "external".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let result = manager.checkExternalChanges()

        #expect(result.conflicts.count == 1)
        #expect(result.conflicts.first?.kind == .modified)
        #expect(fired == false)
        #expect(manager.activeTab?.content == "user edits")
    }

    @Test("reloadTab posts .tabReloadedFromDisk after dirty conflict resolution")
    func reloadTabPostsNotification() throws {
        let url = tempFile(content: "original")
        let manager = TabManager()
        manager.openTab(url: url)
        manager.updateContent("dirty edit")

        try "fresh from disk".write(to: url, atomically: true, encoding: .utf8)

        var received: String?
        let token = NotificationCenter.default.addObserver(
            forName: .tabReloadedFromDisk, object: nil, queue: .main
        ) { note in received = note.userInfo?["text"] as? String }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.reloadTab(url: url)

        #expect(received == "fresh from disk")
        #expect(manager.activeTab?.content == "fresh from disk")
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("checkExternalChanges recomputes content caches after reload")
    func reloadRecomputesCaches() throws {
        let url = tempFile(content: "    indented\n")
        let manager = TabManager()
        manager.openTab(url: url)

        // Switch to tabs
        try "\there\twith tabs\n".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        _ = manager.checkExternalChanges()

        #expect(manager.activeTab?.cachedIndentation == .tabs)
    }

    @Test("Two rapid sequential reloads — last writer wins")
    func raceLastWriterWins() throws {
        let url = tempFile(content: "v0")
        let manager = TabManager()
        manager.openTab(url: url)

        try "v1".write(to: url, atomically: true, encoding: .utf8)
        touch(url, secondsInFuture: 1)
        _ = manager.checkExternalChanges()
        #expect(manager.activeTab?.content == "v1")

        try "v2".write(to: url, atomically: true, encoding: .utf8)
        touch(url, secondsInFuture: 5)
        _ = manager.checkExternalChanges()
        #expect(manager.activeTab?.content == "v2")
    }

    @Test("File deleted externally — clean tab is closed silently")
    func deletedFileClosesCleanTab() throws {
        let url = tempFile(content: "x")
        let manager = TabManager()
        manager.openTab(url: url)
        try FileManager.default.removeItem(at: url)

        let result = manager.checkExternalChanges()

        #expect(result.conflicts.isEmpty)
        #expect(manager.tabs.isEmpty)
    }

    @Test("File deleted externally — dirty tab returns conflict")
    func deletedFileDirtyTabConflict() throws {
        let url = tempFile(content: "x")
        let manager = TabManager()
        manager.openTab(url: url)
        manager.updateContent("dirty")
        try FileManager.default.removeItem(at: url)

        let result = manager.checkExternalChanges()

        #expect(result.conflicts.count == 1)
        #expect(result.conflicts.first?.kind == .deleted)
        #expect(manager.tabs.count == 1)
    }

    @Test("Reload with mismatched encoding fails gracefully — no crash")
    func encodingMismatchSurvives() throws {
        let url = tempFile(content: "ascii")
        let manager = TabManager()
        manager.openTab(url: url)
        // Write UTF-16 BOM bytes — invalid as the original UTF-8 encoding
        let invalidBytes = Data([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0xDC])
        try invalidBytes.write(to: url)
        touch(url)
        // Must not crash; the silent reload either succeeds with replacement
        // chars or skips the tab.
        _ = manager.checkExternalChanges()
        #expect(manager.tabs.count == 1)
    }

    // MARK: - Coordinator notification path (#734 root cause)

    @Test("Coordinator updates NSTextView on .tabReloadedFromDisk for matching URL")
    func coordinatorAppliesNotification() {
        let url = URL(fileURLWithPath: "/tmp/coordinator-test-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "old")

        let view = CodeEditorView(
            text: .constant("old"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.applyExternalReload(text: "fresh content")

        #expect(textView.string == "fresh content")
    }

    @Test("Coordinator ignores notification for a different URL")
    func coordinatorIgnoresUnrelatedNotification() {
        let myURL = URL(fileURLWithPath: "/tmp/me-\(UUID().uuidString).txt")
        let otherURL = URL(fileURLWithPath: "/tmp/other-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "stable")

        let view = CodeEditorView(
            text: .constant("stable"),
            contentVersion: 0,
            language: "txt",
            fileName: "me.txt",
            fileURL: myURL,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        NotificationCenter.default.post(
            name: .tabReloadedFromDisk,
            object: nil,
            userInfo: ["url": otherURL, "text": "intruder"]
        )

        #expect(textView.string == "stable")
    }

    @Test("applyExternalReload is idempotent — same text is a no-op")
    func idempotentReload() {
        let url = URL(fileURLWithPath: "/tmp/idem-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "same")

        let view = CodeEditorView(
            text: .constant("same"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Place cursor mid-text
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.applyExternalReload(text: "same")

        #expect(textView.string == "same")
        #expect(textView.selectedRange().location == 2)
    }

    @Test("applyExternalReload preserves cursor when new content is longer")
    func cursorPreservedLongerContent() {
        let url = URL(fileURLWithPath: "/tmp/cur-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "hello")

        let view = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.applyExternalReload(text: "hello, world!")

        #expect(textView.string == "hello, world!")
        #expect(textView.selectedRange().location == 3)
    }

    @Test("applyExternalReload clamps cursor when new content is shorter")
    func cursorClampedShorterContent() {
        let url = URL(fileURLWithPath: "/tmp/clamp-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "long string of text")

        let view = CodeEditorView(
            text: .constant("long string of text"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        textView.setSelectedRange(NSRange(location: 15, length: 0))
        coordinator.applyExternalReload(text: "short")

        #expect(textView.string == "short")
        #expect(textView.selectedRange().location == 5)
    }

    @Test("End-to-end: TabManager.checkExternalChanges drives Coordinator via notification")
    func endToEndPipeline() throws {
        let url = tempFile(content: "before")
        let manager = TabManager()
        manager.openTab(url: url)

        let (scrollView, textView) = makeTextStack(text: "before")
        let view = CodeEditorView(
            text: .constant("before"),
            contentVersion: 0,
            language: "txt",
            fileName: url.lastPathComponent,
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        try "AFTER EXTERNAL CHANGE".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let result = manager.checkExternalChanges()

        #expect(result.reloadedFileNames.count == 1)
        // The coordinator's NSNotification observer must have applied the
        // new content to the NSTextView synchronously.
        #expect(textView.string == "AFTER EXTERNAL CHANGE")
    }

    @Test("End-to-end: reloadTab via dirty conflict resolution drives Coordinator")
    func endToEndDirtyResolve() throws {
        let url = tempFile(content: "v1")
        let manager = TabManager()
        manager.openTab(url: url)
        manager.updateContent("user edits")

        let (scrollView, textView) = makeTextStack(text: "user edits")
        let view = CodeEditorView(
            text: .constant("user edits"),
            contentVersion: 0,
            language: "txt",
            fileName: url.lastPathComponent,
            fileURL: url,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        try "fresh from disk".write(to: url, atomically: true, encoding: .utf8)
        manager.reloadTab(url: url)

        #expect(textView.string == "fresh from disk")
    }
}
