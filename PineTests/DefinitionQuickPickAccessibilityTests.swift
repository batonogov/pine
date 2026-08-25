//
//  DefinitionQuickPickAccessibilityTests.swift
//  PineTests
//
//  Whether the go-to-definition quick pick can be used at all without a mouse
//  (#1533).
//
//  Two separate defects lived here. The rows were `onTapGesture` on an
//  `HStack`, so the accessibility tree carried unnamed fragments of static
//  text and no way to activate anything. And the Escape/arrow/Return handlers
//  sat on a backdrop that was never focusable — a view that cannot take focus
//  never receives a key press, so the keyboard path was decorative.
//
//  The row assertions read the published tree and then *press* what they
//  find, because publishing a button that is wired to nothing looks identical
//  from the outside.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Definition quick pick accessibility (#1533)", .serialized)
@MainActor
struct DefinitionQuickPickAccessibilityTests {

    private static let overlaySize = NSSize(width: 640, height: 480)

    // MARK: - Rows

    @Test("every row is published as one named, activatable stop")
    func rowsArePublishedAsNamedButtons() throws {
        let controller = makeController()
        let hosted = host(controller)
        defer { hosted.tearDown() }

        for (index, item) in controller.items.enumerated() {
            let row = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: AccessibilityID.definitionQuickPickRow(index)
                ),
                """
                row \(index) is not in the published tree — the quick pick is \
                reachable by mouse only
                """
            )
            let announced = try #require(
                AccessibilityTreeProbe.label(of: row),
                "row \(index) publishes no name"
            )

            #expect(
                announced.contains(item.label),
                "row \(index) announces \"\(announced)\" without its symbol"
            )
            #expect(
                announced.contains(item.detail),
                """
                row \(index) announces "\(announced)" without its location. \
                Every row in this list shares a symbol name — the location is \
                the only thing that tells them apart, which is the entire \
                reason the list is shown.
                """
            )
            #expect(
                AccessibilityTreeProbe.role(of: row) == .button,
                "row \(index) is not published as something to activate"
            )
        }
    }

    @Test("the selected row is published as selected, and only that one")
    func selectionIsPublished() throws {
        let controller = makeController()
        controller.select(at: 2)
        let hosted = host(controller)
        defer { hosted.tearDown() }

        let selected = try (0..<controller.items.count).filter { index in
            let row = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: AccessibilityID.definitionQuickPickRow(index)
                )
            )
            return AccessibilityTreeProbe.isSelected(of: row)
        }

        #expect(
            selected == [2],
            """
            \(selected) rows are published as selected. Without the trait, \
            arrowing through the list moves a highlight VoiceOver cannot see.
            """
        )
    }

    /// The load-bearing one. Press the row the way VoiceOver presses it and
    /// require the selection to have actually been made.
    @Test("pressing a row through the accessibility tree opens that definition")
    func pressingARowSelectsIt() throws {
        let controller = makeController()
        var chosen: [DefinitionQuickPickItem] = []
        controller.onSelect = { chosen.append($0) }
        let hosted = host(controller)
        defer { hosted.tearDown() }

        let row = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.definitionQuickPickRow(1)
            )
        )

        #expect(
            AccessibilityTreeProbe.performPress(row) == true,
            """
            the row publishes no press. Its only activation was a tap \
            gesture, which the accessibility tree cannot reach.
            """
        )
        #expect(chosen.map(\.id) == [Self.expectedItems[1].id])
        #expect(!controller.isVisible, "choosing a definition must dismiss")
    }

    // MARK: - Container

    @Test("the list is a named container and the backdrop is not published")
    func listIsNamedAndBackdropIsSilent() throws {
        let controller = makeController()
        let hosted = host(controller)
        defer { hosted.tearDown() }

        let list = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.definitionQuickPickList
            ),
            "the quick pick list publishes no container"
        )
        #expect(
            AccessibilityTreeProbe.label(of: list)
                == Strings.a11yDefinitionQuickPickLabel
        )

        let rows = AccessibilityTreeProbe.elements(
            under: hosted.root,
            identifierPrefix: "definitionQuickPickRow_"
        )
        #expect(rows.count == controller.items.count)

        // The backdrop is a full-bleed rectangle carrying its own dismissal
        // tap. Published, it becomes an unnamed activatable stop the size of
        // the window, sitting over the list and cancelling on activation.
        let activatable = AccessibilityTreeProbe.elements(under: hosted.root)
            .filter { AccessibilityTreeProbe.role(of: $0) == .button }
        let activatableIdentifiers = activatable
            .map { AccessibilityTreeProbe.identifier(of: $0) ?? "«unnamed»" }
        #expect(
            activatableIdentifiers.sorted()
                == (0..<controller.items.count)
                    .map(AccessibilityID.definitionQuickPickRow)
                    .sorted(),
            """
            the quick pick publishes \(activatableIdentifiers) as activatable \
            — anything beyond the rows is the dismissal backdrop, which \
            VoiceOver would offer as an unnamed button covering the list
            """
        )
    }

    // MARK: - Keyboard

    /// The controller half of the keyboard path. `onKeyPress` now sits on a
    /// focusable view, but what those handlers call has to survive too.
    @Test("arrow, Return and Escape reach the controller and wrap at the ends")
    func keyboardCommandsDriveTheController() throws {
        let controller = makeController()
        var chosen: [DefinitionQuickPickItem] = []
        var dismissals = 0
        controller.onSelect = { chosen.append($0) }
        controller.onDismiss = { dismissals += 1 }

        controller.move(by: 1)
        #expect(controller.selectedIndex == 1)
        controller.move(by: -1)
        #expect(controller.selectedIndex == 0)
        controller.move(by: -1)
        #expect(
            controller.selectedIndex == controller.items.count - 1,
            "arrowing up from the first row must wrap to the last"
        )
        controller.move(by: 1)
        #expect(controller.selectedIndex == 0)

        controller.selectCurrent()
        #expect(chosen.map(\.id) == [Self.expectedItems[0].id])

        controller.present(items: Self.expectedItems)
        controller.cancel()
        #expect(dismissals == 1)
        #expect(!controller.isVisible)
    }

    /// A row whose location is empty must not be announced with a dangling
    /// separator — VoiceOver reads punctuation out loud.
    @Test("a row with no location is announced as its symbol alone")
    func rowWithoutDetailIsAnnouncedPlainly() {
        let item = DefinitionQuickPickItem(
            label: "resolve",
            detail: "",
            url: URL(fileURLWithPath: "/tmp/a.swift"),
            line: 1,
            character: 0
        )

        #expect(
            DefinitionQuickPickItem.accessibilityLabel(for: item) == "resolve"
        )
    }

    // MARK: - Fixture

    private static let expectedItems: [DefinitionQuickPickItem] = [
        DefinitionQuickPickItem(
            label: "resolve(_:)",
            detail: "Resolver.swift:12",
            url: URL(fileURLWithPath: "/tmp/Resolver.swift"),
            line: 12,
            character: 4
        ),
        DefinitionQuickPickItem(
            label: "resolve(_:)",
            detail: "Resolver+Cache.swift:48",
            url: URL(fileURLWithPath: "/tmp/Resolver+Cache.swift"),
            line: 48,
            character: 4
        ),
        DefinitionQuickPickItem(
            label: "resolve(_:)",
            detail: "ResolverTests.swift:9",
            url: URL(fileURLWithPath: "/tmp/ResolverTests.swift"),
            line: 9,
            character: 4
        ),
    ]

    private func makeController() -> DefinitionQuickPickController {
        let controller = DefinitionQuickPickController()
        controller.present(items: Self.expectedItems)
        return controller
    }

    private func host(
        _ controller: DefinitionQuickPickController
    ) -> AccessibilityTreeProbe.Hosted {
        AccessibilityTreeProbe.host(
            DefinitionQuickPickOverlay(controller: controller),
            size: Self.overlaySize
        )
    }
}
