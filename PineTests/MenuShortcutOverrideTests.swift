//
//  MenuShortcutOverrideTests.swift
//  PineTests
//
//  Issue #1539: menu items that spell their key equivalent out in source
//  ignore the user's keybinding override, so a rebound command answers to
//  both chords and the menu advertises the wrong one.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Menu key equivalents come from the override system")
@MainActor
struct MenuShortcutOverrideTests {
    /// A key equivalent as a menu item advertises it.
    ///
    /// `KeyEquivalent` is not `Equatable`, so comparisons go through
    /// `character`; the type exists to keep the table below readable.
    struct AdvertisedShortcut {
        let key: KeyEquivalent
        let modifiers: EventModifiers

        init(_ key: KeyEquivalent, _ modifiers: EventModifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// The key equivalent every rebindable menu item advertised *before*
    /// #1539, transcribed from the `.keyboardShortcut(…)` literals the menu
    /// used to carry.
    ///
    /// Writing them out a second time is the point. Routing an item through
    /// `effectiveKeyboardShortcut` has to preserve what the menu shows, and
    /// the one way that can fail silently is a built-in chord the menu layer
    /// cannot render: `MenuKeyboardShortcut` returns `nil`, the item loses
    /// its key equivalent, and nothing else in the app notices. This table is
    /// the independent record of what each item is supposed to show.
    ///
    /// Commands added *after* #1539 have no "before" to transcribe — they are
    /// born reading `effectiveChord(for:)`. They still belong here: the table
    /// is asserted to cover every command with a built-in chord, so a new
    /// rebindable command cannot arrive without a record of what its menu
    /// item shows. `.newAgent` (#1566) is the first of those.
    static var advertisedShortcuts: [UserCommand: AdvertisedShortcut] {
        [
            // File
            .newFile: AdvertisedShortcut("n", .command),
            .openFile: AdvertisedShortcut("o", .command),
            .openFolder: AdvertisedShortcut("o", [.command, .shift]),
            .quickOpen: AdvertisedShortcut("p", .command),
            .commandPalette: AdvertisedShortcut("p", [.command, .option]),
            .symbolNavigator: AdvertisedShortcut("r", .command),
            .closeTab: AdvertisedShortcut("w", .command),
            .closeProject: AdvertisedShortcut("w", [.command, .control]),
            .closeWindow: AdvertisedShortcut("w", [.command, .shift]),
            .save: AdvertisedShortcut("s", .command),
            .saveAll: AdvertisedShortcut("s", [.command, .option]),
            .saveAs: AdvertisedShortcut("s", [.command, .shift]),
            .duplicate: AdvertisedShortcut("d", [.command, .shift]),
            // Edit
            .toggleComment: AdvertisedShortcut("/", .command),
            .findInFile: AdvertisedShortcut("f", .command),
            .findAndReplace: AdvertisedShortcut("f", [.command, .option]),
            .findNext: AdvertisedShortcut("g", .command),
            .findPrevious: AdvertisedShortcut("g", [.command, .shift]),
            .useSelectionForFind: AdvertisedShortcut("e", .command),
            .findInProject: AdvertisedShortcut("f", [.command, .shift]),
            .goToLine: AdvertisedShortcut("l", .command),
            .nextChange: AdvertisedShortcut(.downArrow, [.control, .option]),
            .previousChange: AdvertisedShortcut(.upArrow, [.control, .option]),
            .acceptChange: AdvertisedShortcut(.return, [.control, .option]),
            .revertChange: AdvertisedShortcut(.delete, [.control, .option]),
            .foldCode: AdvertisedShortcut(.leftArrow, [.command, .option]),
            .unfoldCode: AdvertisedShortcut(.rightArrow, [.command, .option]),
            .foldAll: AdvertisedShortcut(
                .leftArrow, [.command, .option, .shift]
            ),
            .unfoldAll: AdvertisedShortcut(
                .rightArrow, [.command, .option, .shift]
            ),
            // View
            .increaseFontSize: AdvertisedShortcut("+", .command),
            .decreaseFontSize: AdvertisedShortcut("-", .command),
            .resetFontSize: AdvertisedShortcut("0", .command),
            .toggleTerminal: AdvertisedShortcut("`", .command),
            .togglePreview: AdvertisedShortcut("p", [.command, .shift]),
            .toggleMinimap: AdvertisedShortcut("m", [.command, .shift]),
            .toggleBlame: AdvertisedShortcut("b", [.command, .control]),
            // ⌥Z claimed a typeable letter app-wide (#1564): ⌘ joins the
            // chord so the Z mnemonic survives without stealing text input.
            .toggleWordWrap: AdvertisedShortcut("z", [.command, .option]),
            .showProblems: AdvertisedShortcut("x", [.command, .shift]),
            // Bare F8/⇧F8 needed Fn under default settings and collided with
            // system feature keys (#1564). ⌥⌘↓/↑ mirror Next/Previous Change
            // (⌃⌥↓/↑) on the Command modifier family.
            .nextDiagnostic: AdvertisedShortcut(.downArrow, [.command, .option]),
            .previousDiagnostic: AdvertisedShortcut(.upArrow, [.command, .option]),
            .revealFileInFinder: AdvertisedShortcut("r", [.command, .shift]),
            .showAgentInbox: AdvertisedShortcut("i", [.command, .shift]),
            .newAgent: AdvertisedShortcut("a", [.command, .shift]),
            // Git
            .showBranchSwitcher: AdvertisedShortcut("b", [.command, .shift]),
            // Terminal
            .newTerminalTab: AdvertisedShortcut("t", .command),
            .sendToTerminal: AdvertisedShortcut(.return, [.command, .shift]),
            .toggleTerminalZoom: AdvertisedShortcut(
                .return, [.command, .option]
            ),
        ]
    }

    // MARK: - The chord the menu shows

    /// With no user configuration loaded, every rebindable command must come
    /// out of the override layer showing exactly the chord it always showed.
    ///
    /// This is the half of #1539 that a purely mechanical edit gets wrong:
    /// `.keyboardShortcut(KeyEquivalent("\u{F70B}"))` renders F8 whether or
    /// not the chord grammar can name that key, while
    /// `effectiveKeyboardShortcut(keybindings.effectiveChord(for:))` renders
    /// nothing at all when it cannot.
    @Test("built-in chords survive the trip through the override layer")
    func builtInChordsRenderThroughTheOverrideLayer() throws {
        let keybindings = UserKeybindingRegistry()

        for (command, expected) in Self.advertisedShortcuts {
            let shortcut = try #require(
                MenuKeyboardShortcut(keybindings.effectiveChord(for: command)),
                "\(command.rawValue) renders no menu key equivalent"
            )
            #expect(
                shortcut.key.character == expected.key.character,
                "\(command.rawValue) key equivalent"
            )
            #expect(
                shortcut.modifiers == expected.modifiers,
                "\(command.rawValue) modifiers"
            )
        }
    }

    /// Ties the table to the command list, so a new rebindable command cannot
    /// be added with a built-in chord and no record of what its menu item is
    /// supposed to show.
    @Test("the table covers exactly the commands that own a built-in chord")
    func tableCoversEveryCommandWithABuiltInChord() {
        let withBuiltInChords = Set(
            UserCommand.allCases.filter { $0.defaultChord != nil }
        )

        #expect(Set(Self.advertisedShortcuts.keys) == withBuiltInChords)
    }

    // MARK: - The chord the menu shows after a rebind

    /// The user-visible symptom in #1539: a rebound command answers to both
    /// chords. The override has to *replace* the built-in one — in the menu
    /// and in dispatch.
    @Test("a rebind replaces the advertised chord instead of adding to it")
    func rebindReplacesTheAdvertisedChord() async throws {
        let keybindings = try await Self.registry(
            loading: #"[{"command": "findInFile", "key": "cmd+k"}]"#
        )

        let shortcut = try #require(
            MenuKeyboardShortcut(keybindings.effectiveChord(for: .findInFile))
        )
        #expect(shortcut.key.character == "k")
        #expect(shortcut.modifiers == .command)
        #expect(
            keybindings.suppressesBuiltInShortcut(
                for: try #require(Self.keyDown("f", modifiers: .command))
            )
        )
    }

    /// The same replacement, for a command whose built-in chord is an arrow
    /// key: the user's new chord must retire the arrow chord underneath.
    /// (Before #1564 this test used F8 — bare function keys are no longer
    /// built-in chords, but a user may still bind one, so the grammar below
    /// keeps naming them.)
    @Test("rebinding a command retires its replaced chord")
    func rebindRetiresAFunctionKeyChord() async throws {
        let keybindings = try await Self.registry(
            loading: #"[{"command": "nextDiagnostic", "key": "cmd+j"}]"#
        )

        let shortcut = try #require(
            MenuKeyboardShortcut(
                keybindings.effectiveChord(for: .nextDiagnostic)
            )
        )
        #expect(shortcut.key.character == "j")
        #expect(
            keybindings.suppressesBuiltInShortcut(
                for: try #require(
                    Self.keyDown("↓", modifiers: [.command, .option], keyCode: 125)
                )
            )
        )
    }

    /// `f1` … `f20` have to round-trip through the chord grammar, so a user
    /// can bind them (`FunctionKeyToken`, #1539) even though no built-in
    /// command carries one anymore (#1564).
    @Test("the chord grammar names function keys")
    func chordGrammarNamesFunctionKeys() throws {
        let parsed = try #require(UserKeybindingRegistry.parse("f8"))
        #expect(parsed.key == "f8")
        #expect(parsed.modifiers.isEmpty)
        #expect(parsed.displayText == "F8")
        #expect(
            UserKeybindingRegistry.keyToken(
                keyCode: 100,
                charactersIgnoringModifiers: "\u{F70B}"
            ) == "f8"
        )
        #expect(UserKeybindingRegistry.parse("f21") == nil)
        #expect(UserKeybindingRegistry.parse("ff") == nil)
    }

    // MARK: - Helpers

    private static func registry(
        loading json: String
    ) async throws -> UserKeybindingRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-menu-chord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")
        try Data(json.utf8).write(to: file)

        let keybindings = UserKeybindingRegistry()
        #expect(await keybindings.load(from: file).outcome == .loaded)
        return keybindings
    }

    private static func keyDown(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
