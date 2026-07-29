//
//  AgentAttentionWindowContextTests.swift
//  PineTests
//
//  Owner-window focus and accessibility routing for Agent Attention.
//

import AppKit
import Testing

@testable import Pine

@MainActor
@Suite("Agent Attention Owner Window")
struct AgentAttentionWindowContextTests {
    @Test("Focus restoration and announcements stay in the owning window")
    func focusAndAnnouncementUseOwnerWindow() throws {
        let owner = makeWindowFixture()
        let unrelated = makeWindowFixture()
        defer {
            tearDown(owner.window)
            tearDown(unrelated.window)
        }

        let probe = AgentAttentionAnnouncementProbe()
        let windowContext = AgentAttentionWindowContext { window, announcement in
            probe.record(window: window, announcement: announcement)
        }
        windowContext.install(owner.sentinel)

        #expect(windowContext.window === owner.window)
        #expect(owner.window.makeFirstResponder(owner.originalResponder))
        #expect(unrelated.window.makeFirstResponder(
            unrelated.originalResponder
        ))

        let focusCoordinator = AgentAttentionFocusCoordinator()
        let captureID = try #require(
            focusCoordinator.capture(in: windowContext.window)
        )
        #expect(owner.window.makeFirstResponder(owner.overlayResponder))

        #expect(windowContext.announce("Codex, waiting for input"))
        #expect(probe.window === owner.window)
        #expect(probe.announcement == "Codex, waiting for input")

        #expect(focusCoordinator.restore(matching: captureID))
        #expect(owner.window.firstResponder === owner.originalResponder)
        #expect(
            unrelated.window.firstResponder === unrelated.originalResponder
        )
    }

    @Test("Stale representable teardown cannot erase a replacement owner")
    func staleSentinelCannotClearReplacementWindow() {
        let first = makeWindowFixture()
        let replacement = makeWindowFixture()
        defer {
            tearDown(first.window)
            tearDown(replacement.window)
        }

        let probe = AgentAttentionAnnouncementProbe()
        let windowContext = AgentAttentionWindowContext { window, announcement in
            probe.record(window: window, announcement: announcement)
        }

        windowContext.install(first.sentinel)
        windowContext.install(replacement.sentinel)
        first.sentinel.removeFromSuperview()
        windowContext.updateWindow(for: first.sentinel)
        windowContext.untrack(first.sentinel)

        #expect(windowContext.window === replacement.window)
        #expect(windowContext.announce("Replacement owner"))
        #expect(probe.window === replacement.window)

        windowContext.untrack(replacement.sentinel)
        #expect(windowContext.window == nil)
        #expect(!windowContext.announce("No global fallback"))
        #expect(probe.announcement == "Replacement owner")
    }

    private func makeWindowFixture() -> AgentAttentionWindowFixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView

        let originalResponder = AgentAttentionFocusableView(frame: .zero)
        let overlayResponder = AgentAttentionFocusableView(frame: .zero)
        let sentinel = NSView(frame: .zero)
        contentView.addSubview(originalResponder)
        contentView.addSubview(overlayResponder)
        contentView.addSubview(sentinel)

        return AgentAttentionWindowFixture(
            window: window,
            originalResponder: originalResponder,
            overlayResponder: overlayResponder,
            sentinel: sentinel
        )
    }

    private func tearDown(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private struct AgentAttentionWindowFixture {
    let window: NSWindow
    let originalResponder: AgentAttentionFocusableView
    let overlayResponder: AgentAttentionFocusableView
    let sentinel: NSView
}

@MainActor
private final class AgentAttentionFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class AgentAttentionAnnouncementProbe {
    private(set) weak var window: NSWindow?
    private(set) var announcement: String?

    func record(window: NSWindow, announcement: String) {
        self.window = window
        self.announcement = announcement
    }
}
