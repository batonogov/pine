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
@MainActor
struct MenuIconTests {

    // MARK: - Main menu icons (PineApp.swift)

    @Test(arguments: [
        (MenuIcons.openFolder, "Open Folder"),
        (MenuIcons.commandPalette, "Command Palette"),
        (MenuIcons.save, "Save"),
        (MenuIcons.saveAll, "Save All"),
        (MenuIcons.saveAs, "Save As"),
        (MenuIcons.duplicate, "Duplicate"),
        (MenuIcons.increaseFontSize, "Increase Font Size"),
        (MenuIcons.decreaseFontSize, "Decrease Font Size"),
        (MenuIcons.resetFontSize, "Reset Font Size"),
        (MenuIcons.toggleTerminal, "Toggle Terminal"),
        (MenuIcons.togglePreview, "Toggle Markdown Preview"),
        (MenuIcons.toggleMinimap, "Minimap"),
        (MenuIcons.revealFileInFinder, "Reveal File in Finder"),
        (MenuIcons.revealProjectInFinder, "Reveal Project in Finder"),
        (MenuIcons.newTerminalTab, "New Terminal Tab"),
        (MenuIcons.toggleComment, "Toggle Comment"),
        (MenuIcons.findInProject, "Find in Project"),
        (MenuIcons.nextChange, "Next Change"),
        (MenuIcons.previousChange, "Previous Change"),
        (MenuIcons.switchBranch, "Switch Branch"),
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

    // MARK: - Project switcher icons (ProjectSwitcherView.swift, #1470)

    // The switcher shipped with `folder.stack`, which is not an SF Symbol.
    // It rendered as nothing and stayed unnoticed because a text label sat
    // beside it. Its toolbar control can now be icon-only, so a missing
    // symbol would leave an empty capsule holding nothing but the toolbar's
    // own disclosure chevron.
    @Test(arguments: [
        (MenuIcons.projectSwitcher, "Project switcher toolbar control"),
        (MenuIcons.projectSwitcherNewAgent, "New Agent"),
        (MenuIcons.projectSwitcherOpenFolder, "Open Folder (switcher menu)"),
        (MenuIcons.projectSwitcherActive, "Active project checkmark"),
        (MenuIcons.projectSwitcherProject, "Inactive project"),
        (MenuIcons.switchProjectInWindow, "Switch Project (menu bar)"),
        (MenuIcons.nextProjectInWindow, "Next Project"),
        (MenuIcons.previousProjectInWindow, "Previous Project"),
        (MenuIcons.agentWorktrees, "Manage Agent Worktrees (#1524)"),
    ])
    func projectSwitcherIconExists(_ symbol: String, _ element: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(element)' does not exist"
        )
    }

    // MARK: - Agent worktree state icons (ProjectSwitcherView.swift)

    @Test(arguments: [
        ("checkmark", "Active worktree"),
        ("exclamationmark.circle.fill", "Worktree waiting for input"),
        ("xmark.circle.fill", "Failed worktree"),
        ("checkmark.circle", "Completed worktree"),
        ("circle.fill", "Live worktree"),
        ("circle", "Idle worktree"),
    ])
    func worktreeStateIconExists(_ symbol: String, _ state: String) {
        // These encode agent state in the switcher menu. A missing symbol
        // makes two different states look identical rather than merely blank.
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(state)' does not exist"
        )
    }
}
