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
nonisolated enum KeyboardShortcutMatcher {
    /// Physical key codes (Carbon HID / `kVK_ANSI_*` constants).
    ///
    /// These are not contiguous — digit row codes jump around — so they are listed
    /// explicitly rather than computed arithmetically.
    enum PhysicalKey {
        static let f = 3       // kVK_ANSI_F
        static let w = 13      // kVK_ANSI_W
        static let b = 11      // kVK_ANSI_B
        static let tab = 48    // kVK_Tab
        static let equalSign = 24 // kVK_ANSI_Equal (the =/+ key)
        static let minus = 27  // kVK_ANSI_Minus (the -/_ key)
        /// Digit keys 1-9, indexed by position (index 0 → key "1", index 8 → key "9").
        static let digits: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// Strips device-specific noise (caps-lock LED, function-key state, etc.) from
    /// raw modifier flags, leaving only the meaningful logical modifiers.
    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift])
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

/// The font-zoom aliases that answer beside the menu's own chords (#1564).
///
/// The Zoom In item advertises ⌘+, which on a US layout means the user must
/// press ⇧⌘=. Apple apps answer to ⌘= as well, but Pine cannot express that
/// as a second menu item: SwiftUI `Commands` has no hidden items, and the
/// chord grammar cannot spell `cmd++` because "+" is its separator. So the
/// aliases ride the physical-key router next to Cmd+W and terminal find,
/// matching the exact key position — the same layout-independence the
/// system's own shortcuts use (ISO keyboards add their extra Section key
/// elsewhere and leave the Equal/Minus positions in place).
nonisolated enum FontZoomAliasPolicy {
    /// The zoom a matched key event should perform.
    enum Zoom: Equatable {
        case increase
        case decrease
    }

    /// Resolves the zoom alias for a physical key event, or `nil` when the
    /// event belongs to the menu's own chords, another handler, or text
    /// input.
    ///
    /// - ⌘ on the physical Equal key zooms in — ⌘= beside the menu's ⌘+.
    /// - ⇧⌘ on the physical Minus key zooms out — ⌘_ beside the menu's ⌘-,
    ///   the pair Apple apps accept for Zoom Out.
    /// - ⇧⌘ on Equal stays with the menu: it is how ⌘+ is *typed* on a US
    ///   layout, and an alias that claimed it would invert Zoom In.
    /// - A user rebind of the corresponding command retires its alias — the
    ///   replacement rule `effectiveChord` already applies to the menu
    ///   chord (#1539).
    static func zoom(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        increaseFontSizeRebound: Bool,
        decreaseFontSizeRebound: Bool
    ) -> Zoom? {
        if keyCode == KeyboardShortcutMatcher.PhysicalKey.equalSign,
           modifiers == .command,
           !increaseFontSizeRebound {
            return .increase
        }
        if keyCode == KeyboardShortcutMatcher.PhysicalKey.minus,
           modifiers == [.command, .shift],
           !decreaseFontSizeRebound {
            return .decrease
        }
        return nil
    }

    /// Whether `keyCode` is one this policy looks at. Callers guard on this
    /// before computing the override flags, so the common keyDown path —
    /// every key that is neither Equal nor Minus — never touches the
    /// keybinding registry.
    static func handles(keyCode: Int) -> Bool {
        [
            KeyboardShortcutMatcher.PhysicalKey.equalSign,
            KeyboardShortcutMatcher.PhysicalKey.minus,
        ].contains(keyCode)
    }
}
