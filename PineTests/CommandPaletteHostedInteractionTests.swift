//
//  CommandPaletteHostedInteractionTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Command palette hosted keyboard interaction")
@MainActor
struct CommandPaletteHostedInteractionTests {
    @Test("Hosted palette exposes its identifier on the native text field")
    func nativeAccessibilityIdentifier() throws {
        let state = HostedState()
        let hosted = hostPalette(state: state, items: makeItems())
        let field = try #require(
            findTextField(in: hosted) as? CommandOverlayTextField
        )

        #expect(field.isAccessibilityElement())
        #expect(field.accessibilityRole() == .textField)
        #expect(
            field.accessibilityIdentifier()
                == AccessibilityID.commandPaletteSearchField
        )
        #expect(
            field.identifier?.rawValue
                == AccessibilityID.commandPaletteSearchField
        )
        #expect(
            field.accessibilityLabel()
                == String(localized: "commandPalette.placeholder")
        )
    }

    @Test("Arrow navigation and Return invoke the selected row")
    func arrowAndReturn() throws {
        let state = HostedState()
        let hosted = hostPalette(state: state, items: makeItems())
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )
        let editor = NSTextView()

        #expect(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        drainMainRunLoop()

        #expect(state.invoked == [.task("second")])
        #expect(state.presentationAtInvocation == [.commandPalette])
        #expect(state.isPresented == false)
    }

    @Test("Arrow navigation immediately announces the selected command")
    func arrowAnnouncesSelection() throws {
        let state = HostedState()
        let hosted = hostPalette(state: state, items: makeItems())
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))

        // Soft expectations first: a `#require` throws out of the test, so
        // anything ordered after it is missing from the failure report exactly
        // when the report matters most.
        #expect(state.announcements.count == 1)
        #expect(state.isPresented)
        // `#require`, never a bare subscript: a hosted view that has not
        // settled announces nothing, and a subscript on the empty result traps
        // the whole `PineTests` process instead of failing this test (#1506).
        let announced = try #require(state.announcements.first)
        #expect(announced.contains("Second Task"))
        _ = hosted
    }

    @Test("Invocation can replace Command Palette without stale dismissal")
    func replacementSurvivesInvocation() throws {
        let state = HostedState()
        state.replacementOnInvoke = .quickOpen
        let hosted = hostPalette(state: state, items: makeItems())
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        drainMainRunLoop()

        #expect(state.invoked == [.builtIn(.quickOpen)])
        #expect(state.presentationAtInvocation == [.commandPalette])
        #expect(state.activePresentation == .quickOpen)
    }

    @Test("Escape dismisses without invoking a command")
    func escapeDismisses() throws {
        let state = HostedState()
        let hosted = hostPalette(state: state, items: makeItems())
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        drainMainRunLoop()

        #expect(state.isPresented == false)
        #expect(state.invoked.isEmpty)
    }

    @Test("Initial keyboard selection skips a disabled first row")
    func initialSelectionSkipsDisabledRow() throws {
        let state = HostedState()
        var items = makeItems()
        items[0] = CommandPaletteItem(
            id: items[0].id,
            title: items[0].title,
            subtitle: items[0].subtitle,
            searchTerms: items[0].searchTerms,
            iconName: items[0].iconName,
            shortcut: items[0].shortcut,
            isEnabled: false,
            unavailabilityReason: Strings.commandPaletteRequiresProject
        )
        let hosted = hostPalette(state: state, items: items)
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        drainMainRunLoop()

        #expect(state.invoked == [.task("second")])
        #expect(state.isPresented == false)
    }

    @Test("Arrow navigation skips disabled rows")
    func arrowNavigationSkipsDisabledRows() throws {
        let state = HostedState()
        var items = makeItems()
        items[1] = CommandPaletteItem(
            id: items[1].id,
            title: items[1].title,
            subtitle: items[1].subtitle,
            searchTerms: items[1].searchTerms,
            iconName: items[1].iconName,
            shortcut: items[1].shortcut,
            isEnabled: false,
            unavailabilityReason: Strings.commandPaletteRequiresProject
        )
        let hosted = hostPalette(state: state, items: items)
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        drainMainRunLoop()

        #expect(state.invoked == [.builtIn(.findInFile)])
        #expect(state.isPresented == false)
    }

    @Test("All-disabled results remain visible and Return is a no-op")
    func allDisabledRowsDoNotInvoke() throws {
        let state = HostedState()
        let items = makeItems().map { item in
            CommandPaletteItem(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                searchTerms: item.searchTerms,
                iconName: item.iconName,
                shortcut: item.shortcut,
                isEnabled: false,
                unavailabilityReason: Strings.commandPaletteRequiresProject
            )
        }
        let hosted = hostPalette(state: state, items: items)
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        drainMainRunLoop()

        #expect(state.isPresented)
        #expect(state.invoked.isEmpty)
        #expect(items.allSatisfy { $0.unavailabilityReason != nil })
    }

    @Test("Selected command rows expose the selected accessibility trait")
    func selectedRowAccessibilityTrait() {
        let selected = CommandOverlayRowAccessibility.selectionTraits(
            isSelected: true
        )
        let unselected = CommandOverlayRowAccessibility.selectionTraits(
            isSelected: false
        )

        #expect(selected.contains(.isSelected))
        #expect(!unselected.contains(.isSelected))
    }

    private func makeItems() -> [CommandPaletteItem] {
        [
            makeItem(id: .builtIn(.quickOpen), title: "Quick Open"),
            makeItem(id: .task("second"), title: "Second Task"),
            makeItem(id: .builtIn(.findInFile), title: "Find"),
        ]
    }

    private func makeItem(
        id: CommandPaletteItemID,
        title: String
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            subtitle: "Test",
            searchTerms: [title],
            iconName: "command",
            shortcut: CommandShortcutPresentation(chord: nil, state: .none),
            isEnabled: true
        )
    }

    private func hostPalette(
        state: HostedState,
        items: [CommandPaletteItem]
    ) -> NSHostingView<HostedHarness> {
        let harness = HostedHarness(state: state, items: items)
        let hosted = NSHostingView(rootView: harness)
        hosted.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
        hosted.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField {
            return field
        }
        for subview in view.subviews {
            if let field = findTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}

@MainActor
private final class HostedState {
    var activePresentation: CommandOverlayPresentation? = .commandPalette
    var replacementOnInvoke: CommandOverlayPresentation?
    var invoked: [CommandPaletteItemID] = []
    var presentationAtInvocation: [CommandOverlayPresentation?] = []
    var announcements: [String] = []

    var isPresented: Bool {
        get { activePresentation == .commandPalette }
        set {
            if newValue {
                activePresentation = .commandPalette
            } else if activePresentation == .commandPalette {
                activePresentation = nil
            }
        }
    }
}

private struct HostedHarness: View {
    let state: HostedState
    let items: [CommandPaletteItem]

    var body: some View {
        CommandPaletteView(
            isPresented: Binding(
                get: { state.isPresented },
                set: { state.isPresented = $0 }
            ),
            items: items,
            onAnnounce: {
                state.announcements.append($0)
                return true
            },
            onInvoke: {
                state.presentationAtInvocation.append(
                    state.activePresentation
                )
                state.invoked.append($0.id)
                if let replacement = state.replacementOnInvoke {
                    state.activePresentation = replacement
                }
            }
        )
    }
}
