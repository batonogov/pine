//
//  TerminalMetalRendererTests.swift
//  PineTests
//
//  Tests for the SwiftTerm Metal renderer opt-in (#1108).
//

import Testing
import AppKit
import Foundation
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

    @Test("Theme changes repaint through the CoreGraphics bridge")
    func themeChangeRepaintsCoreGraphics() async throws {
        let settings = try makeThemeSettings()
        settings.appearancePolicy = .alwaysDark
        let tab = TerminalTab(name: "theme-core-graphics", themeSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        view.metalRendererDisabledForTesting = true
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        settings.setTheme(id: TerminalTheme.dracula.id)
        let repainted = await waitForThemeRepaint {
            redrawRequests == 1
        }

        #expect(repainted)
        #expect(view.isUsingMetalRenderer == false)
        #expect(
            view.nativeBackgroundColor
                == TerminalTheme.dracula.dark.backgroundColor()
        )
        #expect(redrawRequests == 1)
    }

    @Test("Theme changes repaint through the Metal compatibility bridge")
    func themeChangeRepaintsMetal() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let settings = try makeThemeSettings()
        settings.appearancePolicy = .alwaysDark
        let tab = TerminalTab(name: "theme-metal", themeSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        guard view.isUsingMetalRenderer else { return }

        // Drain attachment retries so only the settings-driven repaint is
        // counted below.
        try? await Task.sleep(for: .milliseconds(450))
        var redrawRequests = 0
        var metalBridgeRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }
        view.metalRedrawBridgeObserver = { metalBridgeRequests += 1 }

        settings.setTheme(id: TerminalTheme.dracula.id)
        let repainted = await waitForThemeRepaint {
            redrawRequests == 1 && metalBridgeRequests == 1
        }

        #expect(repainted)
        #expect(
            view.nativeBackgroundColor
                == TerminalTheme.dracula.dark.backgroundColor()
        )
        #expect(redrawRequests == 1)
        #expect(metalBridgeRequests == 1)
    }

    @Test("Metal redraw uses the nested MTKView compatibility bridge")
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
        var bridgeRequests = 0
        view.metalRedrawBridgeObserver = { bridgeRequests += 1 }
        view.requestRendererDisplay()

        // `needsDisplay` is deliberately not asserted here: AppKit may
        // consume the on-demand MTKView request synchronously and reset that
        // transient flag before this line. The bridge hook records the stable
        // production boundary immediately before SwiftTerm receives it.
        #expect(metalView.superview === view)
        #expect(bridgeRequests == 1)
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
        guard let originalMetalView = firstMetalView(in: view) else {
            Issue.record("Attached terminal has no Metal view")
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
        guard let reattachedMetalView = firstMetalView(in: view) else {
            Issue.record("Reattached terminal lost its Metal view")
            window.contentView = nil
            return
        }
        #expect(reattachedMetalView === originalMetalView)
        window.contentView = nil
    }

    @Test("Switching away and back to the same host keeps Metal renderer")
    func sameHostReattachKeepsMetalView() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let state = TerminalPaneState()
        let firstTab = state.addTab(workingDirectory: nil)
        let secondTab = state.addTab(workingDirectory: nil)
        state.activeTerminalID = firstTab.id
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.bind(to: state)
        let window = makeWindow(containing: container)
        defer {
            firstTab.stop()
            secondTab.stop()
            window.contentView = nil
        }
        guard let view = firstTab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        guard view.isUsingMetalRenderer,
              let originalMetalView = firstMetalView(in: view) else {
            return
        }

        state.activeTerminalID = secondTab.id
        container.showTab(secondTab)
        state.activeTerminalID = firstTab.id
        container.showTab(firstTab)

        #expect(firstMetalView(in: view) === originalMetalView)
        #expect(view.superview === container)
        #expect(view.isUsingMetalRenderer)
    }

    @Test("Repeated same-window container reparent recreates only Metal presentation")
    func repeatedSameWindowContainerReparentRecreatesMetalView() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.bind(to: state)
        let firstHost = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let secondHost = NSView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(firstHost)
        root.addSubview(secondHost)
        firstHost.addSubview(container)

        let window = makeWindow(containing: root)
        defer {
            tab.stop()
            window.contentView = nil
        }
        guard let view = tab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        guard view.isUsingMetalRenderer,
              var previousMetalView = firstMetalView(in: view) else {
            return
        }
        let originalTerminal = view.getTerminal()

        // Direct same-window moves keep both the terminal view's immediate
        // superview and its NSWindow unchanged. Exercise both directions
        // repeatedly: this is the maximize/restore presentation boundary.
        for index in 0..<20 {
            let destination = index.isMultiple(of: 2) ? secondHost : firstHost
            destination.addSubview(container)
            guard let recreatedMetalView = firstMetalView(in: view) else {
                Issue.record("Reparented terminal lost its Metal view")
                return
            }
            #expect(recreatedMetalView !== previousMetalView)
            #expect(view.getTerminal() === originalTerminal)
            #expect(view.superview === container)
            #expect(container.superview === destination)
            #expect(view.isUsingMetalRenderer)
            previousMetalView = recreatedMetalView
        }
    }

    @Test("Cross-pane tab move recreates Metal presentation and preserves terminal")
    func crossPaneTabMoveRecreatesMetalPresentation() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let sourceState = TerminalPaneState()
        let movedTab = sourceState.addTab(workingDirectory: nil)
        let remainingTab = sourceState.addTab(workingDirectory: nil)
        sourceState.activeTerminalID = movedTab.id
        let destinationState = TerminalPaneState()
        let destinationExistingTab = destinationState.addTab(workingDirectory: nil)

        let source = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let destination = TerminalContainerView(
            frame: NSRect(x: 400, y: 0, width: 400, height: 300)
        )
        source.bind(to: sourceState)
        destination.bind(to: destinationState)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(source)
        root.addSubview(destination)

        let window = makeWindow(containing: root)
        defer {
            source.prepareForDismantle()
            destination.prepareForDismantle()
            movedTab.stop()
            remainingTab.stop()
            destinationExistingTab.stop()
            window.contentView = nil
        }
        #expect(source.window === window)
        #expect(destination.window === window)
        #expect(movedTab.terminalView.superview === source)
        #expect(movedTab.presentationOwner === source)
        #expect(destinationExistingTab.terminalView.superview === destination)
        #expect(destinationExistingTab.presentationOwner === destination)
        guard let view = movedTab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        guard view.isUsingMetalRenderer,
              let originalMetalView = firstMetalView(in: view) else {
            return
        }
        let originalTerminal = view.getTerminal()

        // Mirror PaneManager's add-before-remove transfer while both pane
        // hosts are already committed to the same window. The destination
        // must replace only the renderer presentation, never the session.
        destinationState.terminalTabs.append(movedTab)
        destinationState.activeTerminalID = movedTab.id
        sourceState.terminalTabs.removeAll { $0.id == movedTab.id }
        sourceState.activeTerminalID = remainingTab.id
        destination.showTab(movedTab)
        source.showTab(remainingTab)

        guard let recreatedMetalView = firstMetalView(in: view) else {
            Issue.record("Cross-pane terminal move lost its Metal view")
            return
        }
        #expect(recreatedMetalView !== originalMetalView)
        #expect(view.getTerminal() === originalTerminal)
        #expect(view.isUsingMetalRenderer)
        #expect(view.superview === destination)
        #expect(destinationState.presentationOwner === destination)
        #expect(movedTab.presentationOwner === destination)
        #expect(remainingTab.terminalView.superview === source)
        #expect(sourceState.presentationOwner === source)
        #expect(remainingTab.presentationOwner === source)
        #expect(destinationExistingTab.terminalView.superview == nil)
        #expect(destinationExistingTab.presentationOwner == nil)
    }

    @Test("Ancestor detach and same-window reattach recreates Metal presentation")
    func ancestorDetachReattachRecreatesMetalView() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.bind(to: state)
        let root = NSView(frame: container.bounds)
        root.addSubview(container)
        let window = makeWindow(containing: root)
        defer {
            tab.stop()
            window.contentView = nil
        }
        guard let view = tab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        guard view.isUsingMetalRenderer,
              let originalMetalView = firstMetalView(in: view) else { return }
        let originalTerminal = view.getTerminal()

        // Neither the terminal nor its container changes immediate superview;
        // only the ancestor presentation subtree leaves and re-enters window.
        window.contentView = nil
        window.contentView = root

        guard let recreatedMetalView = firstMetalView(in: view) else {
            Issue.record("Reattached terminal lost its Metal view")
            return
        }
        #expect(recreatedMetalView !== originalMetalView)
        #expect(view.getTerminal() === originalTerminal)
        #expect(view.superview === container)
        #expect(container.superview === root)
        #expect(view.isUsingMetalRenderer)
    }

    @Test("Direct same-window ancestor move recreates Metal presentation")
    func directSameWindowAncestorMoveRecreatesMetalView() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.bind(to: state)
        let ancestor = NSView(frame: container.bounds)
        ancestor.addSubview(container)
        let firstHost = NSView(frame: ancestor.bounds)
        let secondHost = NSView(frame: ancestor.bounds)
        firstHost.addSubview(ancestor)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(firstHost)
        root.addSubview(secondHost)
        let window = makeWindow(containing: root)
        defer {
            tab.stop()
            window.contentView = nil
        }
        guard let view = tab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        guard view.isUsingMetalRenderer,
              let originalMetalView = firstMetalView(in: view) else { return }
        let originalTerminal = view.getTerminal()

        // Moving the ancestor directly within one window leaves both the
        // terminal and container immediate superviews unchanged. AppKit only
        // reports the presentation-subtree change through the descendant's
        // same-window viewDidMoveToWindow callback.
        secondHost.addSubview(ancestor)

        guard let recreatedMetalView = firstMetalView(in: view) else {
            Issue.record("Ancestor-reparented terminal lost its Metal view")
            return
        }
        #expect(recreatedMetalView !== originalMetalView)
        #expect(view.getTerminal() === originalTerminal)
        #expect(view.superview === container)
        #expect(container.superview === ancestor)
        #expect(ancestor.superview === secondHost)
        #expect(view.isUsingMetalRenderer)
    }

    @Test("CoreGraphics redraws after direct same-window ancestor move")
    func coreGraphicsAncestorMovePreservesTerminalAndRedraws() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.bind(to: state)
        let ancestor = NSView(frame: container.bounds)
        ancestor.addSubview(container)
        let firstHost = NSView(frame: ancestor.bounds)
        let secondHost = NSView(frame: ancestor.bounds)
        firstHost.addSubview(ancestor)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(firstHost)
        root.addSubview(secondHost)
        let window = makeWindow(containing: root)
        defer {
            tab.stop()
            window.contentView = nil
        }
        guard let view = tab.terminalView as? PineTerminalView else {
            Issue.record("Terminal tab does not use PineTerminalView")
            return
        }
        view.metalRendererDisabledForTesting = true
        if view.isUsingMetalRenderer {
            try view.setUseMetal(false)
        }
        let originalTerminal = view.getTerminal()
        feed("core-graphics-probe", to: view)
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        secondHost.addSubview(ancestor)

        #expect(!view.isUsingMetalRenderer)
        #expect(view.getTerminal() === originalTerminal)
        #expect(view.superview === container)
        #expect(container.superview === ancestor)
        #expect(ancestor.superview === secondHost)
        #expect(redrawRequests >= 1)
    }

    @Test("Ordinary resize does not recreate Metal view")
    func resizeKeepsMetalRenderer() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer,
              let originalMetalView = firstMetalView(in: view) else {
            window.contentView = nil
            return
        }

        view.setFrameSize(NSSize(width: 640, height: 240))
        view.layoutSubtreeIfNeeded()
        view.requestRendererDisplay()

        #expect(firstMetalView(in: view) === originalMetalView)
        #expect(view.isUsingMetalRenderer)
        window.contentView = nil
    }

    // MARK: - First-output recovery (#1135)

    @Test("OSC title does not consume Metal recovery before visible output")
    func delayedFirstOutputRearmsMetalRecovery() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer else {
            window.contentView = nil
            return
        }

        // Model a slow zsh/oh-my-zsh startup: the view-attachment recovery
        // window has fully elapsed before the first prompt bytes arrive.
        try? await Task.sleep(for: .milliseconds(450))
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        // Shells commonly publish OSC metadata before drawing their prompt.
        // Metadata alone must not spend the one visible-content recovery.
        feed("\u{1B}]2;pine-title\u{07}", to: view)
        try? await Task.sleep(for: .milliseconds(450))
        #expect(redrawRequests == 0)

        feed("pine> ", to: view)
        try? await Task.sleep(for: .milliseconds(450))

        #expect(redrawRequests == UITimings.Render.terminalFirstFrameRetryDelays.count)
        window.contentView = nil
    }

    @Test("CoreGraphics recovery ignores empty and subsequent PTY chunks")
    func firstOutputRecoveryIsOneShotAndIgnoresEmptyChunks() throws {
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = makeWindow(containing: view)
        if view.isUsingMetalRenderer {
            try view.setUseMetal(false)
        }
        #expect(!view.isUsingMetalRenderer)

        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        let emptyBytes: [UInt8] = []
        view.dataReceived(slice: emptyBytes[...])
        #expect(redrawRequests == 0)

        feed("first", to: view)
        #expect(redrawRequests == 1)

        feed("second", to: view)
        #expect(redrawRequests == 1)
        window.contentView = nil
    }

    @Test("Detaching cancels first-output retries and reattaching starts a fresh batch")
    func detachCancelsFirstOutputRetriesAndReattachRecovers() async {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = makeWindow(containing: view)
        guard view.isUsingMetalRenderer else {
            window.contentView = nil
            return
        }

        // Isolate the output-triggered batch from the original attachment.
        try? await Task.sleep(for: .milliseconds(450))
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        feed("pine> ", to: view)
        // All retry work is asynchronous, so a synchronous detach must cancel
        // even the zero-delay item before it can touch the orphaned MTKView.
        window.contentView = nil
        try? await Task.sleep(for: .milliseconds(450))
        #expect(redrawRequests == 0)

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

    private func feed(_ text: String, to view: PineTerminalView) {
        let bytes = Array(text.utf8)
        view.dataReceived(slice: bytes[...])
    }

    private func makeThemeSettings() throws -> TerminalThemeSettings {
        let suiteName = "TerminalMetalThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalThemeSettings(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
    }

    private func waitForThemeRepaint(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
