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

    @Test("a value set before attachment is applied once the view reaches a window")
    func pendingValueAppliesOnAttachment() {
        // The race this type exists for: SwiftUI's updateNSView runs while
        // `window` is still nil. The write must survive and land when the
        // view is attached — the "fresh project, no file" scenario never
        // produces a second update to repair a lost one.
        let anchor = TitleVisibilityAnchorView()
        anchor.showsTitle = false

        let window = makeWindow()
        window.contentView?.addSubview(anchor)

        #expect(window.titleVisibility == .hidden)
    }

    @Test("updates after attachment apply immediately, both ways")
    func updatesApplyAfterAttachment() {
        let window = makeWindow()
        let anchor = TitleVisibilityAnchorView()
        window.contentView?.addSubview(anchor)

        anchor.showsTitle = false
        #expect(window.titleVisibility == .hidden)

        anchor.showsTitle = true
        #expect(window.titleVisibility == .visible)
    }

    @Test("a view moved between windows carries its value to the new one")
    func valueFollowsTheViewAcrossWindows() {
        let first = makeWindow()
        let second = makeWindow()
        let anchor = TitleVisibilityAnchorView()
        first.contentView?.addSubview(anchor)
        anchor.showsTitle = false

        anchor.removeFromSuperview()
        second.contentView?.addSubview(anchor)

        #expect(second.titleVisibility == .hidden)
    }

    @Test("changing the window title does not reset title visibility")
    func titleChangeKeepsVisibility() {
        // AppKit fact the no-observation design rests on: assigning
        // `NSWindow.title` — which is all SwiftUI's `.navigationTitle` does
        // when a file opens or closes — never touches `titleVisibility`,
        // so the tracker does not need to replay after title changes.
        let window = makeWindow()
        window.titleVisibility = .hidden

        window.title = "main.swift"
        #expect(window.titleVisibility == .hidden)

        window.title = ""
        #expect(window.titleVisibility == .hidden)
    }
}
