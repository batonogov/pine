//
//  TerminalMetalRendererTests.swift
//  PineTests
//
//  Tests for the SwiftTerm Metal renderer opt-in (#1108).
//

import Testing
import AppKit
import MetalKit
import SwiftTerm
@testable import Pine

/// Tests for Pine's opt-in to SwiftTerm's Metal renderer.
///
/// Hosted-window tests exercise the production Metal path when the runner has
/// a GPU; headless runners still pin the fallback invariants. This keeps the
/// suite portable while covering the first-frame recovery that UI tests miss
/// because they intentionally pass `--disable-metal` (#1108, #1128).
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

    // MARK: - Backend-aware redraw (#1128)

    @Test("First-frame retry plan is bounded and ordered")
    func firstFrameRetryPlanIsBoundedAndOrdered() {
        let delays = UITimings.Render.terminalFirstFrameRetryDelays
        #expect(delays.first == 0)
        #expect(delays == delays.sorted())
        #expect(delays.count == 4)
        #expect(delays.last == 0.35)
    }

    @Test("forceFullRedraw routes through Pine's backend-aware display bridge")
    func forceFullRedrawUsesBackendAwareBridge() {
        let tab = TerminalTab(name: "redraw-test")
        let view = tab.terminalView as? PineTerminalView
        var redrawRequests = 0
        view?.backendRedrawRequestObserver = { redrawRequests += 1 }

        tab.forceFullRedraw()

        #expect(view != nil)
        #expect(redrawRequests == 1)
    }

    @Test("Metal redraw invalidates the nested MTKView")
    func metalRedrawTargetsNestedView() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = makeWindow(containing: view)

        guard view.isUsingMetalRenderer,
              let metalView = firstMetalView(in: view) else {
            window.contentView = nil
            return
        }

        // Let the initial bounded retry batch drain, then isolate one request.
        try? await Task.sleep(for: .milliseconds(450))
        metalView.needsDisplay = false
        view.requestRendererDisplay()

        #expect(metalView.needsDisplay)
        window.contentView = nil
    }

    @Test("Initial Metal attachment schedules bounded redraw retries")
    func initialAttachmentSchedulesRetries() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer else {
            window.contentView = nil
            return
        }

        try? await Task.sleep(for: .milliseconds(450))

        #expect(redrawRequests == UITimings.Render.terminalFirstFrameRetryDelays.count)
        window.contentView = nil
    }

    @Test("Detaching Metal view cancels pending first-frame retries")
    func detachingCancelsRetries() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer else {
            window.contentView = nil
            return
        }
        window.contentView = nil

        try? await Task.sleep(for: .milliseconds(450))

        #expect(redrawRequests == 0)
    }

    @Test("Reattaching Metal view schedules a fresh bounded retry batch")
    func reattachingSchedulesFreshRetries() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer else {
            window.contentView = nil
            return
        }

        // Cancel the first batch before the main queue can deliver it, then
        // reattach to the same window. A fresh batch is required because the
        // CAMetalLayer can lose its drawable during ordinary tab re-parenting.
        window.contentView = nil
        window.contentView = view

        try? await Task.sleep(for: .milliseconds(450))

        #expect(redrawRequests == UITimings.Render.terminalFirstFrameRetryDelays.count)
        window.contentView = nil
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    private func firstMetalView(in view: NSView) -> MTKView? {
        if let metalView = view as? MTKView { return metalView }
        for subview in view.subviews {
            if let metalView = firstMetalView(in: subview) { return metalView }
        }
        return nil
    }
}
