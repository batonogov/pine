//
//  StateChangeReentrancyTests.swift
//  PineTests
//
//  Regression tests for issue #1032: Swift exclusivity abort on macOS 27
//  beta 1 caused by reentrant @Observable mutation during NSTextView edit.
//
//  Root cause: `reportStateChange` synchronously called
//  `parent.onStateChange?(cursor, scroll)`, which mutates @Observable
//  fields (cursorPosition/scrollOffset) on the active tab and forces a
//  synchronous SwiftUI re-render. When this happens inside an AppKit
//  text-storage / selection-notification callstack (programmatic
//  `setSelectedRange` after `replaceCharacters` — external reload, toggle
//  comment, auto-indent, tab switch), the re-render collides with the
//  outer callstack's exclusive access to `EnvironmentValues` and triggers
//  `_swift_reportExclusivityConflict` → `abort()`.
//
//  Fix: `reportStateChange` now defers the `onStateChange` call to the next
//  runloop via `DispatchQueue.main.async` with coalescing, breaking the
//  synchronous reentrancy.
//
//  These tests pin the contract: `onStateChange` must NOT fire synchronously
//  from within `applyExternalReload` (the primary crash path), but MUST fire
//  on the next runloop with the latest cursor/scroll values. Coalescing is
//  also verified — multiple rapid reports deliver only the final value.
//

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import Pine

@MainActor
struct StateChangeReentrancyTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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

    // MARK: - Synchronous delivery is forbidden (the crash contract)

    @Test("applyExternalReload does not call onStateChange synchronously (#1032)")
    func externalReloadNotSynchronous() async throws {
        let url = URL(fileURLWithPath: "/tmp/reentrancy-\(UUID().uuidString).txt")
        let (scrollView, _) = makeTextStack(text: "old")

        var syncCallCount = 0
        let view = CodeEditorView(
            text: .constant("old"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState()),
            onStateChange: { _, _ in syncCallCount += 1 }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // The reentrant path: applyExternalReload → replaceCharacters →
        // setSelectedRange → selection notification → reportStateChange.
        coordinator.applyExternalReload(text: "fresh content")

        // Synchronously, onStateChange must NOT have fired — that was the
        // reentrancy that caused the macOS 27 exclusivity abort.
        #expect(syncCallCount == 0,
                "onStateChange must be deferred to the next runloop, not called synchronously from applyExternalReload")
    }

    @Test("textViewDidChangeSelection does not call onStateChange synchronously (#1032)")
    func selectionChangeNotSynchronous() async throws {
        let url = URL(fileURLWithPath: "/tmp/reentrancy-sel-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "hello")

        var syncCallCount = 0
        let view = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState()),
            onStateChange: { _, _ in syncCallCount += 1 }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Wire the Coordinator as the text view's delegate so AppKit actually
        // delivers `textViewDidChangeSelection(_:)` to it. Without this wiring
        // the test would post a notification nobody observes, pass trivially,
        // and not exercise the selection-change path at all.
        textView.delegate = coordinator

        // Simulate the synchronous selection-notification delivery that AppKit
        // posts during a programmatic `setSelectedRange`. Because `delegate` is
        // set, this reaches `reportStateChange` synchronously.
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        // Must not fire synchronously — the whole point of the #1032 fix.
        #expect(syncCallCount == 0,
                "onStateChange must be deferred to the next runloop, not called synchronously from a selection notification")
    }

    // MARK: - Deferred delivery happens on the next runloop

    @Test("applyExternalReload delivers onStateChange on the next runloop (#1032)")
    func externalReloadDeferredDelivery() async throws {
        let url = URL(fileURLWithPath: "/tmp/reentrancy-defer-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "old")

        actor CallRecorder {
            var cursor: Int?
            var scroll: CGFloat?
            func record(cursor: Int, scroll: CGFloat) {
                self.cursor = cursor
                self.scroll = scroll
            }
        }
        let recorder = CallRecorder()
        let view = CodeEditorView(
            text: .constant("old"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState()),
            onStateChange: { c, s in Task { await recorder.record(cursor: c, scroll: s) } }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.applyExternalReload(text: "fresh content")

        // Drain the main runloop so the deferred DispatchQueue.main.async block fires.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        let finalCursor = await recorder.cursor
        #expect(finalCursor != nil,
                "onStateChange must fire on the next runloop after applyExternalReload")
        if let finalCursor {
            #expect(finalCursor == textView.selectedRange().location,
                    "deferred cursor must match the post-reload selection")
        }
    }

    // MARK: - Coalescing: multiple rapid reports deliver only the final value

    @Test("rapid reportStateChange calls coalesce to a single onStateChange (#1032)")
    func coalescingMultipleReports() async throws {
        let url = URL(fileURLWithPath: "/tmp/reentrancy-coal-\(UUID().uuidString).txt")
        let (scrollView, textView) = makeTextStack(text: "0123456789")

        actor Counter {
            var count = 0
            var lastCursor: Int?
            func record(cursor: Int) { count += 1; lastCursor = cursor }
        }
        let counter = Counter()
        let view = CodeEditorView(
            text: .constant("0123456789"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: .constant(FoldState()),
            onStateChange: { c, _ in Task { await counter.record(cursor: c) } }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Wire the Coordinator as the text view's delegate so AppKit actually
        // delivers `textViewDidChangeSelection(_:)` to it. Without this wiring
        // the test would post a notification nobody observes, never reach
        // `reportStateChange`, and `counter.count` would stay 0 — failing the
        // assertion below without exercising the path under test.
        textView.delegate = coordinator

        // Simulate the rapid sequence AppKit produces during a programmatic
        // edit + selection restore. With `delegate` wired, each
        // `setSelectedRange` reaches `reportStateChange` synchronously on the
        // same runloop, so they must coalesce into exactly one onStateChange.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.setSelectedRange(NSRange(location: 9, length: 0))

        // Drain the runloop.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        let callCount = await counter.count
        let lastCursor = await counter.lastCursor
        #expect(callCount == 1,
                "coalescing must collapse 3 rapid reportStateChange calls into 1 onStateChange")
        #expect(lastCursor == 9,
                "coalesced value must be the latest cursor position, not an earlier one")
    }
}
