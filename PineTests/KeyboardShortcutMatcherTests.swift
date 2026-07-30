//
//  KeyboardShortcutMatcherTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for `KeyboardShortcutMatcher` — the layout-independent shortcut predicate.
///
/// These tests verify the pure predicate functions (no NSEvent construction needed)
/// so they document the expected behavior of every global shortcut regardless of
/// keyboard layout.
@Suite("KeyboardShortcutMatcher Tests")
struct KeyboardShortcutMatcherTests {

    // MARK: - Physical key code constants

    @Test("Physical key codes match Carbon HID constants")
    func physicalKeyCodes() {
        #expect(KeyboardShortcutMatcher.PhysicalKey.f == 3)   // kVK_ANSI_F
        #expect(KeyboardShortcutMatcher.PhysicalKey.w == 13)  // kVK_ANSI_W
        #expect(KeyboardShortcutMatcher.PhysicalKey.b == 11)  // kVK_ANSI_B
        #expect(KeyboardShortcutMatcher.PhysicalKey.tab == 48) // kVK_Tab
    }

    @Test("Digit key codes array has exactly 9 entries")
    func digitCodesCount() {
        #expect(KeyboardShortcutMatcher.PhysicalKey.digits.count == 9)
    }

    // MARK: - matches() — exact key + modifier

    @Test("Cmd+W matches on physical W key code with command")
    func cmdWMatches() {
        #expect(KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.w,
            modifiers: .command,
            eventKeyCode: 13,
            eventModifiers: .command
        ))
    }

    @Test("Cmd+W does not match wrong key code")
    func cmdWWrongKey() {
        #expect(!KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.w,
            modifiers: .command,
            eventKeyCode: 0, // 'A' key — not 'W'
            eventModifiers: .command
        ))
    }

    @Test("Cmd+W does not match without command modifier")
    func cmdWMissingModifier() {
        #expect(!KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.w,
            modifiers: .command,
            eventKeyCode: 13,
            eventModifiers: [] // no modifiers
        ))
    }

    @Test("Cmd+F matches on physical F key code")
    func cmdFMatches() {
        #expect(KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.f,
            modifiers: .command,
            eventKeyCode: 3,
            eventModifiers: .command
        ))
    }

    @Test("Cmd+Shift+B matches with both modifiers")
    func cmdShiftBMatches() {
        #expect(KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.b,
            modifiers: [.command, .shift],
            eventKeyCode: 11,
            eventModifiers: [.command, .shift]
        ))
    }

    @Test("Cmd+Shift+B does not match with only command")
    func cmdShiftBMissingShift() {
        #expect(!KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.b,
            modifiers: [.command, .shift],
            eventKeyCode: 11,
            eventModifiers: .command
        ))
    }

    @Test("Extra modifiers cause non-match (exact match required)")
    func extraModifiersFail() {
        #expect(!KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.f,
            modifiers: .command,
            eventKeyCode: 3,
            eventModifiers: [.command, .shift] // shift held — not exact match
        ))
    }

    // MARK: - digit() — decode 1-9 from key code

    @Test("Digit 1 decodes from key code 18")
    func digitOne() {
        #expect(KeyboardShortcutMatcher.digit(
            eventKeyCode: 18, eventModifiers: .command, modifiers: .command
        ) == 1)
    }

    @Test("Digit 5 decodes from key code 23 (non-contiguous)")
    func digitFive() {
        #expect(KeyboardShortcutMatcher.digit(
            eventKeyCode: 23, eventModifiers: .command, modifiers: .command
        ) == 5)
    }

    @Test("Digit 9 decodes from key code 25")
    func digitNine() {
        #expect(KeyboardShortcutMatcher.digit(
            eventKeyCode: 25, eventModifiers: .command, modifiers: .command
        ) == 9)
    }

    @Test("All digit key codes 1-9 decode correctly")
    func allDigitsDecode() {
        for (index, code) in KeyboardShortcutMatcher.PhysicalKey.digits.enumerated() {
            let result = KeyboardShortcutMatcher.digit(
                eventKeyCode: code, eventModifiers: .command, modifiers: .command
            )
            #expect(result == index + 1, "Expected digit \(index + 1) for keyCode \(code)")
        }
    }

    @Test("Non-digit key code returns nil")
    func nonDigitKeyReturnsNil() {
        #expect(KeyboardShortcutMatcher.digit(
            eventKeyCode: 13, // 'W' key — not a digit
            eventModifiers: .command, modifiers: .command
        ) == nil)
    }

    @Test("Digit with wrong modifiers returns nil")
    func digitWrongModifiers() {
        #expect(KeyboardShortcutMatcher.digit(
            eventKeyCode: 18,
            eventModifiers: .shift, // shift, not command
            modifiers: .command
        ) == nil)
    }

    // MARK: - normalizedModifiers

    @Test("normalizedModifiers strips incidental keyboard state")
    func normalizedStripsIncidentalFlags() {
        let incidental: NSEvent.ModifierFlags = [
            .capsLock,
            .numericPad,
            .function,
            .help,
        ]
        let normalized = KeyboardShortcutMatcher.normalizedModifiers(
            .command.union(incidental)
        )
        #expect(normalized == .command)
    }

    @Test("normalizedModifiers keeps every logical shortcut modifier")
    func normalizedKeepsLogicalModifiers() {
        let logical: NSEvent.ModifierFlags = [
            .command,
            .option,
            .control,
            .shift,
        ]
        #expect(
            KeyboardShortcutMatcher.normalizedModifiers(logical) == logical
        )
    }
}
