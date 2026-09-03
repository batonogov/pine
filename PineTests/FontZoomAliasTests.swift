//
//  FontZoomAliasTests.swift
//  PineTests
//
//  The ⌘= half of #1564. The Zoom In item advertises ⌘+, which on a US
//  layout means the user must press ⇧⌘= (the key's shifted glyph). Apple
//  apps answer to ⌘= as well; Pine cannot express that as a second menu
//  item — SwiftUI Commands has no hidden items, and the chord grammar
//  cannot spell "cmd++" because "+" is its separator — so the alias rides
//  the physical-key router with an exact-modifier match on the physical key
//  position, the same layout-independence the system's own shortcuts use.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Font zoom aliases answer beside their menu chords")
struct FontZoomAliasTests {
    private static func zoom(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        increaseFontSizeRebound: Bool = false,
        decreaseFontSizeRebound: Bool = false
    ) -> FontZoomAliasPolicy.Zoom? {
        FontZoomAliasPolicy.zoom(
            keyCode: keyCode,
            modifiers: modifiers,
            increaseFontSizeRebound: increaseFontSizeRebound,
            decreaseFontSizeRebound: decreaseFontSizeRebound
        )
    }

    @Test("Command on the physical Equal key zooms in")
    func commandEqualZoomsIn() {
        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.equalSign,
                modifiers: .command
            ) == .increase
        )
    }

    @Test("Shift-Command on the physical Minus key zooms out")
    func shiftCommandMinusZoomsOut() {
        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.minus,
                modifiers: [.command, .shift]
            ) == .decrease
        )
    }

    /// ⇧⌘= is how ⌘+ is typed on a US layout — the menu owns that event. An
    /// alias that claimed it would invert zoom-in into zoom-out. Symmetrically,
    /// ⌘- alone is the Zoom Out menu chord and must reach NSMenu unclaimed.
    @Test("the primary chords stay with the menu")
    func primaryChordsStayWithTheMenu() {
        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.equalSign,
                modifiers: [.command, .shift]
            ) == nil,
            "⇧⌘= types ⌘+; claiming it here would invert Zoom In"
        )
        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.minus,
                modifiers: .command
            ) == nil,
            "⌘- is the Zoom Out menu chord; the router must not claim it"
        )
    }

    /// Extra modifiers mean the user pressed something else entirely; an
    /// alias must not fire and eat an event another handler may own.
    @Test("modifier sets match exactly")
    func modifierSetsMatchExactly() {
        for modifiers in [
            NSEvent.ModifierFlags([.command, .option]),
            NSEvent.ModifierFlags([.command, .control]),
            NSEvent.ModifierFlags([.command, .option, .shift]),
            NSEvent.ModifierFlags(),
        ] {
            #expect(
                Self.zoom(
                    keyCode: KeyboardShortcutMatcher.PhysicalKey.equalSign,
                    modifiers: modifiers
                ) == nil,
                "modifiers \(modifiers.rawValue) must not trigger the alias"
            )
        }
    }

    /// The alias is part of the command's built-in chord, so a user rebind
    /// replaces it — the same replacement rule `effectiveChord` applies to
    /// the menu chord (#1539), checked here against a real loaded registry.
    @Test("a user rebind retires the alias")
    func rebindRetiresTheAlias() async throws {
        let keybindings = try await Self.registry(
            loading: #"""
            [
              {"command": "increaseFontSize", "key": "cmd+k"},
              {"command": "decreaseFontSize", "key": "cmd+j"}
            ]
            """#
        )

        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.equalSign,
                modifiers: .command,
                increaseFontSizeRebound: keybindings.hasOverride(
                    for: .increaseFontSize
                )
            ) == nil,
            "⌘= must stop zooming once Increase Font Size is rebound"
        )
        #expect(
            Self.zoom(
                keyCode: KeyboardShortcutMatcher.PhysicalKey.minus,
                modifiers: [.command, .shift],
                decreaseFontSizeRebound: keybindings.hasOverride(
                    for: .decreaseFontSize
                )
            ) == nil,
            "⇧⌘- must stop zooming once Decrease Font Size is rebound"
        )
    }

    /// The numeric keypad has its own Plus/Minus/Equals keys (kVK_ANSI_
    /// KeypadPlus 69, KeypadMinus 78, KeypadEquals 81). They are not the
    /// aliases: ⌘-plus-pad still reaches NSMenu as ⌘+, and a future
    /// `|| keyCode == 81` someone adds to the policy must not pass unseen.
    @Test("the numeric keypad keys are not aliases")
    func numericKeypadKeysAreNotAliases() {
        let keypadCodes = [
            69, // kVK_ANSI_KeypadPlus
            78, // kVK_ANSI_KeypadMinus
            81, // kVK_ANSI_KeypadEquals
        ]
        for keyCode in keypadCodes {
            #expect(
                Self.zoom(keyCode: keyCode, modifiers: .command) == nil,
                "keyCode \(keyCode) with ⌘ must not trigger the alias"
            )
            #expect(
                Self.zoom(keyCode: keyCode, modifiers: [.command, .shift])
                    == nil,
                "keyCode \(keyCode) with ⇧⌘ must not trigger the alias"
            )
            #expect(
                !FontZoomAliasPolicy.handles(keyCode: keyCode),
                "keyCode \(keyCode) must not claim to be handled"
            )
        }
    }

    /// `handles` is the cheap key filter that keeps the common keyDown path
    /// out of the keybinding registry; it may claim exactly the two key
    /// positions the policy reads.
    @Test("handles claims exactly the Equal and Minus key positions")
    func handlesClaimsExactlyTheTwoKeys() {
        #expect(FontZoomAliasPolicy.handles(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.equalSign
        ))
        #expect(FontZoomAliasPolicy.handles(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.minus
        ))
        #expect(!FontZoomAliasPolicy.handles(keyCode: 0))
        #expect(!FontZoomAliasPolicy.handles(keyCode: 30))
    }

    /// Locks the key positions to the Carbon HID constants: 24 is
    /// `kVK_ANSI_Equal` (the =/+ key, right of Minus, adjacent to
    /// Backspace), 27 is `kVK_ANSI_Minus`. ISO keyboards add their extra
    /// Section key elsewhere and leave both positions in place, so the
    /// match is layout-stable.
    @Test("the aliases bind the ANSI Equal and Minus key positions")
    func physicalKeyCodes() {
        #expect(KeyboardShortcutMatcher.PhysicalKey.equalSign == 24)
        #expect(KeyboardShortcutMatcher.PhysicalKey.minus == 27)
    }

    private static func registry(
        loading json: String
    ) async throws -> UserKeybindingRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-zoom-alias-\(UUID().uuidString)")
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
}
