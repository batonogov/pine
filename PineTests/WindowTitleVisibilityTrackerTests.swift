//
//  WindowTitleVisibilityTrackerTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@Suite("Window title visibility tracker")
@MainActor
struct WindowTitleVisibilityTrackerTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    @Test("the title hides once the anchor view reaches a window")
    func titleHidesOnAttachment() {
        // A plain updateNSView write would race attachment (window == nil),
        // and with a constant value no later update would repair the loss.
        let window = makeWindow()
        #expect(window.titleVisibility == .visible)

        window.contentView?.addSubview(TitleVisibilityAnchorView())

        #expect(window.titleVisibility == .hidden)
    }

    @Test("an anchor moved between windows hides the new one's title too")
    func hidingFollowsTheViewAcrossWindows() {
        let first = makeWindow()
        let second = makeWindow()
        let anchor = TitleVisibilityAnchorView()
        first.contentView?.addSubview(anchor)

        anchor.removeFromSuperview()
        second.contentView?.addSubview(anchor)

        #expect(second.titleVisibility == .hidden)
    }

    @Test("changing the window title does not bring the title back")
    func titleChangeKeepsVisibility() {
        // AppKit fact the pin must preserve: assigning `NSWindow.title` —
        // which is all SwiftUI's `.navigationTitle` does when a file opens
        // or closes — never touches `titleVisibility`, so no re-hiding
        // fires here.
        let window = makeWindow()
        window.contentView?.addSubview(TitleVisibilityAnchorView())

        window.title = "main.swift"
        #expect(window.titleVisibility == .hidden)

        window.title = "pine"
        #expect(window.titleVisibility == .hidden)
    }

    @Test("a visibility flip back to visible is pinned back to hidden")
    func visibilityFlipIsPinnedBack() {
        // macOS 27: SwiftUI's `.navigationTitle` machinery re-asserts
        // `.visible` when it applies the title/toolbar configuration after
        // the anchor attached. Simulate that flip — the anchor's KVO pin
        // must put `.hidden` back synchronously.
        let window = makeWindow()
        window.contentView?.addSubview(TitleVisibilityAnchorView())

        window.titleVisibility = .visible
        #expect(window.titleVisibility == .hidden)
    }

    @Test("attaching twice stays hidden without re-applying")
    func idempotentReattachment() {
        let window = makeWindow()
        let anchor = TitleVisibilityAnchorView()
        window.contentView?.addSubview(anchor)
        anchor.removeFromSuperview()
        window.contentView?.addSubview(anchor)

        #expect(window.titleVisibility == .hidden)
    }
}
