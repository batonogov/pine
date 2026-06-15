//
//  KeyboardShortcutMatcher.swift
//  Pine
//

import AppKit

/// Layout-independent keyboard shortcut matching.
///
/// Compares physical key codes (Carbon HID) instead of `charactersIgnoringModifiers`,
/// which returns locale-specific characters and breaks shortcuts on non-US keyboard
/// layouts. For example, Cmd+W fails on a Russian layout because the same physical
/// key produces "ц", not "w" — so a character comparison never matches and the event
/// falls through to the system "Close Window" action.
///
/// Physical key codes identify a key by its position on the keyboard, not by the
/// glyph it produces, so they are stable across every layout.
enum KeyboardShortcutMatcher {
    /// Physical key codes (Carbon HID / `kVK_ANSI_*` constants).
    ///
    /// These are not contiguous — digit row codes jump around — so they are listed
    /// explicitly rather than computed arithmetically.
    enum PhysicalKey {
        static let f = 3       // kVK_ANSI_F
        static let w = 13      // kVK_ANSI_W
        static let b = 11      // kVK_ANSI_B
        static let tab = 48    // kVK_Tab
        /// Digit keys 1-9, indexed by position (index 0 → key "1", index 8 → key "9").
        static let digits: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// Strips device-specific noise (caps-lock LED, function-key state, etc.) from
    /// raw modifier flags, leaving only the meaningful logical modifiers.
    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
    }

    /// Returns true when the physical key code and modifier flags both match exactly.
    ///
    /// Pure function — accepts raw integers/flags so it can be unit-tested without
    /// constructing `NSEvent` objects (which is fragile outside a real event loop).
    static func matches(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        eventKeyCode: Int,
        eventModifiers: NSEvent.ModifierFlags
    ) -> Bool {
        eventKeyCode == keyCode && eventModifiers == modifiers
    }

    /// Convenience overload matching against a real `NSEvent`, normalizing its
    /// modifier flags first.
    static func matches(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        in event: NSEvent
    ) -> Bool {
        matches(
            keyCode: keyCode,
            modifiers: modifiers,
            eventKeyCode: Int(event.keyCode),
            eventModifiers: normalizedModifiers(event.modifierFlags)
        )
    }

    /// Returns the digit 1-9 when the key code is a digit-row key and the modifiers
    /// match exactly; otherwise nil.
    ///
    /// Pure function — accepts raw values for unit testing.
    static func digit(
        eventKeyCode: Int,
        eventModifiers: NSEvent.ModifierFlags,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        guard eventModifiers == modifiers else { return nil }
        return PhysicalKey.digits.firstIndex(of: eventKeyCode).map { $0 + 1 }
    }

    /// Convenience overload decoding a digit from a real `NSEvent`.
    static func digit(from event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Int? {
        digit(
            eventKeyCode: Int(event.keyCode),
            eventModifiers: normalizedModifiers(event.modifierFlags),
            modifiers: modifiers
        )
    }
}
