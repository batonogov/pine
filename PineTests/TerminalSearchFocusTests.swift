//
//  TerminalSearchFocusTests.swift
//  PineTests
//
//  Issue #1523 — ⌘F must move first responder into the terminal search
//  field, Return/Shift+Return must navigate matches, and Escape must close
//  the bar and hand first responder back to the terminal.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

/// Stand-in for SwiftTerm's terminal view. The production target is a
/// `LocalProcessTerminalView`, which needs a live PTY to behave; first
/// responder ownership is the only property under test here.
private final class FocusAcceptingTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@Suite("Terminal Search Focus")
@MainActor
struct TerminalSearchFocusTests {

    // MARK: - Focus intent state machine

    @Test("Cmd+F opens the bar, requests field focus, and cancels terminal focus")
    func presentSearchClaimsFocusFromTerminal() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        // `addTab` leaves a pending focus request aimed at the terminal view.
        #expect(state.pendingFocusTabID == tab.id)

        state.presentSearch()

        #expect(state.isSearchVisible)
        _ = try #require(state.searchFocusRequestID)
        // Without this the terminal's own request would win the race and the
        // field would be revealed while the shell kept the keystrokes.
        #expect(state.pendingFocusTabID == nil)
        #expect(state.pendingFocusRequestID == nil)
    }

    @Test("Cmd+F while the bar is already open re-requests focus")
    func repeatedPresentSearchIssuesDistinctRequests() throws {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)

        state.presentSearch()
        let first = try #require(state.searchFocusRequestID)
        state.presentSearch()
        let second = try #require(state.searchFocusRequestID)

        #expect(first != second)
    }

    @Test("Only the live search focus request is acknowledged")
    func searchFocusAcknowledgementIsGenerationGuarded() throws {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)

        state.presentSearch()
        let stale = try #require(state.searchFocusRequestID)
        state.presentSearch()
        let live = try #require(state.searchFocusRequestID)

        #expect(!state.acknowledgeSearchFocusRequest(stale, succeeded: true))
        #expect(state.searchFocusRequestID == live)

        #expect(state.acknowledgeSearchFocusRequest(live, succeeded: true))
        #expect(state.searchFocusRequestID == nil)
    }

    @Test("A failed focus attempt is consumed but reported as failure")
    func failedSearchFocusRequestIsConsumed() throws {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)
        state.presentSearch()
        let requestID = try #require(state.searchFocusRequestID)

        #expect(!state.acknowledgeSearchFocusRequest(requestID, succeeded: false))
        #expect(state.searchFocusRequestID == nil)
    }

    @Test("Escape closes the bar, clears the query, and re-focuses the terminal")
    func dismissSearchReturnsFocusToTerminal() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.presentSearch()
        state.terminalSearchQuery = "needle"
        _ = try #require(state.searchFocusRequestID)

        state.dismissSearch()

        #expect(!state.isSearchVisible)
        #expect(state.terminalSearchQuery.isEmpty)
        #expect(state.searchFocusRequestID == nil)
        #expect(state.pendingFocusTabID == tab.id)
        #expect(state.pendingFocusRequestID != nil)
    }

    @Test("Dismissing an already-closed bar never steals focus")
    func dismissSearchWhileClosedIsANoOp() {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)
        state.pendingFocusTabID = nil

        state.dismissSearch()

        #expect(!state.isSearchVisible)
        #expect(state.pendingFocusTabID == nil)
        #expect(state.pendingFocusRequestID == nil)
    }

    // MARK: - Field editor key bindings

    @Test("Return finds next, Shift+Return finds previous, Escape dismisses")
    func fieldEditorSelectorsMapToSearchCommands() {
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.insertNewline(_:)),
                shiftPressed: false
            ) == .findNext
        )
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.insertNewline(_:)),
                shiftPressed: true
            ) == .findPrevious
        )
        // AppKit routes Shift/Option+Return through this selector on some
        // key-binding configurations; the direction rule must not change.
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                shiftPressed: true
            ) == .findPrevious
        )
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.cancelOperation(_:)),
                shiftPressed: false
            ) == .dismiss
        )
        // Escape must dismiss regardless of a stray modifier.
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.cancelOperation(_:)),
                shiftPressed: true
            ) == .dismiss
        )
    }

    @Test("Unrelated field editor commands stay with AppKit")
    func unrelatedSelectorsAreNotIntercepted() {
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.insertTab(_:)),
                shiftPressed: false
            ) == nil
        )
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.deleteBackward(_:)),
                shiftPressed: false
            ) == nil
        )
        #expect(
            TerminalSearchFieldCommand.forSelector(
                #selector(NSResponder.moveLeft(_:)),
                shiftPressed: false
            ) == nil
        )
    }

    @Test("The field delegate dispatches the mapped command and consumes the key")
    func delegateDispatchesMappedCommands() {
        var commands: [TerminalSearchFieldCommand] = []
        let field = TerminalSearchFieldView()
        let coordinator = TerminalSearchField.Coordinator(
            text: .constant(""),
            onCommand: { commands.append($0) }
        )
        var shift = false
        coordinator.modifierFlagsProvider = { shift ? [.shift] : [] }

        #expect(coordinator.handleCommand(#selector(NSResponder.insertNewline(_:))))
        shift = true
        #expect(coordinator.handleCommand(#selector(NSResponder.insertNewline(_:))))
        shift = false
        #expect(coordinator.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        // Not ours — AppKit keeps its default behaviour.
        #expect(!coordinator.handleCommand(#selector(NSResponder.deleteBackward(_:))))

        #expect(commands == [.findNext, .findPrevious, .dismiss])
        #expect(field.acceptsFirstResponder)
    }

    // MARK: - Real AppKit first responder round trip

    @Test("First responder moves into the field on Cmd+F and back on Escape")
    func firstResponderRoundTripBetweenTerminalAndSearchField() throws {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        let terminalStandIn = FocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 160)
        )
        let field = TerminalSearchFieldView(
            frame: NSRect(x: 0, y: 160, width: 400, height: 24)
        )
        contentView.addSubview(terminalStandIn)
        contentView.addSubview(field)
        defer { window.orderOut(nil) }

        // Before ⌘F the terminal owns first responder.
        #expect(window.makeFirstResponder(terminalStandIn))
        #expect(window.firstResponder === terminalStandIn)

        // ⌘F — production drives the very same coordinator from updateNSView.
        state.presentSearch()
        let searchRequestID = try #require(state.searchFocusRequestID)
        field.focusCoordinator.update(
            requestID: searchRequestID,
            hostView: field,
            targetView: field,
            onResult: { requestID, succeeded in
                state.acknowledgeSearchFocusRequest(requestID, succeeded: succeeded)
            }
        )
        #expect(field.focusCoordinator.attemptNow())

        // The window's first responder is the field editor, a descendant of
        // the search field — typing now lands in the query, not the shell.
        let editor = try #require(window.firstResponder as? NSView)
        #expect(editor.isDescendant(of: field))
        #expect(!editor.isDescendant(of: terminalStandIn))
        #expect(state.searchFocusRequestID == nil)

        // Escape.
        state.dismissSearch()
        let terminalRequestID = try #require(state.pendingFocusRequestID)
        let terminalFocus = AppKitFocusRequestCoordinator()
        terminalFocus.update(
            requestID: terminalRequestID,
            hostView: contentView,
            targetView: terminalStandIn,
            onResult: { requestID, succeeded in
                state.acknowledgeFocusRequest(
                    requestID: requestID,
                    for: tab.id,
                    succeeded: succeeded
                )
            }
        )
        #expect(terminalFocus.attemptNow())
        #expect(window.firstResponder === terminalStandIn)
        #expect(state.pendingFocusTabID == nil)
    }
}
