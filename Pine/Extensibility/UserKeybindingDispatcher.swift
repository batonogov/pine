//
//  UserKeybindingDispatcher.swift
//  Pine
//
//  Issue #1117: makes the user-keybinding precedence rule explicit and
//  testable. The AppDelegate keyDown monitor delegates to this type so the
//  "one event, one handler" invariant has a single, unit-tested owner.
//

import AppKit
import Foundation

/// Resolves whether a key event is claimed by a user keybinding override.
///
/// Precedence (highest first), evaluated for each `keyDown` event:
/// 1. **user overrides** — this dispatcher. A match *consumes* the event so
///    no later handler can also act on it.
/// 2. **built-in menu equivalents** — SwiftUI `.keyboardShortcut` / `NSMenu`
///    key equivalents.
/// 3. **text input** — the responder chain.
/// 4. **terminal input** — the focused terminal.
///
/// Because a user match returns the event to the monitor as `nil`
/// (consumed), a built-in shortcut for the *same chord* never also fires —
/// there is no double-dispatch. When no user override matches, the event
/// falls through unchanged to built-in shortcuts, text input, and terminal
/// input in their usual order.
@MainActor
enum UserKeybindingDispatcher {
    /// Returns the user command to dispatch for `event`, or `nil` when the
    /// event should fall through to built-in shortcuts / text / terminal.
    ///
    /// `nil` means "not claimed by a user override"; the caller must let the
    /// event propagate. A non-`nil` result means "claimed": the caller posts
    /// the command's notification and consumes the event.
    static func command(
        for event: NSEvent,
        in registry: UserKeybindingRegistry
    ) -> UserCommand? {
        // An empty registry cannot claim any event, so built-in shortcuts and
        // text input keep working untouched — the common case at first launch.
        guard !registry.isEmpty else { return nil }
        return registry.command(for: event)
    }
}
