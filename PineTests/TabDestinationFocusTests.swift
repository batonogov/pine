//
//  TabDestinationFocusTests.swift
//  PineTests
//
//  Destination presentation and AppKit focus acknowledgement regressions.
//

import AppKit
import Foundation
import QuickLookUI
import Testing

@testable import Pine

@Suite("Tab Destination Focus")
@MainActor
struct TabDestinationFocusTests {
    @Test("Presentation routing covers Quick Look and rendered Markdown")
    func previewPresentationRouting() {
        let quickLook = EditorTab(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            kind: .preview
        )
        var markdown = EditorTab(
            url: URL(fileURLWithPath: "/tmp/readme.md"),
            content: "# Pine",
            savedContent: "# Pine"
        )

        #expect(EditorContentPresentation.resolve(for: quickLook) == .quickLook)
        markdown.previewMode = .preview
        #expect(EditorContentPresentation.resolve(for: markdown) == .markdownPreview)
        markdown.previewMode = .split
        #expect(EditorContentPresentation.resolve(for: markdown) == .markdownSplit)
        markdown.previewMode = .source
        #expect(EditorContentPresentation.resolve(for: markdown) == .codeEditor)
    }

    @Test("Failed attempts retry while switching tabs cancels stale focus")
    func failedAttemptsRetryAndTabSwitchCancelsStaleFocus() {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/image.png"), kind: .preview)
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id

        #expect(!manager.acknowledgeFocusRequest(for: tab.id, succeeded: false))
        #expect(manager.pendingFocusTabID == tab.id)
        #expect(!manager.acknowledgeFocusRequest(for: UUID(), succeeded: true))
        #expect(manager.pendingFocusTabID == tab.id)

        manager.activeTabID = nil
        #expect(manager.pendingFocusTabID == nil)
        #expect(!manager.acknowledgeFocusRequest(for: tab.id, succeeded: true))
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("Detached AppKit destination retries and acknowledges after attachment")
    func detachedDestinationRetriesAfterWindowAttachment() {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: tab.id,
            hostView: host,
            targetView: target,
            onResult: { tabID, succeeded in
                manager.acknowledgeFocusRequest(for: tabID, succeeded: succeeded)
            }
        )

        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == tab.id)
        #expect(manager.pendingFocusTabID == tab.id)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host

        #expect(coordinator.attemptNow())
        #expect(window.firstResponder === target)
        #expect(coordinator.pendingRequestID == nil)
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("Stale request is cancelled before AppKit can steal focus")
    func staleRequestDoesNotChangeFirstResponder() {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let originalResponder = window.firstResponder
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: tab.id,
            hostView: host,
            targetView: target,
            canAttempt: { tabID in
                manager.activeTabID == tabID
                    && manager.pendingFocusTabID == tabID
            },
            onResult: { tabID, succeeded in
                manager.acknowledgeFocusRequest(for: tabID, succeeded: succeeded)
            }
        )

        manager.activeTabID = nil
        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == nil)
        #expect(window.firstResponder === originalResponder)
        #expect(window.firstResponder !== target)
    }

    @Test("Quick Look focus target is an explicit first responder")
    func quickLookAcceptsDestinationFocus() throws {
        let view = try #require(FocusableQuickLookPreviewView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            style: .normal
        ))
        #expect(view.acceptsFirstResponder)
    }

    @Test("Terminal focus acknowledgement retries and cancels on active switch")
    func terminalAcknowledgementRetryAndCancellation() {
        let state = TerminalPaneState()
        let first = state.addTab(workingDirectory: nil)

        #expect(!state.acknowledgeFocusRequest(for: first.id, succeeded: false))
        #expect(state.pendingFocusTabID == first.id)

        let second = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == second.id)
        state.activeTerminalID = first.id
        #expect(state.pendingFocusTabID == nil)
        #expect(!state.acknowledgeFocusRequest(for: second.id, succeeded: true))
    }
}

private final class FocusAcceptingTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
