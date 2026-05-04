//
//  TerminalTabTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

/// Tests for TerminalTab, TerminalContainerView, TerminalTabDelegate.
@Suite("TerminalTab Tests")
struct TerminalTabTests {

    // MARK: - TerminalTab lifecycle

    @Test @MainActor func terminalTabInitialState() {
        let tab = TerminalTab(name: "zsh")
        #expect(tab.name == "zsh")
        #expect(tab.isTerminated == false)
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test @MainActor func terminalTabsHaveUniqueIDs() {
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")
        #expect(tab1.id != tab2.id)
        #expect(tab1 != tab2)
    }

    @Test @MainActor func terminalTabHashable() {
        let tab = TerminalTab(name: "test")
        var set: Set<TerminalTab> = [tab, tab]
        #expect(set.count == 1)
    }

    @Test @MainActor func stopSetsTerminatedIdempotently() {
        let tab = TerminalTab(name: "test")
        tab.stop()
        #expect(tab.isTerminated == true)
        tab.stop() // second call should not crash
        #expect(tab.isTerminated == true)
    }

    // MARK: - Search navigation with empty matches

    @Test @MainActor func nextMatchNoOpWithoutMatches() {
        let tab = TerminalTab(name: "test")
        tab.nextMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test @MainActor func previousMatchNoOpWithoutMatches() {
        let tab = TerminalTab(name: "test")
        tab.previousMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test @MainActor func clearSearchResetsState() {
        let tab = TerminalTab(name: "test")
        tab.clearSearch()
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    // MARK: - TerminalContainerView

    @Test func showTabNilClearsSubviews() {
        let container = TerminalContainerView()
        container.showTab(nil)
        #expect(container.subviews.isEmpty)
    }

    @Test @MainActor func showTabAddsTerminalView() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        #expect(container.subviews.contains(tab.terminalView))
        #expect(container.subviews.contains { $0 is TerminalScrollInterceptor })
        #expect(container.subviews.count == 2)
    }

    @Test @MainActor func showSameTabTwiceIsNoOp() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        container.showTab(tab)
        #expect(container.subviews.count == 2)
        #expect(container.subviews.contains(tab.terminalView))
    }

    @Test @MainActor func switchTabsReplacesSubview() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")

        container.showTab(tab1)
        container.showTab(tab2)
        #expect(container.subviews.count == 2)
        #expect(container.subviews.contains(tab2.terminalView))
        #expect(!container.subviews.contains(tab1.terminalView))
    }

    // MARK: - TerminalContainerView scroll monitor lifecycle

    @Test @MainActor func showTabNilClearsScrollInterceptorTerminalView() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        // Now clear
        container.showTab(nil)
        #expect(container.subviews.isEmpty)
    }

    @Test @MainActor func showTabSetsInterceptorFrameToContainerBounds() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)

        let interceptor = container.subviews.compactMap { $0 as? TerminalScrollInterceptor }.first
        #expect(interceptor != nil)
        #expect(interceptor?.frame == container.bounds)
    }

    @Test @MainActor func showTabSetsTerminalViewFrameToContainerBounds() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        #expect(tab.terminalView.frame == container.bounds)
    }

    @Test @MainActor func containerViewSubviewOrderIsTerminalThenInterceptor() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)

        #expect(container.subviews.count == 2)
        #expect(container.subviews[0] === tab.terminalView)
        #expect(container.subviews[1] is TerminalScrollInterceptor)
    }

    @Test @MainActor func removeFromSuperviewCleansUpContainer() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        parent.addSubview(container)

        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        #expect(container.subviews.count == 2)

        container.removeFromSuperview()
        #expect(container.superview == nil)
    }

    @Test @MainActor func switchingTabsUpdatesInterceptorTerminalView() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")

        container.showTab(tab1)
        let interceptorAfterTab1 = container.subviews.compactMap { $0 as? TerminalScrollInterceptor }.first
        #expect(interceptorAfterTab1?.terminalView === tab1.terminalView)

        container.showTab(tab2)
        let interceptorAfterTab2 = container.subviews.compactMap { $0 as? TerminalScrollInterceptor }.first
        #expect(interceptorAfterTab2?.terminalView === tab2.terminalView)
    }

    @Test func containerIsFlipped() {
        let container = TerminalContainerView()
        #expect(container.isFlipped == true)
    }

    // MARK: - TerminalScrollInterceptor mouse forwarding

    @Test func interceptorTerminalViewIsNilByDefault() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.terminalView == nil)
    }

    @Test func interceptorDoesNotAcceptFirstResponder() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.acceptsFirstResponder == false)
    }

    @Test func interceptorIsFlipped() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.isFlipped == true)
    }

    @Test func interceptorHitTestInsideBoundsReturnsSelf() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 400, y: 150))
        #expect(result === interceptor)
    }

    @Test func interceptorHitTestOutsideBoundsReturnsNil() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 900, y: 400))
        #expect(result == nil)
    }

    @Test func interceptorHitTestAtBoundaryEdge() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        // Point at (0,0) should be inside
        let result = interceptor.hitTest(NSPoint(x: 0, y: 0))
        #expect(result === interceptor)
    }

    @Test func interceptorHitTestAtExactBoundary() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        // Point at (800,300) is outside bounds (bounds is 0..<800, 0..<300)
        let result = interceptor.hitTest(NSPoint(x: 800, y: 300))
        #expect(result == nil)
    }

    // MARK: - TerminalTabDelegate

    @Test @MainActor func delegateSetTerminalTitle() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "original")
        delegate.tab = tab

        delegate.setTerminalTitle(source: LocalProcessTerminalView(frame: .zero), title: "new title")
        #expect(tab.name == "new title")
    }

    @Test @MainActor func delegateProcessTerminatedSetsFlag() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        delegate.processTerminated(source: tab.terminalView, exitCode: 0)
        #expect(tab.isTerminated == true)
    }

    @Test @MainActor func delegateProcessTerminatedWithNonZeroExitCode() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        delegate.processTerminated(source: tab.terminalView, exitCode: 127)
        #expect(tab.isTerminated == true)
    }

    @Test func delegateHandlesNilTabGracefully() {
        let delegate = TerminalTabDelegate()
        delegate.tab = nil
        // Should not crash when tab is nil
        delegate.processTerminated(source: LocalProcessTerminalView(frame: .zero), exitCode: 0)
        delegate.setTerminalTitle(source: LocalProcessTerminalView(frame: .zero), title: "test")
    }

    // MARK: - Terminal Focus on Click (issue #558)

    /// Helper: creates an off-screen window containing the given view.
    private func makeWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }

    /// Helper: synthesizes a left mouseDown event targeted at the given window.
    private func makeMouseDownEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 400, y: 300),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))
    }

    @Test @MainActor func mouseDownOnInterceptorFocusesTerminalView() throws {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        interceptor.terminalView = terminalView

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.addSubview(terminalView)
        host.addSubview(interceptor)
        let window = makeWindow(contentView: host)

        let event = try makeMouseDownEvent(in: window)
        interceptor.mouseDown(with: event)

        #expect(window.firstResponder === terminalView)
    }

    @Test @MainActor func mouseDownWithNilTerminalViewSafe() throws {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        interceptor.terminalView = nil

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.addSubview(interceptor)
        let window = makeWindow(contentView: host)

        let event = try makeMouseDownEvent(in: window)
        // Should not crash
        interceptor.mouseDown(with: event)
        // First responder stays as window default (not the interceptor)
        #expect(window.firstResponder !== interceptor)
    }

    @Test @MainActor func rightMouseDownOnInterceptorFocusesTerminalView() throws {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        interceptor.terminalView = terminalView

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.addSubview(terminalView)
        host.addSubview(interceptor)
        let window = makeWindow(contentView: host)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 400, y: 300),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))
        interceptor.rightMouseDown(with: event)

        #expect(window.firstResponder === terminalView)
    }

    @Test @MainActor func clickToFocusFirstTab() throws {
        let state = TerminalPaneState()
        state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        // After startTabs, pendingFocusTabID was set by addTab
        state.pendingFocusTabID = nil

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let window = makeWindow(contentView: container)

        // Find the scroll interceptor
        let interceptor = try #require(
            container.subviews.compactMap { $0 as? TerminalScrollInterceptor }.first
        )

        let event = try makeMouseDownEvent(in: window)
        interceptor.mouseDown(with: event)

        // The terminal view should become first responder via click
        let activeTab = try #require(state.activeTab)
        #expect(window.firstResponder === activeTab.terminalView)
    }

    @Test @MainActor func focusAfterTabSwitchViaClick() throws {
        let state = TerminalPaneState()
        let tab1 = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state

        // Show tab1
        container.showTab(state.activeTab)
        let window = makeWindow(contentView: container)

        // Add tab2 and consume pendingFocus
        let tab2 = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab)
        // pendingFocusTabID was consumed by showTab
        #expect(state.pendingFocusTabID == nil)

        // Now switch back to tab1 via activeTerminalID (simulating tab bar click)
        state.activeTerminalID = tab1.id
        // No pendingFocusTabID set — simulates clicking the terminal area to focus
        container.showTab(state.activeTab)

        // Click on the interceptor to focus
        let interceptor = try #require(
            container.subviews.compactMap { $0 as? TerminalScrollInterceptor }.first
        )

        let event = try makeMouseDownEvent(in: window)
        interceptor.mouseDown(with: event)

        _ = tab2 // suppress unused warning
        #expect(window.firstResponder === tab1.terminalView)
    }

    // MARK: - pendingFocusTabID consumption

    @Test @MainActor func showTabConsumesPendingFocus() throws {
        let state = TerminalPaneState()
        state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        let newTab = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == newTab.id)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state
        container.showTab(newTab)

        #expect(state.pendingFocusTabID == nil)
    }

    @Test @MainActor func showTabDoesNotConsumeMismatchedPendingFocus() throws {
        let state = TerminalPaneState()
        let firstTab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        let newTab = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == newTab.id)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state
        // Show the first tab, not the one with pending focus
        container.showTab(firstTab)

        // pendingFocusTabID should still be set to the new tab
        #expect(state.pendingFocusTabID == newTab.id)
    }

    @Test @MainActor func showTabWithoutPendingFocusNoCrash() {
        let state = TerminalPaneState()
        state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        state.pendingFocusTabID = nil

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state
        // Should not crash
        container.showTab(state.activeTab)
        #expect(state.pendingFocusTabID == nil)
    }

    // MARK: - Blank terminal fix (issue #661)

    @Test @MainActor func startIfNeededGuardsZeroFrame() {
        // Terminal created with default 800×300 frame
        let tab = TerminalTab(name: "test")
        // Override to zero to simulate the bug scenario
        tab.terminalView.frame = .zero
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        // Process should NOT have started because frame is zero
        #expect(!tab.isProcessRunning)
    }

    @Test @MainActor func startIfNeededGuardsZeroWidth() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 0, height: 300)
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        #expect(!tab.isProcessRunning)
    }

    @Test @MainActor func startIfNeededGuardsZeroHeight() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 0)
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        #expect(!tab.isProcessRunning)
    }

    @Test @MainActor func startIfNeededRetriesAfterResize() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = .zero
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        #expect(!tab.isProcessRunning)

        // Now give it a real frame and try again
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.startIfNeeded()
        // Process should have started now
        #expect(tab.isProcessRunning)
    }

    @Test @MainActor func showTabFallbackBoundsOnZeroContainer() {
        let container = TerminalContainerView(frame: .zero)
        let tab = TerminalTab(name: "test")
        container.showTab(tab)

        // Terminal view should get the default fallback frame, not zero
        let fallback = TerminalContainerView.defaultTerminalFrame
        #expect(tab.terminalView.frame.size.width == fallback.size.width)
        #expect(tab.terminalView.frame.size.height == fallback.size.height)
    }

    @Test @MainActor func showTabUsesRealBounds() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)

        #expect(tab.terminalView.frame.size.width == 1024)
        #expect(tab.terminalView.frame.size.height == 768)
    }

    @Test @MainActor func layoutZeroBoundsDoesNotStart() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        // Give terminal view a zero frame to simulate the issue
        tab.terminalView.frame = .zero

        let container = TerminalContainerView(frame: .zero)
        container.terminalPaneState = state
        container.showTab(tab)

        // Trigger layout with zero bounds
        container.layout()

        // Process should NOT have started
        #expect(!tab.isProcessRunning)
    }

    @Test @MainActor func layoutNonZeroBoundsStartsProcess() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        // Trigger layout with valid bounds
        container.layout()

        #expect(tab.isProcessRunning)
    }

    @Test @MainActor func layoutUpdatesFrame() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)
        container.layout()

        // Now resize container
        container.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        container.layout()

        #expect(tab.terminalView.frame.size.width == 1200)
        #expect(tab.terminalView.frame.size.height == 600)
    }

    @Test @MainActor func processStartsWithFallbackFrameAfterShowTabOnZeroContainer() throws {
        // Integration test: showTab on a zero-bounds container uses the fallback
        // frame, and a subsequent layout with real bounds starts the process.
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        // Container starts with zero bounds (simulates first SwiftUI layout pass)
        let container = TerminalContainerView(frame: .zero)
        container.terminalPaneState = state
        container.showTab(tab)

        // showTab should have used the fallback frame
        let fallback = TerminalContainerView.defaultTerminalFrame
        #expect(tab.terminalView.frame.size.width == fallback.size.width)
        #expect(tab.terminalView.frame.size.height == fallback.size.height)

        // Process should NOT be running yet (layout hasn't happened with real bounds)
        #expect(!tab.isProcessRunning)

        // Simulate the container getting a real size from SwiftUI
        container.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        container.layout()

        // Now the process should have started with the real frame
        #expect(tab.isProcessRunning)
        #expect(tab.terminalView.frame.size.width == 1024)
        #expect(tab.terminalView.frame.size.height == 768)
    }

    // MARK: - Blank second-tab fix (issue #918)

    /// Adding a second tab to an existing pane (with non-zero bounds) must
    /// start the new tab's PTY immediately. Without this, the new tab paints
    /// blank because AppKit does not call `layout()` again — bounds did not
    /// change — and `startIfNeeded()` is otherwise only invoked from `layout()`.
    @Test @MainActor func showTabStartsProcessWhenContainerHasRealBounds() throws {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)
        // First tab's process must be running purely as a result of `showTab`,
        // *without* AppKit calling `layout()`. This is the load-bearing
        // assertion for issue #918: previously `startIfNeeded()` only ran
        // inside `layout()`.
        let firstTab = try #require(state.activeTab)
        #expect(firstTab.isProcessRunning)
    }

    /// Reproduction of issue #918: after the first terminal tab has rendered,
    /// adding a second tab in the same pane must NOT leave the second
    /// terminal blank. The second tab's PTY must be started by `showTab`
    /// itself, not deferred until the next `layout()` (which never comes
    /// because the container's bounds did not change).
    @Test @MainActor func addingSecondTabStartsItsProcessImmediately() throws {
        let state = TerminalPaneState()
        let firstTab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)
        #expect(firstTab.isProcessRunning, "First tab's process must run after initial showTab")

        // User clicks `+` — TerminalPaneState appends a new tab and flips
        // activeTerminalID to it. SwiftUI then calls `updateNSView` which
        // calls `showTab(state.activeTab)` again with the brand-new tab.
        let secondTab = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab)

        // The second tab MUST have started — issue #918 was that this only
        // happened after a manual resize because `startIfNeeded()` was gated
        // behind `layout()`.
        #expect(secondTab.isProcessRunning, "Second tab's process must start without waiting for layout()")
        // First tab is still running; we did not stop it.
        #expect(firstTab.isProcessRunning, "First tab keeps running while the second tab is active")
    }

    /// After the second tab's process has started, switching back to the
    /// first tab must keep the first tab attached and visible. Previously the
    /// first tab's `terminalView` was detached (`removeFromSuperview`) and
    /// its CALayer could lose backing, leaving an empty pane.
    @Test @MainActor func switchingBackToFirstTabKeepsItRunning() throws {
        let state = TerminalPaneState()
        let firstTab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let secondTab = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab) // installs second tab

        // Simulate clicking on the first tab in the tab bar.
        state.activeTerminalID = firstTab.id
        container.showTab(state.activeTab)

        #expect(container.subviews.contains(firstTab.terminalView),
                "First tab's view must be re-attached to the container")
        #expect(!container.subviews.contains(secondTab.terminalView),
                "Second tab's view must be detached when first tab is active")
        #expect(firstTab.isProcessRunning, "First tab's PTY must still be running")
        #expect(secondTab.isProcessRunning, "Second tab's PTY must still be running")
    }

    /// `showTab` must be idempotent: calling it twice with the same tab and
    /// non-zero bounds must not spawn a second process or duplicate subviews.
    @Test @MainActor func showTabIsIdempotentForSameTab() throws {
        let tab = TerminalTab(name: "test")
        tab.configure(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.showTab(tab)
        #expect(tab.isProcessRunning)
        let pidAfterFirst = tab.terminalView.process.shellPid

        container.showTab(tab) // no-op
        #expect(container.subviews.count == 2,
                "Repeated showTab must not duplicate subviews")
        #expect(tab.isProcessRunning,
                "Repeated showTab must not stop the running process")
        #expect(tab.terminalView.process.shellPid == pidAfterFirst,
                "Repeated showTab must not respawn the process")
    }

    /// `showTab(nil)` must clear all subviews even after a tab was previously
    /// installed and started. Edge case: closing the last terminal tab.
    @Test @MainActor func showNilAfterRunningTabClearsSubviews() throws {
        let tab = TerminalTab(name: "test")
        tab.configure(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.showTab(tab)
        #expect(tab.isProcessRunning)

        container.showTab(nil)
        #expect(container.subviews.isEmpty,
                "showTab(nil) must remove all subviews including a running terminal")
    }

    /// `showTab` must not spawn a process when the container has zero bounds —
    /// the fallback frame is a placeholder, not a real layout. The PTY must
    /// be started by the next `layout()` call with real bounds.
    @Test @MainActor func showTabDoesNotStartProcessOnZeroBoundsContainer() throws {
        let tab = TerminalTab(name: "test")
        tab.configure(workingDirectory: nil)

        let container = TerminalContainerView(frame: .zero)
        container.showTab(tab)
        #expect(!tab.isProcessRunning,
                "Process must not start while the container has zero bounds")
    }

    /// Stress test: rapidly creating, switching, and closing tabs must keep
    /// every running tab attached or cleanly detached, with no leaked
    /// subviews and no duplicated processes.
    @Test @MainActor func rapidTabSwitchingMaintainsConsistency() throws {
        let state = TerminalPaneState()
        let tab1 = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let tab2 = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab)

        let tab3 = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab)

        // Switch through them in a tight loop.
        for id in [tab1.id, tab2.id, tab3.id, tab1.id, tab3.id] {
            state.activeTerminalID = id
            container.showTab(state.activeTab)
        }

        // Container must always hold exactly one terminal view + one
        // interceptor, regardless of how many tabs exist in the model.
        #expect(container.subviews.count == 2,
                "Container must hold exactly two subviews (terminalView + interceptor)")
        // The currently active tab is tab3 (last switch). Its view must be
        // attached; the others must be detached.
        #expect(container.subviews.contains(tab3.terminalView))
        #expect(!container.subviews.contains(tab1.terminalView))
        #expect(!container.subviews.contains(tab2.terminalView))
        // All three PTYs are alive.
        #expect(tab1.isProcessRunning)
        #expect(tab2.isProcessRunning)
        #expect(tab3.isProcessRunning)
    }
}
