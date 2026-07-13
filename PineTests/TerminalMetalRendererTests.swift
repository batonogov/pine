//
//  TerminalMetalRendererTests.swift
//  PineTests
//
//  Tests for the SwiftTerm Metal renderer opt-in (#1108).
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

/// Tests for Pine's opt-in to SwiftTerm's Metal renderer.
///
/// The full Metal path needs a window + a Metal device, so it is exercised
/// manually / via UI tests. These unit tests pin the headless invariants
/// that must hold regardless of environment: the opt-out flag is honoured,
/// enabling without a window is a safe no-op, and the CoreGraphics-only
/// `prepareLayerForRedraw()` does not crash (#1108).
@Suite("Terminal Metal Renderer Tests")
@MainActor
struct TerminalMetalRendererTests {

    // MARK: - Opt-out flag

    @Test("Opt-out flag is unset under the default unit-test environment")
    func optOutFlagUnsetByDefault() {
        // Unit tests run without `--disable-metal` in argv and without
        // `PINE_DISABLE_METAL` in env, so the opt-out reads false. This is
        // also the production default — Metal is enabled unless overridden.
        #expect(PineTerminalView.isMetalExplicitlyDisabled == false)
    }

    // MARK: - Headless safety

    @Test("enableMetalRendererIfNeeded is a no-op without a window")
    func enablingWithoutWindowIsNoOp() {
        // No window attached → guard returns early; must not throw or crash
        // even when a Metal device exists on the host. Pins the headless
        // invariant that keeps unit tests and CI virtual displays stable.
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.enableMetalRendererIfNeeded()
        #expect(view.isUsingMetalRenderer == false)
    }

    @Test("prepareLayerForRedraw does not crash under CoreGraphics (no Metal)")
    func prepareLayerForRedrawIsSafe() {
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        // CoreGraphics path (Metal not active): clears `layer.contents`.
        // Must be safe to call repeatedly and with a background colour.
        view.prepareLayerForRedraw(background: .black)
        view.prepareLayerForRedraw()
        view.prepareLayerForRedraw(background: NSColor.windowBackgroundColor)
        #expect(view.isUsingMetalRenderer == false)
    }

    @Test("enableMetalRendererIfNeeded is idempotent")
    func enablingIsIdempotent() {
        // Calling repeatedly without a window must remain a no-op — the
        // re-parent path (tab switch / pane split) invokes
        // `viewDidMoveToWindow` again, so `enableMetalRendererIfNeeded`
        // must be cheap and safe to re-enter.
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        for _ in 0..<5 {
            view.enableMetalRendererIfNeeded()
        }
        #expect(view.isUsingMetalRenderer == false)
    }
}
