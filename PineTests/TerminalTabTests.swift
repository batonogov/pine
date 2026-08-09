//
//  TerminalTabTests.swift
//  PineTests
//

import Darwin
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

    @Test @MainActor func terminalTabUsesPineTerminalView() {
        let tab = TerminalTab(name: "zsh")
        #expect(tab.terminalView is PineTerminalView)
    }

    @Test @MainActor func terminalTabsHaveUniqueIDs() {
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")
        #expect(tab1.id != tab2.id)
        #expect(tab1 != tab2)
    }

    @Test("acknowledged PTY write retains its descriptor identity")
    func acknowledgedWriteOwnsDescriptor() async throws {
        var pipeDescriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&pipeDescriptors) == 0)
        let readDescriptor = pipeDescriptors[0]
        let borrowedDescriptor = pipeDescriptors[1]
        defer { Darwin.close(readDescriptor) }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let expected = Array("resume\n".utf8)
        let writeTask = Task.detached {
            await AcknowledgedPTYWriter.writeForTesting(
                expected,
                to: borrowedDescriptor
            ) {
                acquired.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        let didAcquire = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: acquired.wait(timeout: .now() + 1) == .success
                )
            }
        }
        try #require(didAcquire)
        Darwin.close(borrowedDescriptor)
        let replacement = Darwin.open(
            temporaryURL.path,
            O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
            mode_t(0o600)
        )
        try #require(replacement >= 0)
        let reusedDescriptor: Int32
        if replacement == borrowedDescriptor {
            reusedDescriptor = replacement
        } else {
            try #require(Darwin.dup2(replacement, borrowedDescriptor) >= 0)
            Darwin.close(replacement)
            reusedDescriptor = borrowedDescriptor
        }
        defer { Darwin.close(reusedDescriptor) }
        release.signal()

        #expect(await writeTask.value)
        var received = [UInt8](repeating: 0, count: expected.count)
        let readCount = received.withUnsafeMutableBytes { bytes in
            Darwin.read(readDescriptor, bytes.baseAddress, bytes.count)
        }
        #expect(readCount == expected.count)
        #expect(received == expected)
        #expect((try? Data(contentsOf: temporaryURL)).map(\.isEmpty) == true)
    }

    @Test("partial and failed PTY completions are never acknowledged")
    func incompletePTYWriteIsRejected() {
        #expect(
            AcknowledgedPTYWriter.acknowledgesCompletion(
                error: 0,
                remainingByteCount: 0
            )
        )
        #expect(
            !AcknowledgedPTYWriter.acknowledgesCompletion(
                error: 0,
                remainingByteCount: 1
            )
        )
        #expect(
            !AcknowledgedPTYWriter.acknowledgesCompletion(
                error: EIO,
                remainingByteCount: 0
            )
        )
    }

    @Test("reused borrowed PTY descriptor is rejected before duplication")
    func reusedBorrowedDescriptorIsRejected() throws {
        var pipeDescriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&pipeDescriptors) == 0)
        let readDescriptor = pipeDescriptors[0]
        let borrowedDescriptor = pipeDescriptors[1]
        defer { Darwin.close(readDescriptor) }
        let expectedIdentity = try #require(
            AcknowledgedPTYWriter.descriptorIdentity(borrowedDescriptor)
        )
        Darwin.close(borrowedDescriptor)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let replacement = Darwin.open(
            temporaryURL.path,
            O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
            mode_t(0o600)
        )
        try #require(replacement >= 0)
        let reusedDescriptor: Int32
        if replacement == borrowedDescriptor {
            reusedDescriptor = replacement
        } else {
            try #require(Darwin.dup2(replacement, borrowedDescriptor) >= 0)
            Darwin.close(replacement)
            reusedDescriptor = borrowedDescriptor
        }
        defer { Darwin.close(reusedDescriptor) }

        #expect(AcknowledgedPTYWriter.acquireDescriptor(
            reusedDescriptor,
            expectedIdentity: expectedIdentity
        ) == nil)
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

    @Test @MainActor func staleContainerCannotReclaimTabFromLiveOwner() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let first = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let second = TerminalContainerView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        first.terminalPaneState = state
        second.terminalPaneState = state

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(first)
        host.addSubview(second)
        defer {
            tab.stop()
            window.contentView = nil
        }

        first.showTab(tab)
        second.showTab(tab)
        #expect(tab.presentationOwner === second)
        #expect(tab.terminalView.superview === second)

        // Models the outgoing maximize/restore representable receiving late
        // updateNSView and layout callbacks during a structural transition.
        first.showTab(tab)
        first.layout()

        #expect(tab.presentationOwner === second)
        #expect(tab.terminalView.superview === second)
    }

    @Test @MainActor func newlyAttachedContainerCanReclaimPresentationLease() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let first = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let second = TerminalContainerView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        first.terminalPaneState = state
        second.terminalPaneState = state

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(first)
        host.addSubview(second)
        defer {
            tab.stop()
            window.contentView = nil
        }

        first.showTab(tab)
        second.showTab(tab)
        #expect(tab.presentationOwner === second)

        // Reattaching the previously used split container models restore.
        // Its window-attachment callback is the one legitimate force claim.
        first.removeFromSuperview()
        host.addSubview(first)

        #expect(tab.presentationOwner === first)
        #expect(tab.terminalView.superview === first)

        // The older live host can no longer steal the view back.
        second.showTab(tab)
        second.layout()
        #expect(tab.presentationOwner === first)
        #expect(tab.terminalView.superview === first)
    }

    @Test @MainActor func detachedContainerCannotStealFromLivePaneOwner() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let live = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let incoming = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        live.terminalPaneState = state
        incoming.terminalPaneState = state

        let host = NSView(frame: live.bounds)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(live)
        defer {
            tab.stop()
            window.contentView = nil
        }

        live.showTab(tab)
        incoming.showTab(tab)

        #expect(state.presentationOwner === live)
        #expect(tab.presentationOwner === live)
        #expect(tab.terminalView.superview === live)

        host.addSubview(incoming)

        #expect(state.presentationOwner === incoming)
        #expect(tab.presentationOwner === incoming)
        #expect(tab.terminalView.superview === incoming)
    }

    @Test @MainActor func staleContainerCannotStealNewlySelectedTab() {
        let state = TerminalPaneState()
        let firstTab = state.addTab(workingDirectory: nil)
        let secondTab = state.addTab(workingDirectory: nil)
        state.activeTerminalID = firstTab.id
        let stale = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let live = TerminalContainerView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        stale.terminalPaneState = state
        live.terminalPaneState = state

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(stale)
        host.addSubview(live)
        defer {
            firstTab.stop()
            secondTab.stop()
            window.contentView = nil
        }

        #expect(state.presentationOwner === live)
        #expect(firstTab.presentationOwner === live)

        state.activeTerminalID = secondTab.id
        live.showTab(secondTab)
        stale.showTab(secondTab)
        stale.layout()

        #expect(state.presentationOwner === live)
        #expect(secondTab.presentationOwner === live)
        #expect(secondTab.terminalView.superview === live)
    }

    @Test @MainActor func sameWindowContainerReparentReclaimsPaneLease() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let moving = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let competing = TerminalContainerView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        moving.terminalPaneState = state
        competing.terminalPaneState = state

        let firstHost = NSView(frame: moving.bounds)
        let secondHost = NSView(frame: competing.bounds)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(firstHost)
        root.addSubview(secondHost)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        firstHost.addSubview(moving)
        secondHost.addSubview(competing)
        defer {
            tab.stop()
            window.contentView = nil
        }

        #expect(state.presentationOwner === competing)
        #expect(tab.terminalView.superview === competing)

        // Direct addSubview reparents without calling moving.removeFromSuperview().
        secondHost.addSubview(moving)

        #expect(state.presentationOwner === moving)
        #expect(tab.presentationOwner === moving)
        #expect(tab.terminalView.superview === moving)

        competing.showTab(tab)
        competing.layout()
        #expect(state.presentationOwner === moving)
        #expect(tab.presentationOwner === moving)
        #expect(tab.terminalView.superview === moving)
    }

    @Test @MainActor func sameWindowAncestorReparentReclaimsPaneLease() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let reclaiming = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let outgoing = TerminalContainerView(
            frame: NSRect(x: 400, y: 0, width: 400, height: 300)
        )
        reclaiming.bind(to: state)
        outgoing.bind(to: state)

        let movingAncestor = NSView(frame: reclaiming.bounds)
        movingAncestor.addSubview(reclaiming)
        let firstHost = NSView(frame: reclaiming.bounds)
        let secondHost = NSView(frame: outgoing.bounds)
        firstHost.addSubview(movingAncestor)
        secondHost.addSubview(outgoing)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        root.addSubview(firstHost)
        root.addSubview(secondHost)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        defer {
            tab.stop()
            window.contentView = nil
        }

        outgoing.showTab(tab, forcePresentationClaim: true)
        #expect(state.presentationOwner === outgoing)
        #expect(tab.terminalView.superview === outgoing)

        // The container itself keeps the same immediate superview. AppKit
        // reports only a same-window descendant callback when its ancestor is
        // moved directly to another presentation subtree.
        secondHost.addSubview(movingAncestor)

        #expect(state.presentationOwner === reclaiming)
        #expect(tab.presentationOwner === reclaiming)
        #expect(tab.terminalView.superview === reclaiming)
        #expect(reclaiming.superview === movingAncestor)
        #expect(movingAncestor.superview === secondHost)

        outgoing.showTab(tab)
        outgoing.layout()
        #expect(state.presentationOwner === reclaiming)
        #expect(tab.presentationOwner === reclaiming)
        #expect(tab.terminalView.superview === reclaiming)
    }

    @Test @MainActor func detachedDestinationWaitsToClaimMovedTabUntilAttach() {
        let sourceState = TerminalPaneState()
        let movedTab = sourceState.addTab(workingDirectory: nil)
        let remainingTab = sourceState.addTab(workingDirectory: nil)
        sourceState.activeTerminalID = movedTab.id
        let destinationState = TerminalPaneState()
        let source = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let destination = TerminalContainerView(frame: NSRect(x: 400, y: 0, width: 400, height: 300))
        source.bind(to: sourceState)
        destination.bind(to: destinationState)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(source)
        defer {
            movedTab.stop()
            remainingTab.stop()
            window.contentView = nil
        }

        #expect(sourceState.presentationOwner === source)
        #expect(movedTab.presentationOwner === source)

        destinationState.terminalTabs.append(movedTab)
        destinationState.activeTerminalID = movedTab.id
        sourceState.terminalTabs.removeAll { $0.id == movedTab.id }
        sourceState.activeTerminalID = remainingTab.id

        destination.showTab(movedTab)
        #expect(destinationState.presentationOwner == nil)
        #expect(movedTab.presentationOwner === source)
        #expect(movedTab.terminalView.superview === source)

        host.addSubview(destination)
        source.showTab(sourceState.activeTab)

        #expect(destinationState.presentationOwner === destination)
        #expect(movedTab.presentationOwner === destination)
        #expect(movedTab.terminalView.superview === destination)
        #expect(sourceState.presentationOwner === source)
        #expect(remainingTab.presentationOwner === source)
        #expect(remainingTab.terminalView.superview === source)
    }

    @Test @MainActor func rebindingContainerReleasesPreviousPaneLease() {
        let firstState = TerminalPaneState()
        let firstTab = firstState.addTab(workingDirectory: nil)
        let secondState = TerminalPaneState()
        let secondTab = secondState.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let outgoingSecondOwner = TerminalContainerView(
            frame: NSRect(x: 400, y: 0, width: 400, height: 300)
        )
        container.bind(to: firstState)
        outgoingSecondOwner.bind(to: secondState)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.addSubview(container)
        host.addSubview(outgoingSecondOwner)
        defer {
            firstTab.stop()
            secondTab.stop()
            window.contentView = nil
        }

        #expect(firstState.presentationOwner === container)
        #expect(firstTab.presentationOwner === container)
        #expect(secondState.presentationOwner === outgoingSecondOwner)
        #expect(secondTab.presentationOwner === outgoingSecondOwner)

        let didRebind = container.bind(to: secondState)
        container.showTab(
            secondState.activeTab,
            forcePresentationClaim: didRebind && container.window != nil
        )

        #expect(firstState.presentationOwner == nil)
        #expect(firstTab.presentationOwner == nil)
        #expect(secondState.presentationOwner === container)
        #expect(secondTab.presentationOwner === container)
        #expect(secondTab.terminalView.superview === container)

        outgoingSecondOwner.showTab(secondState.activeTab)
        outgoingSecondOwner.layout()
        #expect(secondState.presentationOwner === container)
        #expect(secondTab.presentationOwner === container)
        #expect(secondTab.terminalView.superview === container)
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

        // Add tab2 and confirm focus only after AppKit accepts it.
        let tab2 = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab)
        #expect(state.pendingFocusTabID == tab2.id)
        #expect(container.destinationFocusCoordinator.attemptNow())
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

    @Test @MainActor func showTabRetainsFocusUntilResponderIsConfirmed() throws {
        let state = TerminalPaneState()
        state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        let newTab = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == newTab.id)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.terminalPaneState = state
        container.showTab(newTab)

        #expect(state.pendingFocusTabID == newTab.id)
        #expect(!container.destinationFocusCoordinator.attemptNow())
        #expect(state.pendingFocusTabID == newTab.id)

        let window = makeWindow(contentView: container)
        #expect(container.destinationFocusCoordinator.attemptNow())
        #expect(window.firstResponder === newTab.terminalView)
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

    // MARK: - Black terminal on TUI fix
    //
    // After re-parenting the terminal view (tab switch, pane split, drag,
    // window become-key, etc.) AppKit may discard the layer's backing store,
    // and TUI apps in alternate screen (k9s, htop, vim) won't redraw on
    // their own. Pine repaints from `displayBuffer` via `forceFullRedraw`
    // and (for alternate screen) raises SIGWINCH via `kickPTYWindowSize` to
    // nudge the TUI into redrawing.

    /// `forceFullRedraw` must seed SwiftTerm's dirty range so a subsequent
    /// `updateDisplay` (or our own synchronous `setNeedsDisplay`) repaints
    /// the entire visible buffer. Without this, an idle TUI in alternate
    /// screen leaves `getUpdateRange()` empty and SwiftTerm's throttled
    /// path never schedules a redraw.
    @Test @MainActor func forceFullRedrawSeedsDirtyRange() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let term = tab.terminalView.getTerminal()

        term.clearUpdateRange()
        #expect(term.getUpdateRange() == nil, "Precondition: dirty range must start empty")

        tab.forceFullRedraw()

        let range = term.getUpdateRange()
        #expect(range != nil, "forceFullRedraw must seed a non-empty dirty range")
        #expect(range?.startY == 0)
        #expect(range?.endY == term.rows)
    }

    /// `forceFullRedraw` must not crash when the terminal view has no
    /// host window — `displayIfNeeded` is a no-op in that state but the
    /// dirty-range seeding and `setNeedsDisplay` calls must still succeed.
    @Test @MainActor func forceFullRedrawSafeWithoutWindow() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        // Not added to any window/superview.
        tab.forceFullRedraw()
        #expect(tab.terminalView.window == nil)
    }

    /// `forceFullRedraw` is idempotent: calling it twice in a row must
    /// behave like calling it once — same dirty range, no crashes.
    @Test @MainActor func forceFullRedrawIdempotent() {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let term = tab.terminalView.getTerminal()

        tab.forceFullRedraw()
        tab.forceFullRedraw()

        let range = term.getUpdateRange()
        #expect(range?.startY == 0)
        #expect(range?.endY == term.rows)
    }

    /// SwiftTerm's layer background can drift from Pine's appearance-aware
    /// native background when AppKit recreates or reuses backing layers.
    /// `forceFullRedraw` must restore it before asking SwiftTerm to paint.
    @Test @MainActor func forceFullRedrawSyncsLayerBackground() {
        let tab = TerminalTab(name: "test")
        let expected = tab.terminalView.nativeBackgroundColor.cgColor
        let staleContents = "stale-terminal-backing" as NSString
        tab.terminalView.layer?.backgroundColor = NSColor.black.cgColor
        tab.terminalView.layer?.contents = staleContents

        tab.forceFullRedraw()

        #expect(tab.terminalView.layer?.backgroundColor == expected)
        #expect((tab.terminalView.layer?.contents as? NSString) != staleContents)
    }

    /// `setNeedsDisplay` promotes partial invalidations to full-bounds
    /// redraws but does NOT zero `layer.contents` — zeroing on every call
    /// created a race where AppKit cancelled the pending display cycle,
    /// leaving the layer permanently black (issue #1094). Contents are
    /// only cleared by `prepareLayerForRedraw()` / `forceFullRedraw()`,
    /// where the nil is immediately followed by synchronous
    /// `displayIfNeeded()`.
    @Test @MainActor func pineTerminalViewSetNeedsDisplayDoesNotClearContents() {
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let background = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        let existingContents = "valid-backing" as NSString
        view.nativeBackgroundColor = background
        view.prepareLayerForRedraw(background: background)
        view.layer?.contents = existingContents

        view.setNeedsDisplay(NSRect(x: 0, y: 0, width: 10, height: 10))

        // Background must be preserved, contents must NOT be nil'd.
        #expect(view.layer?.backgroundColor == background.cgColor)
        #expect(view.layer?.contents != nil)
    }

    /// `prepareLayerForRedraw` (called from `forceFullRedraw`) DOES clear
    /// stale contents — this is the safe call site because it is always
    /// followed by synchronous `displayIfNeeded()`.
    @Test @MainActor func prepareLayerForRedrawClearsStaleContents() {
        let view = PineTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let background = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        let staleContents = "stale-terminal-backing" as NSString
        view.layer?.contents = staleContents

        view.prepareLayerForRedraw(background: background)

        #expect(view.layer?.backgroundColor == background.cgColor)
        #expect(view.layer?.contents == nil)
    }

    /// `applyCurrentTerminalAppearance(forceRedraw: false)` must sync the
    /// layer background WITHOUT clearing `contents`. Clearing contents here —
    /// when no synchronous repaint follows — leaves the layer black if the
    /// window is minimized/occluded (e.g. an appearance change firing while
    /// the window is hidden). Contents clearing belongs exclusively in
    /// `forceFullRedraw()`, where a synchronous `displayIfNeeded()` always
    /// follows (issue #1107, #1094 invariant).
    @Test @MainActor func applyCurrentTerminalAppearanceDoesNotClearContentsWithoutRedraw() {
        let tab = TerminalTab(name: "test")
        let existingContents = "valid-backing" as NSString
        tab.terminalView.layer?.contents = existingContents

        tab.applyCurrentTerminalAppearance(forceRedraw: false)

        // Background must be synced to the appearance-aware native background,
        // but contents must NOT be nil'd — no synchronous repaint follows.
        let expected = tab.terminalView.nativeBackgroundColor.cgColor
        #expect(tab.terminalView.layer?.backgroundColor == expected)
        #expect((tab.terminalView.layer?.contents as? NSString) == existingContents)
    }

    /// `applyCurrentTerminalAppearance(forceRedraw: true)` keeps the safe
    /// behaviour: `forceFullRedraw()` clears stale contents and syncs the
    /// background. This pins that the `forceRedraw == true` path did not
    /// regress when the unconditional `prepareLayerForRedraw` was removed
    /// from `applyCurrentTerminalAppearance` (issue #1107).
    @Test @MainActor func applyCurrentTerminalAppearanceForceRedrawClearsContents() {
        let tab = TerminalTab(name: "test")
        let staleContents = "stale-terminal-backing" as NSString
        tab.terminalView.layer?.contents = staleContents

        tab.applyCurrentTerminalAppearance(forceRedraw: true)

        let expected = tab.terminalView.nativeBackgroundColor.cgColor
        #expect(tab.terminalView.layer?.backgroundColor == expected)
        // forceFullRedraw() runs the safe clear path (prepareLayerForRedraw +
        // synchronous repaint), so the stale backing must have been replaced.
        // Uses `!= staleContents` (not `== nil`) because SwiftTerm may repaint
        // into a fresh CGImage even on a detached view — consistent with the
        // sibling `forceFullRedrawSyncsLayerBackground` test.
        #expect((tab.terminalView.layer?.contents as? NSString) != staleContents)
    }

    // MARK: - Backing-store recovery triggers (occlusion / hide / minimize)

    /// The terminal must recover its backing store on the occluded → visible
    /// window transition only. Becoming occluded (window fully covered) must
    /// NOT trigger a repaint — it is wasteful and the window is off-screen.
    /// Pins the visible-edge decision without instantiating a live window,
    /// so CI headless runners can exercise it (issue #1094 family).
    @Test func recoverAfterOcclusionOnlyWhenBecomingVisible() {
        #expect(TerminalContainerView.shouldRecoverAfterOcclusionChange(occlusionState: [.visible]))
        #expect(!TerminalContainerView.shouldRecoverAfterOcclusionChange(occlusionState: []))
    }

    /// `kickPTYWindowSize` must be a safe no-op when the shell process is
    /// not running. Calling it on a freshly-created tab (which has not
    /// reached `startIfNeeded`) must not crash, and `isProcessRunning`
    /// must stay false.
    @Test @MainActor func kickPTYWindowSizeNoOpWhenProcessNotRunning() {
        let tab = TerminalTab(name: "test")
        // No `startIfNeeded` — process is not running.
        tab.kickPTYWindowSize()
        #expect(!tab.isProcessRunning)
    }

    /// `kickPTYWindowSize` against a running shell must not kill the
    /// process. Sending the same winsize is identical to a no-change
    /// `SIGWINCH` and is benign.
    @Test @MainActor func kickPTYWindowSizeOnRunningProcessKeepsItAlive() throws {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        try #require(tab.isProcessRunning)

        tab.kickPTYWindowSize()
        #expect(tab.isProcessRunning, "SIGWINCH with the same winsize must not terminate the shell")
    }

    /// `kickPTYWindowSize` after `stop()` must be a safe no-op — the
    /// process is no longer running and the PTY fd may be invalid.
    @Test @MainActor func kickPTYWindowSizeAfterStopIsNoOp() throws {
        let tab = TerminalTab(name: "test")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.configure(workingDirectory: nil)
        tab.startIfNeeded()
        try #require(tab.isProcessRunning)
        tab.stop()
        // Should not crash even though the PTY is being torn down.
        tab.kickPTYWindowSize()
        #expect(tab.isTerminated)
    }

    /// Switching back to a previously-active tab must seed its dirty
    /// range so the layer repaints from the buffer. Reproduces the
    /// scenario "k9s in tab1, switch to tab2, switch back to tab1 →
    /// alternate-screen buffer never redrew → blank terminal".
    @Test @MainActor func returningToPreviousTabRepaintsBuffer() throws {
        let state = TerminalPaneState()
        let tab1 = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let tab2 = state.addTab(workingDirectory: nil)
        container.showTab(state.activeTab) // installs tab2

        // Imagine tab1's TUI has been idle on alternate screen for a while —
        // its dirty range was consumed by SwiftTerm's last paint.
        tab1.terminalView.getTerminal().clearUpdateRange()
        #expect(tab1.terminalView.getTerminal().getUpdateRange() == nil)

        // User clicks tab1 in the tab bar — Pine flips active and re-shows.
        state.activeTerminalID = tab1.id
        container.showTab(state.activeTab)

        let range = tab1.terminalView.getTerminal().getUpdateRange()
        #expect(range != nil, "Returning to tab1 must seed its dirty range so the buffer repaints")
        #expect(range?.startY == 0)
        _ = tab2 // suppress unused warning
    }

    /// The first time a `TerminalContainerView` enters a window, the
    /// active tab's buffer must be marked dirty — `displayIfNeeded`
    /// inside `showTab` is a no-op while the container has no window,
    /// so `viewDidMoveToWindow` is the first chance to actually paint.
    @Test @MainActor func viewDidMoveToWindowSeedsDirtyRange() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        // Drain the dirty range that `showTab` already seeded so the
        // assertion below is about `viewDidMoveToWindow` specifically.
        tab.terminalView.getTerminal().clearUpdateRange()
        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let range = tab.terminalView.getTerminal().getUpdateRange()
        #expect(range != nil, "Attaching to a window must seed the dirty range")
        #expect(range?.startY == 0)
    }

    /// `layout()` with the same bounds twice must NOT re-trigger a
    /// forceFullRedraw — the `frameChanged` guard prevents redundant
    /// repaints on AppKit's no-op layout passes.
    @Test @MainActor func layoutWithUnchangedBoundsDoesNotReseedDirtyRange() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)
        container.layout() // first layout pass — frame changed from showTab fallback to real

        // Drain the dirty range so we can detect a re-seed unambiguously.
        tab.terminalView.getTerminal().clearUpdateRange()
        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil)

        // Second layout with identical bounds — must be a no-op for redraw.
        container.layout()

        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil,
                "Layout with unchanged bounds must not re-seed the dirty range")
    }

    /// `layout()` with new bounds must re-seed the dirty range so a TUI
    /// app's alternate-screen content repaints after a sub-cell pixel
    /// resize that did NOT trigger SwiftTerm's own size-change path.
    @Test @MainActor func layoutWithChangedBoundsReseedsDirtyRange() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)
        container.layout()

        tab.terminalView.getTerminal().clearUpdateRange()

        // Resize the container — frame size differs from previous layout.
        container.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        container.layout()

        let range = tab.terminalView.getTerminal().getUpdateRange()
        #expect(range != nil, "Layout with new bounds must re-seed the dirty range")
    }

    /// After `removeFromSuperview` the container must clean up EVERY
    /// backing-store recovery observer (become-key, change-screen,
    /// change-occlusion-state, app-become-active, deminiaturize) so none
    /// can fire against a now-detached terminal view. Verified indirectly:
    /// posting each notification does not crash and does not re-seed the
    /// dirty range (issue #1094 recovery-trigger family).
    @Test @MainActor func removeFromSuperviewClearsAllRecoveryObservers() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        container.removeFromSuperview()
        tab.terminalView.getTerminal().clearUpdateRange()
        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil)

        // Posting becomeKey on the (now-orphaned) window must not retrigger
        // a redraw on the detached container.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil,
                "Detached container must not respond to becomeKey notifications")

        // The three new recovery triggers added for occlusion/hide/minimize
        // (issue #1094) must likewise be torn down — posting any of them
        // against the orphaned window/app must not re-seed the dirty range.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)

        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil,
                "Detached container must not respond to occlusion/app-active/deminimize notifications")
    }

    /// When the host window receives `didBecomeKey`, the active terminal
    /// must repaint so a previously-blanked alternate-screen buffer
    /// becomes visible again.
    @Test @MainActor func windowBecomeKeyTriggersTerminalRedraw() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.startTabs(workingDirectory: nil)

        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.terminalPaneState = state
        container.showTab(state.activeTab)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        // Drain the dirty range that `viewDidMoveToWindow` just seeded.
        tab.terminalView.getTerminal().clearUpdateRange()
        #expect(tab.terminalView.getTerminal().getUpdateRange() == nil)

        // Simulate user returning focus to the window via Cmd+Tab.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        let range = tab.terminalView.getTerminal().getUpdateRange()
        #expect(range != nil, "didBecomeKey must trigger a buffer repaint on the active terminal")
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
