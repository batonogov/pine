//
//  MenuIconTests.swift
//  PineTests
//

import AppKit
import Testing
@testable import Pine

/// Validates that all SF Symbol names in ``MenuIcons`` resolve to real images.
/// Catches typos and non-existent symbol names at test time rather than at runtime
/// (where they silently render as blank space).
struct MenuIconTests {

    // MARK: - Main menu icons (PineApp.swift)

    @Test(arguments: [
        (MenuIcons.openFolder, "Open Folder"),
        (MenuIcons.save, "Save"),
        (MenuIcons.saveAll, "Save All"),
        (MenuIcons.saveAs, "Save As"),
        (MenuIcons.duplicate, "Duplicate"),
        (MenuIcons.increaseFontSize, "Increase Font Size"),
        (MenuIcons.decreaseFontSize, "Decrease Font Size"),
        (MenuIcons.resetFontSize, "Reset Font Size"),
        (MenuIcons.toggleTerminal, "Toggle Terminal"),
        (MenuIcons.togglePreview, "Toggle Preview"),
        (MenuIcons.toggleMinimap, "Toggle Minimap"),
        (MenuIcons.revealFileInFinder, "Reveal File in Finder"),
        (MenuIcons.revealProjectInFinder, "Reveal Project in Finder"),
        (MenuIcons.newTerminalTab, "New Terminal Tab"),
        (MenuIcons.toggleComment, "Toggle Comment"),
        (MenuIcons.findInProject, "Find in Project"),
        (MenuIcons.nextChange, "Next Change"),
        (MenuIcons.previousChange, "Previous Change"),
    ])
    func mainMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }

    // MARK: - Context menu icons (ContentView.swift)

    @Test(arguments: [
        (MenuIcons.newFile, "New File"),
        (MenuIcons.newFolder, "New Folder"),
        (MenuIcons.revealInFinder, "Reveal in Finder"),
        (MenuIcons.rename, "Rename"),
        (MenuIcons.delete, "Delete"),
    ])
    func contextMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }
}
