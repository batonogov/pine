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
/// 1. **user overrides** — this router. A match *consumes* the event so
///    no later handler can also act on it.
/// 2. **built-in physical-key handling** — Cmd+W, terminal find, branch
///    switching, and tab navigation.
/// 3. **built-in menu equivalents** — SwiftUI `.keyboardShortcut` / `NSMenu`.
/// 4. **text and terminal input** — the responder chain.
///
/// AppDelegate installs exactly one key-down monitor and delegates both user
/// and built-in routing here. The precedence therefore does not depend on
/// AppKit's unspecified ordering between multiple local event monitors.
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

    /// Routes one event through user overrides and then Pine's physical-key
    /// handlers. Returning `nil` consumes the event; returning the original
    /// event lets NSMenu and the responder chain continue.
    static func route(
        _ event: NSEvent,
        registry: UserKeybindingRegistry,
        dispatchUserCommand: (UserCommand) -> Void,
        dispatchBuiltIn: (NSEvent) -> Bool
    ) -> NSEvent? {
        if let userCommand = command(for: event, in: registry) {
            dispatchUserCommand(userCommand)
            return nil
        }
        if dispatchBuiltIn(event) {
            return nil
        }
        return event
    }
}
