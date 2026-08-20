//
//  SidebarAccessibilityHostedTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar hosted accessibility")
@MainActor
struct SidebarAccessibilityHostedTests {
    @Test("Folder bridge exposes native outline row semantics and actions")
    func folderOutlineSemantics() throws {
        var pressed = 0
        var disclosureActions = 0
        let hosted = hostRow(
            configuration: configuration(
                isFolder: true,
                isExpanded: true,
                isSelected: true,
                isFocused: true,
                level: 2
            ),
            onPress: {
                pressed += 1
                return true
            },
            onCustomAction: {
                disclosureActions += 1
                return true
            }
        )
        let row = try #require(findRow(in: hosted))

        #expect(row.accessibilityRole() == .row)
        #expect(row.accessibilitySubrole() == .outlineRow)
        #expect(row.accessibilityLabel() == "Sources")
        #expect(row.accessibilityIdentifier() == "fileNode_Sources")
        #expect(row.accessibilityDisclosureLevel() == 2)
        #expect(row.isAccessibilitySelected())
        #expect(row.isAccessibilityFocused())
        #expect(row.isAccessibilityExpanded())
        #expect(row.accessibilityValue() as? String == "expanded")
        #expect(row.accessibilityHelp() == "Folder hint")
        #expect(row.accessibilityPerformPress())
        #expect(pressed == 1)

        let customAction = try #require(
            row.accessibilityCustomActions()?.first
        )
        #expect(customAction.name == "Collapse")
        #expect(customAction.handler?() == true)
        #expect(disclosureActions == 1)
    }

    @Test("File bridge keeps row role, selection state, and preview action")
    func fileOutlineSemantics() throws {
        var previews = 0
        let hosted = hostRow(
            configuration: configuration(
                isFolder: false,
                isExpanded: false,
                isSelected: false,
                isFocused: false,
                level: 0
            ),
            onPress: { true },
            onCustomAction: {
                previews += 1
                return true
            }
        )
        let row = try #require(findRow(in: hosted))

        #expect(row.accessibilityRole() == .row)
        #expect(row.accessibilitySubrole() == .outlineRow)
        #expect(row.accessibilityDisclosureLevel() == 0)
        #expect(!row.isAccessibilitySelected())
        #expect(!row.isAccessibilityFocused())
        #expect(!row.isAccessibilityExpanded())
        #expect(row.accessibilityValue() == nil)
        let customAction = try #require(
            row.accessibilityCustomActions()?.first
        )
        #expect(customAction.name == "Open Preview")
        #expect(customAction.handler?() == true)
        #expect(previews == 1)
    }

    @Test("Accessibility view never intercepts pointer hit testing")
    func accessibilityViewDoesNotHitTest() {
        let row = SidebarAccessibilityRowView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 20)
        )

        #expect(row.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("Accessibility row routes physical and standard navigation")
    func accessibilityRowNavigationRouting() throws {
        var commands: [SidebarKeyboardCommand] = []
        let hosted = hostRow(
            configuration: configuration(
                isFolder: true,
                isExpanded: true,
                isSelected: true,
                isFocused: true,
                level: 0
            ),
            onPress: { true },
            onCommand: {
                commands.append($0)
                return true
            },
            onCustomAction: { true }
        )
        let row = try #require(findRow(in: hosted))
        let window = NSWindow(
            contentRect: hosted.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosted
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(row))
        #expect(row.isAccessibilityFocused())
        row.keyDown(with: try makeKeyEvent(
            characters: "\u{F702}",
            keyCode: 123,
            flags: []
        ))
        row.doCommand(by: NSSelectorFromString("moveRight:"))

        #expect(commands == [.left, .right])
    }

    @Test("Focused responder reports focus lifecycle to shared controller")
    func responderFocusLifecycle() throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        controller.attach(responder)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = responder
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus())
        #expect(controller.isFocused)
        #expect(window.makeFirstResponder(nil))
        #expect(!controller.isFocused)
    }

    @Test("Row focus claim retries once after responder joins a window")
    func responderFocusRetryAfterAttachment() async {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        controller.attach(responder)

        #expect(!controller.requestFocus(retryOnNextRunLoop: true))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = responder
        defer { window.orderOut(nil) }

        // Enqueued after the controller's retry, so reaching this continuation
        // proves the bounded next-runloop attempt has already completed.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(controller.isFocused)
        #expect(window.firstResponder === responder)
    }

    @Test("Row focus claim survives a later disclosure reconciliation")
    func responderFocusRetryAfterDisclosureReconciliation() async throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let replacement = SidebarFocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        window.contentView?.addSubview(replacement)
        controller.attach(responder)
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus(retryOnNextRunLoop: true))
        #expect(window.makeFirstResponder(replacement))
        #expect(!controller.isFocused)

        try await Task.sleep(for: .milliseconds(150))

        #expect(controller.isFocused)
        #expect(window.firstResponder === responder)
    }

    @Test("Row focus claim survives delayed accessibility activation")
    func responderFocusRetryAfterDelayedAccessibilityActivation() async throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let accessibilityTarget = SidebarFocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        window.contentView?.addSubview(accessibilityTarget)
        controller.attach(responder)
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus(retryOnNextRunLoop: true))
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.makeFirstResponder(accessibilityTarget))
        #expect(!controller.isFocused)

        try await Task.sleep(for: .milliseconds(350))

        #expect(controller.isFocused)
        #expect(window.firstResponder === responder)
    }

    @Test("Focus retry trusts AppKit over a stale cached focus callback")
    func responderFocusRetryRepairsStaleCachedFocus() async throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let accessibilityTarget = SidebarFocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        window.contentView?.addSubview(accessibilityTarget)
        controller.attach(responder)
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus(retryOnNextRunLoop: true))
        #expect(window.makeFirstResponder(accessibilityTarget))
        #expect(!controller.isFocused)

        // Model the macOS 26 AX press path: the semantic row becomes the real
        // responder while the bridge's last callback still says it is focused.
        responder.onFocusChange?(true)
        #expect(controller.isFocused)
        #expect(window.firstResponder === accessibilityTarget)

        try await Task.sleep(for: .milliseconds(150))

        #expect(controller.isFocused)
        #expect(window.firstResponder === responder)
    }

    @Test("Row focus claim survives expanded search toolbar activation")
    func responderFocusRetryAfterExpandedSearchActivation() async throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let searchField = NSSearchField(
            frame: NSRect(x: 0, y: 0, width: 180, height: 24)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(responder)
        window.contentView?.addSubview(searchField)
        controller.attach(responder)
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus(retryOnNextRunLoop: true))
        try await Task.sleep(for: .milliseconds(750))
        #expect(window.makeFirstResponder(searchField))
        #expect(!controller.isFocused)

        try await Task.sleep(for: .milliseconds(350))

        #expect(controller.isFocused)
        #expect(window.firstResponder === responder)
    }

    @Test("Explicit editor focus cancels a pending sidebar retry")
    func explicitEditorFocusCancelsSidebarRetry() async throws {
        let controller = SidebarKeyboardFocusController()
        let responder = SidebarKeyboardResponderView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        let editor = SidebarFocusAcceptingTestView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        let window = NSWindow(
            contentRect: editor.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(responder)
        controller.attach(responder)
        defer { window.orderOut(nil) }

        #expect(controller.requestFocus(retryOnNextRunLoop: true))
        controller.cancelPendingFocusRetry()
        #expect(window.makeFirstResponder(editor))

        // Wait beyond the final bounded retry so this locks the entire retry
        // window, including the expanded-toolbar reconciliation attempt.
        try await Task.sleep(for: .milliseconds(1_100))

        #expect(!controller.isFocused)
        #expect(window.firstResponder === editor)
    }

    @Test("Physical and interpreted printable input share one callback")
    func responderInputClassification() throws {
        let responder = SidebarKeyboardResponderView(frame: .zero)
        var typeSelectInputs: [String] = []
        responder.onPrintableText = {
            typeSelectInputs.append($0)
            return true
        }

        let rejectedInputs: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("\r", 36, []),
            ("\u{1B}", 53, []),
            (" ", 49, []),
            ("\u{F700}", 122, []),
            ("p", 35, .command),
            ("p", 35, .control),
        ]
        for (characters, keyCode, flags) in rejectedInputs {
            responder.keyDown(with: try makeKeyEvent(
                characters: characters,
                keyCode: keyCode,
                flags: flags
            ))
        }

        let acceptedInputs: [(String, UInt16, NSEvent.ModifierFlags)] = [
            (".", 47, []),
            ("π", 35, .option),
            ("A", 0, .shift),
        ]
        for (characters, keyCode, flags) in acceptedInputs {
            responder.keyDown(with: try makeKeyEvent(
                characters: characters,
                keyCode: keyCode,
                flags: flags
            ))
        }

        // XCUITest / accessibility input takes NSResponder's interpreted-text
        // path instead of necessarily delivering a physical keyDown.
        responder.insertText("r")
        responder.insertText(NSAttributedString(string: "_"))

        #expect(typeSelectInputs == [".", "π", "A", "r", "_"])
    }

    @Test("Physical and standard Return and Space dispatch exactly once")
    func responderReturnAndSpaceRouting() throws {
        let responder = SidebarKeyboardResponderView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = responder
        #expect(window.makeFirstResponder(responder))
        defer { window.orderOut(nil) }

        var returnModifiers: [SidebarKeyboardModifiers] = []
        var spaces = 0
        responder.onReturn = {
            returnModifiers.append($0)
            return true
        }
        responder.onSpace = {
            spaces += 1
            return true
        }

        let commandReturn = try makeKeyEvent(
            characters: "\r",
            keyCode: 36,
            flags: .command
        )
        let plainReturn = try makeKeyEvent(
            characters: "\r",
            keyCode: 36,
            flags: []
        )
        let plainSpace = try makeKeyEvent(
            characters: " ",
            keyCode: 49,
            flags: []
        )
        let shiftedSpace = try makeKeyEvent(
            characters: " ",
            keyCode: 49,
            flags: .shift
        )
        let modifiedReturn = try makeKeyEvent(
            characters: "\r",
            keyCode: 36,
            flags: [.command, .option]
        )
        responder.keyDown(with: commandReturn)
        responder.keyDown(with: plainReturn)
        responder.keyDown(with: plainSpace)
        responder.keyDown(with: modifiedReturn)
        responder.currentEventProvider = { nil }
        responder.insertText(" ")
        responder.currentEventProvider = { shiftedSpace }
        responder.insertText(" ")
        #expect(returnModifiers == [.command, []])
        #expect(spaces == 2)

        responder.currentEventProvider = { commandReturn }
        responder.doCommand(by: NSSelectorFromString("insertNewline:"))
        #expect(returnModifiers == [.command, [], .command])

        let untrustedReturnEvents: [NSEvent?] = [
            nil,
            try makeKeyEvent(
                characters: "\r",
                keyCode: 36,
                flags: []
            ),
            try makeKeyEvent(
                characters: "\r",
                keyCode: 36,
                flags: [.command, .option]
            ),
            try makeKeyEvent(
                characters: "p",
                keyCode: 35,
                flags: .command
            ),
        ]
        for event in untrustedReturnEvents {
            responder.currentEventProvider = { event }
            responder.doCommand(
                by: NSSelectorFromString("insertNewline:")
            )
        }
        #expect(returnModifiers == [.command, [], .command])

        var rejectedReturns = 0
        responder.onReturn = { _ in
            rejectedReturns += 1
            return false
        }
        responder.currentEventProvider = { commandReturn }
        responder.keyDown(with: commandReturn)
        #expect(rejectedReturns == 1)

        var rejectedSpaces = 0
        responder.onSpace = {
            rejectedSpaces += 1
            return false
        }
        responder.currentEventProvider = { plainSpace }
        responder.keyDown(with: plainSpace)
        #expect(rejectedSpaces == 1)
    }

    @Test("Physical and accessibility navigation share one command dispatch")
    func responderNavigationCommandRouting() throws {
        let responder = SidebarKeyboardResponderView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = responder
        #expect(window.makeFirstResponder(responder))
        defer { window.orderOut(nil) }

        var commands: [SidebarKeyboardCommand] = []
        responder.onCommand = {
            commands.append($0)
            return true
        }

        let physicalCommands: [
            (characters: String, keyCode: UInt16, command: SidebarKeyboardCommand)
        ] = [
            ("\u{F700}", 126, .up),
            ("\u{F701}", 125, .down),
            ("\u{F702}", 123, .left),
            ("\u{F703}", 124, .right),
            ("\u{F729}", 115, .home),
            ("\u{F72B}", 119, .end),
            ("\u{F72C}", 116, .pageUp),
            ("\u{F72D}", 121, .pageDown),
        ]
        for input in physicalCommands {
            responder.keyDown(with: try makeKeyEvent(
                characters: input.characters,
                keyCode: input.keyCode,
                flags: []
            ))
        }
        #expect(commands == physicalCommands.map { $0.command })

        commands.removeAll()
        for flags: NSEvent.ModifierFlags in [
            .command, .option, .control, .shift,
        ] {
            responder.keyDown(with: try makeKeyEvent(
                characters: "\u{F702}",
                keyCode: 123,
                flags: flags
            ))
        }
        #expect(commands.isEmpty)

        commands.removeAll()
        let selectorCommands: [
            (name: String, command: SidebarKeyboardCommand)
        ] = [
            ("moveUp:", .up),
            ("moveDown:", .down),
            ("moveLeft:", .left),
            ("moveRight:", .right),
            ("moveToBeginningOfDocument:", .home),
            ("scrollToBeginningOfDocument:", .home),
            ("moveToEndOfDocument:", .end),
            ("scrollToEndOfDocument:", .end),
            ("pageUp:", .pageUp),
            ("scrollPageUp:", .pageUp),
            ("pageDown:", .pageDown),
            ("scrollPageDown:", .pageDown),
        ]
        for input in selectorCommands {
            responder.doCommand(by: NSSelectorFromString(input.name))
        }
        #expect(commands == selectorCommands.map { $0.command })
    }

    private func hostRow(
        configuration: SidebarAccessibilityRowConfiguration,
        onPress: @escaping () -> Bool,
        onCommand: @escaping (SidebarKeyboardCommand) -> Bool = { _ in false },
        onCustomAction: @escaping () -> Bool
    ) -> NSHostingView<SidebarAccessibilityHostedHarness> {
        let hosted = NSHostingView(
            rootView: SidebarAccessibilityHostedHarness(
                configuration: configuration,
                onPress: onPress,
                onCommand: onCommand,
                onCustomAction: onCustomAction
            )
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    private func findRow(in view: NSView) -> SidebarAccessibilityRowView? {
        if let row = view as? SidebarAccessibilityRowView {
            return row
        }
        for subview in view.subviews {
            if let row = findRow(in: subview) {
                return row
            }
        }
        return nil
    }

    private func configuration(
        isFolder: Bool,
        isExpanded: Bool,
        isSelected: Bool,
        isFocused: Bool,
        level: Int
    ) -> SidebarAccessibilityRowConfiguration {
        SidebarAccessibilityRowConfiguration(
            label: "Sources",
            identifier: "fileNode_Sources",
            level: level,
            isSelected: isSelected,
            isFocused: isFocused,
            isFolder: isFolder,
            isExpanded: isExpanded,
            value: isFolder ? "expanded" : nil,
            help: isFolder ? "Folder hint" : "File hint",
            customActionName: isFolder ? "Collapse" : "Open Preview"
        )
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private struct SidebarAccessibilityHostedHarness: View {
    let configuration: SidebarAccessibilityRowConfiguration
    let onPress: () -> Bool
    let onCommand: (SidebarKeyboardCommand) -> Bool
    let onCustomAction: () -> Bool

    var body: some View {
        SidebarAccessibilityRow(
            configuration: configuration,
            onPress: onPress,
            onCommand: onCommand,
            onCustomAction: onCustomAction
        )
        .frame(width: 220, height: 24)
    }
}

private final class SidebarFocusAcceptingTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
