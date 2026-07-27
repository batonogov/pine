//
//  TabDestinationFocusTests.swift
//  PineTests
//
//  Destination presentation and AppKit focus acknowledgement regressions.
//

import AppKit
import Foundation
import QuickLookUI
import Testing

@testable import Pine

@Suite("Tab Destination Focus")
@MainActor
struct TabDestinationFocusTests {
    @Test("Presentation routing covers Quick Look and rendered Markdown")
    func previewPresentationRouting() {
        let quickLook = EditorTab(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            kind: .preview
        )
        var markdown = EditorTab(
            url: URL(fileURLWithPath: "/tmp/readme.md"),
            content: "# Pine",
            savedContent: "# Pine"
        )

        #expect(EditorContentPresentation.resolve(for: quickLook) == .quickLook)
        markdown.previewMode = .preview
        #expect(EditorContentPresentation.resolve(for: markdown) == .markdownPreview)
        markdown.previewMode = .split
        #expect(EditorContentPresentation.resolve(for: markdown) == .markdownSplit)
        markdown.previewMode = .source
        #expect(EditorContentPresentation.resolve(for: markdown) == .codeEditor)
    }

    @Test("Final focus results consume requests while tab switches cancel stale focus")
    func finalResultsAndTabSwitchConsumeFocusRequests() throws {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/image.png"), kind: .preview)
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id
        let failedRequestID = try #require(manager.pendingFocusRequestID)

        #expect(!manager.acknowledgeFocusRequest(
            requestID: failedRequestID,
            for: tab.id,
            succeeded: false
        ))
        #expect(manager.pendingFocusTabID == nil)

        manager.pendingFocusTabID = tab.id
        let pendingRequestID = try #require(manager.pendingFocusRequestID)
        #expect(!manager.acknowledgeFocusRequest(
            requestID: pendingRequestID,
            for: UUID(),
            succeeded: true
        ))
        #expect(manager.pendingFocusTabID == tab.id)

        manager.activeTabID = nil
        #expect(manager.pendingFocusTabID == nil)
        #expect(!manager.acknowledgeFocusRequest(
            requestID: pendingRequestID,
            for: tab.id,
            succeeded: true
        ))
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("Repeated requests for one tab receive distinct generations")
    func repeatedRequestsForSameTabHaveDistinctGenerations() throws {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id
        let firstRequestID = try #require(manager.pendingFocusRequestID)

        manager.pendingFocusTabID = tab.id
        let secondRequestID = try #require(manager.pendingFocusRequestID)
        #expect(secondRequestID != firstRequestID)
        #expect(!manager.acknowledgeFocusRequest(
            requestID: firstRequestID,
            for: tab.id,
            succeeded: true
        ))
        #expect(manager.pendingFocusRequestID == secondRequestID)
        #expect(manager.acknowledgeFocusRequest(
            requestID: secondRequestID,
            for: tab.id,
            succeeded: true
        ))
        #expect(manager.pendingFocusTabID == nil)

        let terminalState = TerminalPaneState()
        let terminalTab = terminalState.addTab(workingDirectory: nil)
        let firstTerminalRequestID = try #require(terminalState.pendingFocusRequestID)
        terminalState.pendingFocusTabID = terminalTab.id
        let secondTerminalRequestID = try #require(terminalState.pendingFocusRequestID)
        #expect(secondTerminalRequestID != firstTerminalRequestID)
        #expect(!terminalState.acknowledgeFocusRequest(
            requestID: firstTerminalRequestID,
            for: terminalTab.id,
            succeeded: true
        ))
        #expect(terminalState.pendingFocusRequestID == secondTerminalRequestID)
    }

    @Test("Detached AppKit destination retries and acknowledges after attachment")
    func detachedDestinationRetriesAfterWindowAttachment() throws {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id
        let requestID = try #require(manager.pendingFocusRequestID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: requestID,
            hostView: host,
            targetView: target,
            onResult: { completedRequestID, succeeded in
                manager.acknowledgeFocusRequest(
                    requestID: completedRequestID,
                    for: tab.id,
                    succeeded: succeeded
                )
            }
        )

        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == requestID)
        #expect(manager.pendingFocusTabID == tab.id)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host

        #expect(coordinator.attemptNow())
        #expect(window.firstResponder === target)
        #expect(coordinator.pendingRequestID == nil)
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("Stale request is cancelled before AppKit can steal focus")
    func staleRequestDoesNotChangeFirstResponder() throws {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id
        let requestID = try #require(manager.pendingFocusRequestID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let originalResponder = window.firstResponder
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: requestID,
            hostView: host,
            targetView: target,
            canAttempt: { candidateRequestID in
                manager.activeTabID == tab.id
                    && manager.pendingFocusTabID == tab.id
                    && manager.pendingFocusRequestID == candidateRequestID
            },
            onResult: { completedRequestID, succeeded in
                manager.acknowledgeFocusRequest(
                    requestID: completedRequestID,
                    for: tab.id,
                    succeeded: succeeded
                )
            }
        )

        manager.activeTabID = nil
        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == nil)
        #expect(window.firstResponder === originalResponder)
        #expect(window.firstResponder !== target)
    }

    @Test("Responder rejection exhausts one bounded budget across repeated updates")
    func responderRejectionExhaustsBoundedBudget() async throws {
        let manager = TabManager()
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        manager.tabs = [tab]
        manager.activeTabID = tab.id
        manager.pendingFocusTabID = tab.id
        let requestID = try #require(manager.pendingFocusRequestID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let window = FocusRejectingTestWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let baselineAttempts = window.focusAttemptCount
        var terminalResults: [Bool] = []
        let onResult: (UUID, Bool) -> Void = { completedRequestID, succeeded in
            terminalResults.append(succeeded)
            manager.acknowledgeFocusRequest(
                requestID: completedRequestID,
                for: tab.id,
                succeeded: succeeded
            )
        }
        let coordinator = AppKitFocusRequestCoordinator(maximumAttempts: 2)
        coordinator.update(
            requestID: requestID,
            hostView: host,
            targetView: target,
            onResult: onResult
        )

        // Exercise the first attempt synchronously while retaining the queued
        // retry installed by `update`.
        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == requestID)
        #expect(manager.pendingFocusTabID == tab.id)
        #expect(window.focusAttemptCount - baselineAttempts == 1)
        #expect(terminalResults.isEmpty)

        // Repeated SwiftUI updates while the retry is pending must neither
        // reset the counter nor enqueue parallel attempts.
        for _ in 0..<3 {
            coordinator.update(
                requestID: requestID,
                hostView: host,
                targetView: target,
                onResult: onResult
            )
        }
        await nextMainQueueTurn()
        #expect(coordinator.pendingRequestID == nil)
        #expect(manager.pendingFocusTabID == nil)
        #expect(window.focusAttemptCount - baselineAttempts == 2)
        #expect(terminalResults == [false])

        // A stale SwiftUI update for the completed request must not restart
        // the budget or enqueue another responder attempt.
        coordinator.update(
            requestID: requestID,
            hostView: host,
            targetView: target,
            onResult: onResult
        )
        await nextMainQueueTurn()
        await nextMainQueueTurn()
        #expect(window.focusAttemptCount - baselineAttempts == 2)
        #expect(terminalResults == [false])
    }

    @Test("Queued attempt from a superseded generation cannot focus its old target")
    func queuedSupersededGenerationDoesNotRun() async {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let oldTarget = FocusAcceptingTestView(frame: host.bounds)
        let currentTarget = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(oldTarget)
        host.addSubview(currentTarget)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host

        let oldRequestID = UUID()
        let currentRequestID = UUID()
        var completedRequestIDs: [UUID] = []
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: oldRequestID,
            hostView: host,
            targetView: oldTarget,
            onResult: { requestID, _ in completedRequestIDs.append(requestID) }
        )
        coordinator.update(
            requestID: currentRequestID,
            hostView: host,
            targetView: currentTarget,
            onResult: { requestID, _ in completedRequestIDs.append(requestID) }
        )

        // The first queue turn discards the stale generation and schedules
        // the current one; the second executes only the current attempt.
        await nextMainQueueTurn()
        await nextMainQueueTurn()

        #expect(window.firstResponder === currentTarget)
        #expect(window.firstResponder !== oldTarget)
        #expect(completedRequestIDs == [currentRequestID])
        #expect(coordinator.pendingRequestID == nil)
    }

    @Test("Pane switch cancels delayed editor focus before AppKit can steal it")
    func paneSwitchCancelsDelayedEditorFocus() throws {
        let paneManager = PaneManager()
        let destinationPaneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: destinationPaneID))
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id
        tabManager.pendingFocusTabID = tab.id
        let requestID = try #require(tabManager.pendingFocusRequestID)
        let otherPaneID = try #require(
            paneManager.splitPane(destinationPaneID, axis: .horizontal)
        )
        #expect(paneManager.activePaneID == otherPaneID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let originalResponder = window.firstResponder
        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: requestID,
            hostView: host,
            targetView: target,
            canAttempt: { candidateRequestID in
                paneManager.activePaneID == destinationPaneID
                    && tabManager.activeTabID == tab.id
                    && tabManager.pendingFocusTabID == tab.id
                    && tabManager.pendingFocusRequestID == candidateRequestID
            },
            onResult: { completedRequestID, succeeded in
                tabManager.acknowledgeFocusRequest(
                    requestID: completedRequestID,
                    for: tab.id,
                    succeeded: succeeded
                )
            }
        )

        #expect(!coordinator.attemptNow())
        #expect(coordinator.pendingRequestID == nil)
        #expect(tabManager.pendingFocusTabID == nil)
        #expect(window.firstResponder === originalResponder)
        #expect(window.firstResponder !== target)
    }

    @Test("Deferred editor creation revalidates its pane before taking focus")
    func deferredEditorCreationRevalidatesPane() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let target = FocusAcceptingTestView(frame: host.bounds)
        host.addSubview(target)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let originalResponder = window.firstResponder

        #expect(!CodeEditorView.attemptInitialFocus(
            on: target,
            canAttempt: { false }
        ))
        #expect(window.firstResponder === originalResponder)
        #expect(window.firstResponder !== target)

        #expect(CodeEditorView.attemptInitialFocus(
            on: target,
            canAttempt: { true }
        ))
        #expect(window.firstResponder === target)
    }

    @Test("Pane switch cancels delayed terminal focus before AppKit can steal it")
    func paneSwitchCancelsDelayedTerminalFocus() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        container.terminalPaneState = state
        container.canAttemptFocusRequest = { _ in false }
        container.showTab(tab)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        let originalResponder = window.firstResponder

        #expect(!container.destinationFocusCoordinator.attemptNow())
        #expect(container.destinationFocusCoordinator.pendingRequestID == nil)
        #expect(state.pendingFocusTabID == nil)
        #expect(window.firstResponder === originalResponder)
        #expect(window.firstResponder !== tab.terminalView)
    }

    @Test("Tab-strip selection and creation activate the owning pane first")
    func tabStripActionsActivateOwningPane() throws {
        let paneManager = PaneManager()
        let editorPaneID = paneManager.activePaneID
        let editorManager = try #require(paneManager.tabManager(for: editorPaneID))
        let firstEditorTab = EditorTab(url: URL(fileURLWithPath: "/tmp/first.swift"))
        let secondEditorTab = EditorTab(url: URL(fileURLWithPath: "/tmp/second.swift"))
        editorManager.tabs = [firstEditorTab, secondEditorTab]
        editorManager.activeTabID = firstEditorTab.id

        let terminalPaneID = try #require(paneManager.createTerminalPane(
            relativeTo: editorPaneID,
            axis: .vertical,
            workingDirectory: nil
        ))
        let terminalState = try #require(paneManager.terminalState(for: terminalPaneID))
        let firstTerminalTab = try #require(terminalState.activeTab)
        #expect(paneManager.activePaneID == terminalPaneID)

        #expect(paneManager.selectEditorTab(secondEditorTab.id, in: editorPaneID))
        #expect(paneManager.activePaneID == editorPaneID)
        #expect(editorManager.activeTabID == secondEditorTab.id)
        #expect(editorManager.pendingFocusTabID == secondEditorTab.id)

        let firstEditorRequestID = try #require(editorManager.pendingFocusRequestID)
        paneManager.activePaneID = terminalPaneID
        #expect(paneManager.selectEditorTab(secondEditorTab.id, in: editorPaneID))
        #expect(paneManager.activePaneID == editorPaneID)
        #expect(editorManager.activeTabID == secondEditorTab.id)
        #expect(editorManager.pendingFocusTabID == secondEditorTab.id)
        #expect(editorManager.pendingFocusRequestID != firstEditorRequestID)

        let addedTerminalTab = try #require(
            paneManager.addTerminalTab(in: terminalPaneID, workingDirectory: nil)
        )
        #expect(paneManager.activePaneID == terminalPaneID)
        #expect(terminalState.activeTerminalID == addedTerminalTab.id)
        #expect(terminalState.pendingFocusTabID == addedTerminalTab.id)

        paneManager.activePaneID = editorPaneID
        #expect(paneManager.selectTerminalTab(firstTerminalTab.id, in: terminalPaneID))
        #expect(paneManager.activePaneID == terminalPaneID)
        #expect(terminalState.activeTerminalID == firstTerminalTab.id)
        #expect(terminalState.pendingFocusTabID == firstTerminalTab.id)

        let previousRequestID = terminalState.pendingFocusRequestID
        #expect(!paneManager.selectTerminalTab(UUID(), in: terminalPaneID))
        #expect(paneManager.activePaneID == terminalPaneID)
        #expect(terminalState.activeTerminalID == firstTerminalTab.id)
        #expect(terminalState.pendingFocusRequestID == previousRequestID)
    }

    @Test("Selection can preserve source focus and cancels stale AppKit requests")
    func selectionWithoutDestinationFocusCancelsPendingRequest() throws {
        let paneManager = PaneManager()
        let editorPaneID = paneManager.activePaneID
        let editorManager = try #require(paneManager.tabManager(for: editorPaneID))
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/sidebar-preview.swift"))
        editorManager.tabs = [tab]
        editorManager.activeTabID = tab.id

        let terminalPaneID = try #require(paneManager.createTerminalPane(
            relativeTo: editorPaneID,
            axis: .vertical,
            workingDirectory: nil
        ))
        #expect(paneManager.activePaneID == terminalPaneID)

        // Seed a request for the already-active tab. Because activeTabID does
        // not change below, only the explicit no-focus path can cancel it.
        editorManager.pendingFocusTabID = tab.id
        #expect(editorManager.pendingFocusRequestID != nil)

        #expect(paneManager.selectEditorTab(
            tab.id,
            in: editorPaneID,
            requestFocus: false
        ))
        #expect(paneManager.activePaneID == editorPaneID)
        #expect(editorManager.activeTabID == tab.id)
        #expect(editorManager.pendingFocusTabID == nil)
        #expect(editorManager.pendingFocusRequestID == nil)

        let identity = GlobalTabIdentity(
            paneID: editorPaneID,
            tabID: tab.id,
            contentType: .editor
        )
        #expect(paneManager.validGlobalTabSwitchOrder().first == identity)

        #expect(paneManager.selectEditorTab(tab.id, in: editorPaneID))
        #expect(editorManager.pendingFocusTabID == tab.id)
    }

    @Test("Sidebar focus claim invalidates an active editor request only")
    func sidebarClaimInvalidatesActiveEditorRequest() async throws {
        let paneManager = PaneManager()
        let editorPaneID = paneManager.activePaneID
        let editorManager = try #require(paneManager.tabManager(for: editorPaneID))
        let editorTab = EditorTab(url: URL(fileURLWithPath: "/tmp/sidebar-editor.swift"))
        editorManager.tabs = [editorTab]
        editorManager.activeTabID = editorTab.id

        let terminalPaneID = try #require(paneManager.createTerminalPane(
            relativeTo: editorPaneID,
            axis: .vertical,
            workingDirectory: nil
        ))
        let terminalState = try #require(paneManager.terminalState(for: terminalPaneID))
        let terminalRequestID = try #require(terminalState.pendingFocusRequestID)

        paneManager.activePaneID = editorPaneID
        editorManager.pendingFocusTabID = editorTab.id
        let editorRequestID = try #require(editorManager.pendingFocusRequestID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let destination = FocusAcceptingTestView(frame: host.bounds)
        let sidebarResponder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        host.addSubview(destination)
        host.addSubview(sidebarResponder)
        let window = SidebarFocusRaceTestWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.destinationResponder = destination
        let focusController = SidebarKeyboardFocusController()
        focusController.attach(sidebarResponder)

        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: editorRequestID,
            hostView: host,
            targetView: destination,
            canAttempt: { candidateRequestID in
                paneManager.activePaneID == editorPaneID
                    && editorManager.activeTabID == editorTab.id
                    && editorManager.pendingFocusTabID == editorTab.id
                    && editorManager.pendingFocusRequestID == candidateRequestID
            },
            onResult: { completedRequestID, succeeded in
                editorManager.acknowledgeFocusRequest(
                    requestID: completedRequestID,
                    for: editorTab.id,
                    succeeded: succeeded
                )
            }
        )

        // Leave the request pending after a real rejected attempt. The retry
        // queued by update() would accept the destination and steal focus if
        // clearing the model token did not invalidate canAttempt.
        #expect(!coordinator.attemptNow())
        #expect(window.destinationAttemptCount == 1)
        #expect(coordinator.pendingRequestID == editorRequestID)

        paneManager.cancelPendingFocusForActivePane()
        #expect(focusController.requestFocus())
        await nextMainQueueTurn()

        #expect(editorManager.pendingFocusTabID == nil)
        #expect(editorManager.pendingFocusRequestID == nil)
        #expect(terminalState.pendingFocusRequestID == terminalRequestID)
        #expect(coordinator.pendingRequestID == nil)
        #expect(window.destinationAttemptCount == 1)
        #expect(window.firstResponder === sidebarResponder)
        #expect(window.firstResponder !== destination)
    }

    @Test("Sidebar focus claim invalidates an active terminal request only")
    func sidebarClaimInvalidatesActiveTerminalRequest() async throws {
        let paneManager = PaneManager()
        let editorPaneID = paneManager.activePaneID
        let editorManager = try #require(paneManager.tabManager(for: editorPaneID))
        let editorTab = EditorTab(url: URL(fileURLWithPath: "/tmp/sidebar-editor.swift"))
        editorManager.tabs = [editorTab]
        editorManager.activeTabID = editorTab.id
        editorManager.pendingFocusTabID = editorTab.id
        let editorRequestID = try #require(editorManager.pendingFocusRequestID)

        let terminalPaneID = try #require(paneManager.createTerminalPane(
            relativeTo: editorPaneID,
            axis: .vertical,
            workingDirectory: nil
        ))
        let terminalState = try #require(paneManager.terminalState(for: terminalPaneID))
        let terminalTab = try #require(terminalState.activeTab)
        let terminalRequestID = try #require(terminalState.pendingFocusRequestID)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let destination = FocusAcceptingTestView(frame: host.bounds)
        let sidebarResponder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        host.addSubview(destination)
        host.addSubview(sidebarResponder)
        let window = SidebarFocusRaceTestWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.destinationResponder = destination
        let focusController = SidebarKeyboardFocusController()
        focusController.attach(sidebarResponder)

        let coordinator = AppKitFocusRequestCoordinator()
        coordinator.update(
            requestID: terminalRequestID,
            hostView: host,
            targetView: destination,
            canAttempt: { candidateRequestID in
                paneManager.activePaneID == terminalPaneID
                    && terminalState.activeTerminalID == terminalTab.id
                    && terminalState.pendingFocusTabID == terminalTab.id
                    && terminalState.pendingFocusRequestID == candidateRequestID
            },
            onResult: { completedRequestID, succeeded in
                terminalState.acknowledgeFocusRequest(
                    requestID: completedRequestID,
                    for: terminalTab.id,
                    succeeded: succeeded
                )
            }
        )

        #expect(!coordinator.attemptNow())
        #expect(window.destinationAttemptCount == 1)
        #expect(coordinator.pendingRequestID == terminalRequestID)

        paneManager.cancelPendingFocusForActivePane()
        #expect(focusController.requestFocus())
        await nextMainQueueTurn()

        #expect(terminalState.pendingFocusTabID == nil)
        #expect(terminalState.pendingFocusRequestID == nil)
        #expect(editorManager.pendingFocusRequestID == editorRequestID)
        #expect(coordinator.pendingRequestID == nil)
        #expect(window.destinationAttemptCount == 1)
        #expect(window.firstResponder === sidebarResponder)
        #expect(window.firstResponder !== destination)
    }

    @Test("Sidebar preview preserves focus while an explicit open targets the editor")
    func sidebarOpenDispositionFocusPolicy() {
        #expect(!SidebarFileOpenDisposition.transientPreview.requestsEditorFocus)
        #expect(SidebarFileOpenDisposition.permanent.requestsEditorFocus)
        #expect(SidebarFileOpenDisposition.pointerClick(count: 0) == .transientPreview)
        #expect(SidebarFileOpenDisposition.pointerClick(count: 1) == .transientPreview)
        #expect(SidebarFileOpenDisposition.pointerClick(count: 2) == .permanent)
        #expect(SidebarFileOpenDisposition.pointerClick(count: 3) == .permanent)
    }

    @Test("Sidebar AppKit responder takes synchronous first-responder focus")
    func sidebarResponderTakesFocus() {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        controller.attach(responder)

        #expect(controller.requestFocus())
        #expect(window.firstResponder === responder)

        let tabID = UUID()
        let editor = FocusAcceptingTestView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(editor)

        #expect(!CodeEditorView.attemptInitialFocus(
            on: editor,
            canAttempt: {
                SidebarKeyboardFocusPolicy.allowsEditorInitialFocus(
                    tabID: tabID,
                    pendingFocusTabID: nil,
                    firstResponder: window.firstResponder
                )
            }
        ))
        #expect(window.firstResponder === responder)

        #expect(CodeEditorView.attemptInitialFocus(
            on: editor,
            canAttempt: {
                SidebarKeyboardFocusPolicy.allowsEditorInitialFocus(
                    tabID: tabID,
                    pendingFocusTabID: tabID,
                    firstResponder: window.firstResponder
                )
            }
        ))
        #expect(window.firstResponder === editor)
        #expect(SidebarKeyboardFocusPolicy.allowsEditorInitialFocus(
            tabID: tabID,
            pendingFocusTabID: nil,
            firstResponder: window.firstResponder
        ))

        // Keyboard preview actions can originate from SwiftUI's focusable
        // host. The controller must be able to normalize that path back to
        // the sidebar responder after another view held focus.
        #expect(controller.requestFocus())
        #expect(window.firstResponder === responder)
    }

    @Test("Queued implicit editor focus respects a sidebar responder claim")
    func queuedImplicitEditorFocusRespectsSidebarClaim() async {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let editor = FocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let window = NSWindow(
            contentRect: editor.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(responder)
        controller.attach(responder)

        let tabID = UUID()
        var attemptedInitialFocus = false
        DispatchQueue.main.async {
            attemptedInitialFocus = true
            _ = CodeEditorView.attemptInitialFocus(
                on: editor,
                canAttempt: {
                    SidebarKeyboardFocusPolicy.allowsEditorInitialFocus(
                        tabID: tabID,
                        pendingFocusTabID: nil,
                        firstResponder: window.firstResponder
                    )
                }
            )
        }

        #expect(controller.requestFocus())
        #expect(window.firstResponder === responder)
        await nextMainQueueTurn()

        #expect(attemptedInitialFocus)
        #expect(window.firstResponder === responder)
        #expect(window.firstResponder !== editor)
    }

    @Test("Sidebar AppKit responder advances the FKA key-view loop")
    func sidebarResponderAdvancesKeyViewLoop() throws {
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let window = FocusTraversalTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        #expect(window.makeFirstResponder(responder))

        let tabEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        responder.keyDown(with: tabEvent)
        #expect(window.nextSelectionCount == 1)
        #expect(window.previousSelectionCount == 0)

        let shiftTabEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        responder.keyDown(with: shiftTabEvent)
        #expect(window.nextSelectionCount == 1)
        #expect(window.previousSelectionCount == 1)
    }

    @Test("Quick Look focus target is an explicit first responder")
    func quickLookAcceptsDestinationFocus() throws {
        let view = try #require(FocusableQuickLookPreviewView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            style: .normal
        ))
        #expect(view.acceptsFirstResponder)
    }

    @Test("Terminal focus terminal result and active switch both clear pending requests")
    func terminalResultAndActiveSwitchClearPendingRequests() throws {
        let state = TerminalPaneState()
        let first = state.addTab(workingDirectory: nil)
        let failedRequestID = try #require(state.pendingFocusRequestID)

        #expect(!state.acknowledgeFocusRequest(
            requestID: failedRequestID,
            for: first.id,
            succeeded: false
        ))
        #expect(state.pendingFocusTabID == nil)

        let second = state.addTab(workingDirectory: nil)
        let staleRequestID = try #require(state.pendingFocusRequestID)
        #expect(state.pendingFocusTabID == second.id)
        state.activeTerminalID = first.id
        #expect(state.pendingFocusTabID == nil)
        #expect(!state.acknowledgeFocusRequest(
            requestID: staleRequestID,
            for: second.id,
            succeeded: true
        ))
    }
}

private final class FocusAcceptingTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class FocusRejectingTestWindow: NSWindow {
    private(set) var focusAttemptCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        focusAttemptCount += 1
        return false
    }
}

private final class SidebarFocusRaceTestWindow: NSWindow {
    weak var destinationResponder: NSResponder?
    private(set) var destinationAttemptCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder === destinationResponder {
            destinationAttemptCount += 1
            if destinationAttemptCount == 1 {
                return false
            }
        }
        return super.makeFirstResponder(responder)
    }
}

private final class FocusTraversalTestWindow: NSWindow {
    private(set) var nextSelectionCount = 0
    private(set) var previousSelectionCount = 0

    override func selectNextKeyView(_ sender: Any?) {
        nextSelectionCount += 1
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        previousSelectionCount += 1
    }
}

@MainActor
private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
