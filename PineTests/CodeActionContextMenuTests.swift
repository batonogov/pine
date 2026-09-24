//
//  CodeActionContextMenuTests.swift
//  PineTests
//
//  Issue #1611: the LSP code-action context menu must not define keyboard
//  shortcuts. Its Rename row used to display ⌘R — Go to Symbol's chord —
//  and a keyboard-operable open menu let that chord fire Rename instead of
//  the global command.
//

import AppKit
import Testing

@testable import Pine

@Suite("LSP code-action context menu")
@MainActor
struct CodeActionContextMenuTests {

    /// The regression behind #1611: ⌘R on the Rename row must be gone, and
    /// no other row may claim a chord either — a context menu is a shortcut
    /// surface, not a shortcut definition.
    @Test("no row carries a key equivalent")
    func noRowCarriesAKeyEquivalent() {
        let menu = makeMenu()

        for item in menu.items where !item.isSeparatorItem {
            #expect(
                item.keyEquivalent.isEmpty,
                "\"\(item.title)\" must not carry a key equivalent"
            )
        }
    }

    @Test("rename row keeps its action and follows a separator")
    func renameRowKeepsActionAfterSeparator() throws {
        let menu = makeMenu()

        let renameItems = menu.items.filter {
            $0.title == Strings.contextRenameTitle
        }
        #expect(renameItems.count == 1)
        let renameItem = try #require(renameItems.first)
        let index = menu.index(of: renameItem)
        #expect(index > 0)
        #expect(menu.items[index - 1].isSeparatorItem)
        // The row stays wired to the rename handler (the handler itself is
        // private, so the selector is compared by name).
        #expect(
            renameItem.action == NSSelectorFromString("handleRenameFromMenu:")
        )
    }

    @Test("actions and commands keep their rows, targets, and enabled state")
    func actionsAndCommandsKeepRows() throws {
        let response = LSPCodeActionResponse(result: [
            ["title": "Fix", "kind": "quickfix", "edit": ["changes": [:]]],
            ["title": "Not executable", "kind": "refactor"],
            ["title": "Run tool", "command": "tool.run"],
        ])

        let menu = CodeEditorView.Coordinator.makeCodeActionMenu(
            response: response,
            target: nil
        )

        let rows = menu.items.filter { !$0.isSeparatorItem }
        let titles = rows.map(\.title)
        #expect(titles == [
            "Fix",
            "Not executable",
            "Run tool",
            Strings.contextRenameTitle
        ])
        // "Not executable" has neither an edit nor a command.
        #expect(!rows[1].isEnabled)
        #expect(rows[0].isEnabled)
        #expect(rows[2].isEnabled)
        #expect(rows[3].isEnabled)
        // Rows with no explicit target would fall into the responder chain.
        for row in rows {
            #expect(row.target == nil)
        }
        // A quickfix kind resolves to a symbol image.
        #expect(rows[0].image != nil)
        // Each row stays wired to its handler (the handlers are private, so
        // the selectors are compared by name).
        #expect(rows[0].action == NSSelectorFromString("handleCodeActionSelection:"))
        #expect(rows[1].action == NSSelectorFromString("handleCodeActionSelection:"))
        #expect(rows[2].action == NSSelectorFromString("handleCodeCommandSelection:"))
        #expect(rows[3].action == NSSelectorFromString("handleRenameFromMenu:"))
        // Actions and commands carry their payload; the rename row carries
        // none.
        #expect(rows[0].representedObject != nil)
        #expect(rows[1].representedObject != nil)
        #expect(rows[2].representedObject != nil)
        #expect(rows[3].representedObject == nil)
    }

    /// The Rename row survives even when the server offers nothing, so the
    /// menu is never reduced to a dangling separator.
    @Test("rename row is present when the server offers no actions")
    func renameRowSurvivesEmptyResponse() {
        let response = LSPCodeActionResponse(result: nil)

        let menu = CodeEditorView.Coordinator.makeCodeActionMenu(
            response: response,
            target: nil
        )

        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(rows.count == 1)
        #expect(rows[0].title == Strings.contextRenameTitle)
    }

    // MARK: - Helpers

    private func makeMenu(target: AnyObject? = nil) -> NSMenu {
        let response = LSPCodeActionResponse(result: [
            ["title": "Fix", "kind": "quickfix", "edit": ["changes": [:]]],
            ["title": "Run tool", "command": "tool.run"],
        ])
        return CodeEditorView.Coordinator.makeCodeActionMenu(
            response: response,
            target: target
        )
    }
}
