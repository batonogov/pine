//
//  MenuIconTests.swift
//  PineTests
//

import AppKit
import Testing

/// Validates that all SF Symbol names used in menus resolve to real images.
/// Catches typos and non-existent symbol names at test time rather than at runtime
/// (where they silently render as blank space).
struct MenuIconTests {

    // MARK: - Main menu icons (PineApp.swift)

    @Test(arguments: [
        ("folder", "Open Folder"),
        ("square.and.arrow.down", "Save"),
        ("square.and.arrow.down.on.square", "Save All"),
        ("doc.on.doc", "Save As"),
        ("plus.square.on.square", "Duplicate"),
        ("plus.magnifyingglass", "Increase Font Size"),
        ("minus.magnifyingglass", "Decrease Font Size"),
        ("textformat.size", "Reset Font Size"),
        ("terminal", "Toggle Terminal"),
        ("doc.richtext", "Toggle Preview"),
        ("sidebar.right", "Toggle Minimap"),
        ("doc.viewfinder", "Reveal File in Finder"),
        ("folder", "Reveal Project in Finder"),
        ("plus", "New Terminal Tab"),
        ("slash.circle", "Toggle Comment"),
        ("magnifyingglass", "Find in Project"),
        ("chevron.down", "Next Change"),
        ("chevron.up", "Previous Change"),
    ])
    func mainMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }

    // MARK: - Context menu icons (ContentView.swift)

    @Test(arguments: [
        ("doc.badge.plus", "New File"),
        ("folder.badge.plus", "New Folder"),
        ("arrow.right.circle", "Reveal in Finder"),
        ("pencil", "Rename"),
        ("trash", "Delete"),
        ("doc.text", "File icon"),
    ])
    func contextMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }
}
