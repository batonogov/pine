//
//  TerminalDisplayRecoveryTests.swift
//  PineTests
//
//  Tests for the user-invoked display recovery that rescues a terminal whose
//  renderer stopped presenting frames while its shell keeps running (#1472).
//
//  The failure being recovered from lives in SwiftTerm's Metal renderer: both
//  refusal paths in `MetalTerminalRenderer.draw(in:)` (busy frame semaphore,
//  missing drawable) set the pending-redraw flag without submitting a command
//  buffer, and only that command buffer's completion handler consumes the
//  flag. Nothing Pine can invalidate escapes it, so recovery must rebuild the
//  renderer rather than merely repaint — that distinction is what these tests
//  pin down.
//

import Testing
import AppKit
import Foundation
import MetalKit
import SwiftTerm
@testable import Pine

@Suite("Terminal Display Recovery Tests")
@MainActor
struct TerminalDisplayRecoveryTests {

    // MARK: - View-level recovery

    @Test("Recovery is inert while detached from a window")
    func recoveryWithoutWindowIsInert() throws {
        // A detached view has no presentation layer to rebuild, and
        // `viewDidMoveToWindow` repaints on the next attachment anyway.
        // Requesting a frame here would be wasted work against a dead layer.
        let view = PineTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200)
        )
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        view.recoverRendererNow()

        #expect(redrawRequests == 0)
        #expect(view.isUsingMetalRenderer == false)
    }

    @Test("Recovery under CoreGraphics repaints exactly once")
    func coreGraphicsRecoveryRepaintsOnce() throws {
        // CoreGraphics has no refusal trap, so recovery must not churn the
        // backend — one repaint through the bridge is necessary and enough.
        let tab = TerminalTab(name: "recover-core-graphics")
        let view = try #require(tab.terminalView as? PineTerminalView)
        view.metalRendererDisabledForTesting = true
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        view.recoverRendererNow()

        #expect(redrawRequests == 1)
        #expect(view.isUsingMetalRenderer == false)
    }

    @Test("Recovery on a zero-sized view does not crash")
    func recoveryOnZeroSizedViewIsSafe() throws {
        // A collapsed split leaves a real window attachment behind a 0×0 view.
        // Recovery runs there (the user cannot tell it is collapsed) and must
        // stay safe rather than assume a valid drawable size.
        let view = PineTerminalView(frame: .zero)
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }

        view.recoverRendererNow()
        view.recoverRendererNow()

        #expect(Bool(true))
    }

    @Test("Metal recovery installs a new MTKView and keeps the buffer")
    func metalRecoveryRebuildsRendererPreservingBuffer() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let tab = TerminalTab(name: "recover-metal")
        let view = try #require(tab.terminalView as? PineTerminalView)
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        guard view.isUsingMetalRenderer else { return }

        let probe = "pine recovery probe"
        view.getTerminal().feed(text: probe + "\r\n")
        let before = Set(metalViewIdentities(in: view))

        view.recoverRendererNow()

        // Rebuilding is the whole point: a recovery that reuses the existing
        // MTKView would re-enter the same refusal and change nothing. SwiftTerm
        // defers removing the outgoing view until the replacement has drawn,
        // so assert a *new* view appeared rather than that the old one is gone.
        let after = Set(metalViewIdentities(in: view))
        #expect(!after.subtracting(before).isEmpty)
        #expect(view.isUsingMetalRenderer)
        // The PTY, Terminal, and scrollback must survive — recovery is a
        // repaint of the session, not a reset of it.
        #expect(bufferText(of: view).contains(probe))
    }

    @Test("Repeated Metal recovery stays stable and lossless")
    func repeatedMetalRecoveryIsStable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let tab = TerminalTab(name: "recover-metal-repeat")
        let view = try #require(tab.terminalView as? PineTerminalView)
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        guard view.isUsingMetalRenderer else { return }

        let probe = "repeat probe"
        view.getTerminal().feed(text: probe + "\r\n")

        // A user who sees nothing happen will press the shortcut repeatedly;
        // that must not degrade into a broken renderer or a lost buffer.
        for _ in 0..<5 {
            view.recoverRendererNow()
        }

        #expect(view.isUsingMetalRenderer)
        #expect(bufferText(of: view).contains(probe))
    }

    // MARK: - Tab-level recovery

    @Test("Tab recovery repaints through the backend-aware bridge")
    func tabRecoveryRepaints() throws {
        let tab = TerminalTab(name: "recover-tab")
        let view = try #require(tab.terminalView as? PineTerminalView)
        view.metalRendererDisabledForTesting = true
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        tab.recoverDisplay()

        #expect(redrawRequests >= 1)
    }

    @Test("Tab recovery is safe on a terminated tab")
    func tabRecoveryOnTerminatedTabIsSafe() throws {
        // A closed-but-still-listed tab keeps its scrollback and is worth
        // repainting, but has no child left to receive SIGWINCH. Recovery must
        // not fault on the closed PTY descriptor.
        let tab = TerminalTab(name: "recover-terminated")
        let view = try #require(tab.terminalView as? PineTerminalView)
        view.metalRendererDisabledForTesting = true
        let window = makeWindow(containing: view)
        defer { window.contentView = nil }
        tab.stop()
        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        tab.recoverDisplay()

        #expect(redrawRequests >= 1)
        #expect(tab.isProcessRunning == false)
    }

    @Test("Tab recovery is safe before the PTY ever started")
    func tabRecoveryBeforeStartIsSafe() throws {
        // Reaching for the command on a pane that never got a shell (the exact
        // situation a confused user is in) must not fault on an absent process.
        let tab = TerminalTab(name: "recover-unstarted")
        let view = try #require(tab.terminalView as? PineTerminalView)
        view.metalRendererDisabledForTesting = true

        tab.recoverDisplay()

        #expect(tab.isProcessRunning == false)
        #expect(view.isUsingMetalRenderer == false)
    }

    // MARK: - Manager-level scope

    @Test("Manager recovery skips background tabs in the same pane")
    func managerRecoveryTargetsOnlyActiveTabs() throws {
        let paneManager = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = paneManager
        let paneID = paneManager.createTerminalPaneAtBottom(
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let state = try #require(paneManager.terminalState(for: paneID))
        let background = try #require(state.activeTab)
        let active = state.addTab(workingDirectory: URL(fileURLWithPath: "/tmp"))
        defer {
            background.stop()
            active.stop()
        }

        var backgroundRedraws = 0
        var activeRedraws = 0
        (background.terminalView as? PineTerminalView)?
            .backendRedrawRequestObserver = { backgroundRedraws += 1 }
        (active.terminalView as? PineTerminalView)?
            .backendRedrawRequestObserver = { activeRedraws += 1 }

        manager.recoverVisibleTerminalDisplays()

        // The background tab is detached; rebuilding its renderer would cost a
        // GPU round-trip for pixels nobody can see, and its own re-attach
        // already repaints it.
        #expect(state.activeTerminalID == active.id)
        #expect(activeRedraws >= 1)
        #expect(backgroundRedraws == 0)
    }

    @Test("Manager recovery covers every terminal pane, not just the focused one")
    func managerRecoveryCoversAllPanes() throws {
        let paneManager = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = paneManager
        let firstPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let secondPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let firstTab = try #require(
            paneManager.terminalState(for: firstPane)?.activeTab
        )
        let secondTab = try #require(
            paneManager.terminalState(for: secondPane)?.activeTab
        )
        defer {
            firstTab.stop()
            secondTab.stop()
        }
        var firstRedraws = 0
        var secondRedraws = 0
        (firstTab.terminalView as? PineTerminalView)?
            .backendRedrawRequestObserver = { firstRedraws += 1 }
        (secondTab.terminalView as? PineTerminalView)?
            .backendRedrawRequestObserver = { secondRedraws += 1 }

        manager.recoverVisibleTerminalDisplays()

        // The stuck pane is frequently not the focused one; a user reaching for
        // this command should not have to guess which pane to click first.
        #expect(firstRedraws >= 1)
        #expect(secondRedraws >= 1)
    }

    @Test("Manager recovery without a pane manager is a no-op")
    func managerRecoveryWithoutPaneManagerIsNoOp() {
        let manager = TerminalManager()

        manager.recoverVisibleTerminalDisplays()

        #expect(manager.allTerminalTabs.isEmpty)
    }

    @Test("Manager recovery after permanent shutdown is a no-op")
    func managerRecoveryAfterShutdownIsNoOp() throws {
        let paneManager = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = paneManager
        let paneID = paneManager.createTerminalPaneAtBottom(
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let tab = try #require(paneManager.terminalState(for: paneID)?.activeTab)
        manager.shutdownPermanently()
        var redrawRequests = 0
        (tab.terminalView as? PineTerminalView)?
            .backendRedrawRequestObserver = { redrawRequests += 1 }

        manager.recoverVisibleTerminalDisplays()

        // Post-shutdown the PTYs are gone; repainting their corpses would
        // resurrect work the reclamation path deliberately ended.
        #expect(redrawRequests == 0)
    }

    // MARK: - Helpers

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

    private func metalViewIdentities(in view: NSView) -> [ObjectIdentifier] {
        var found: [ObjectIdentifier] = []
        if let metalView = view as? MTKView {
            found.append(ObjectIdentifier(metalView))
        }
        for subview in view.subviews {
            found.append(contentsOf: metalViewIdentities(in: subview))
        }
        return found
    }

    private func bufferText(of view: PineTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString() }
            .joined(separator: "\n")
    }
}
