//
//  CodeEditorViewSplitTests.swift
//  PineTests
//
//  Smoke tests guarding the file split introduced in #755: verify that
//  `CodeEditorView.Coordinator` is still resolvable as a nested type (it now
//  lives in a separate file via `extension CodeEditorView`), and that
//  `NSImage.pine_tinted(with:)` is discoverable under its prefixed name.
//

import Testing
import AppKit
@testable import Pine

struct CodeEditorViewSplitTests {
    /// After the split, `CodeEditorView.Coordinator` must still be nameable
    /// as a nested type on `CodeEditorView` — SwiftUI's `makeCoordinator()`
    /// relies on it, and a broken move would surface here at compile time.
    @Test
    func coordinatorTypeIsResolvableAsNested() {
        // Compile-time assertion: if the type disappears, this won't build.
        let coordinatorType: CodeEditorView.Coordinator.Type = CodeEditorView.Coordinator.self
        _ = coordinatorType
    }

    /// The tinting helper was renamed from `tinted(with:)` to
    /// `pine_tinted(with:)` to avoid colliding with future Apple APIs on
    /// `NSImage`. Guard the new name so callers don't silently regress.
    @Test
    func tintedHelperIsAccessibleAndProducesImage() {
        let base = NSImage(size: NSSize(width: 4, height: 4))
        base.lockFocus()
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        base.unlockFocus()

        let tinted = base.pine_tinted(with: .red)
        #expect(tinted.size == base.size)
    }
}
