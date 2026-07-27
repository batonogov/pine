//
//  QuickTerminalSettings.swift
//  Pine
//
//  User-facing preferences for the drop-down Quick Terminal (#1243).
//  Backed by `UserDefaults` with immediate-apply semantics so the global
//  hotkey, geometry, and display selection update as soon as a control
//  changes — no Apply/Reset step required.
//
//  Observable so SwiftUI bindings redraw live; `GlobalHotkeyManager` and
//  `QuickTerminalController` observe via `withObservationTracking` or
//  direct property reads at the point they re-arm.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Which screen edge the drop-down panel anchors to.
enum QuickTerminalScreenEdge: String, CaseIterable, Identifiable {
    case top
    case bottom
    case left
    case right

    var id: String { rawValue }
}

/// Which display the panel appears on.
enum QuickTerminalTargetDisplay: String, CaseIterable, Identifiable {
    /// The display that contains the current key window (falls back to the
    /// main display when Pine has no key window).
    case active
    /// Always the main display (menu bar).
    case main

    var id: String { rawValue }
}

@MainActor
@Observable
final class QuickTerminalSettings {
    static let shared = QuickTerminalSettings()

    // MARK: - UserDefaults keys

    private static let enabledKey = "quickTerminal.enabled"
    private static let keyCodeKey = "quickTerminal.hotkey.keyCode"
    private static let modifiersKey = "quickTerminal.hotkey.modifiers"
    private static let screenEdgeKey = "quickTerminal.screenEdge"
    private static let heightFractionKey = "quickTerminal.heightFraction"
    private static let targetDisplayKey = "quickTerminal.targetDisplay"
    private static let hideOnFocusLossKey = "quickTerminal.hideOnFocusLoss"

    private let defaults: UserDefaults

    // MARK: - Stored properties (immediate-apply via didSet)

    /// Master switch. When `false` the global hotkey is unregistered and the
    /// menu item is disabled.
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            notifyChange()
        }
    }

    /// Carbon virtual-key code for the global hotkey (e.g. `kVK_Space` = 49).
    var keyCode: UInt32 {
        didSet {
            defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
            notifyChange()
        }
    }

    /// Carbon modifier bit-field (`controlKey | optionKey` etc.).
    var modifiers: UInt32 {
        didSet {
            defaults.set(Int(modifiers), forKey: Self.modifiersKey)
            notifyChange()
        }
    }

    /// Screen edge the panel drops down from.
    var screenEdge: QuickTerminalScreenEdge {
        didSet {
            defaults.set(screenEdge.rawValue, forKey: Self.screenEdgeKey)
            notifyChange()
        }
    }

    /// Fraction of the screen's usable dimension the panel occupies
    /// (0.2 … 0.8). For top/bottom edges this is the height fraction; for
    /// left/right edges it is the width fraction.
    var heightFraction: Double {
        didSet {
            // Clamp to a sane range so the panel is always usable.
            let clamped = min(max(heightFraction, 0.2), 0.8)
            if clamped != heightFraction {
                heightFraction = clamped
                return
            }
            defaults.set(heightFraction, forKey: Self.heightFractionKey)
            notifyChange()
        }
    }

    /// Which display the panel appears on.
    var targetDisplay: QuickTerminalTargetDisplay {
        didSet {
            defaults.set(targetDisplay.rawValue, forKey: Self.targetDisplayKey)
            notifyChange()
        }
    }

    /// When `true`, the panel hides itself if it loses keyboard focus
    /// (click-through to another app). Matches iTerm2's "hide on focus loss".
    var hideOnFocusLoss: Bool {
        didSet {
            defaults.set(hideOnFocusLoss, forKey: Self.hideOnFocusLossKey)
            notifyChange()
        }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // `object(forKey:)` distinguishes "never set" from "set to false".
        if defaults.object(forKey: Self.enabledKey) != nil {
            self.enabled = defaults.bool(forKey: Self.enabledKey)
        } else {
            // Enabled by default — the v1 shipped with the hotkey always on.
            self.enabled = true
        }

        let storedKeyCode = defaults.object(forKey: Self.keyCodeKey) as? Int
        self.keyCode = UInt32(storedKeyCode ?? Int(Self.defaultKeyCode))

        let storedMods = defaults.object(forKey: Self.modifiersKey) as? Int
        self.modifiers = UInt32(storedMods ?? Int(Self.defaultModifiers))

        if let raw = defaults.string(forKey: Self.screenEdgeKey),
           let edge = QuickTerminalScreenEdge(rawValue: raw) {
            self.screenEdge = edge
        } else {
            self.screenEdge = .top
        }

        if let stored = defaults.object(forKey: Self.heightFractionKey) as? Double {
            self.heightFraction = min(max(stored, 0.2), 0.8)
        } else {
            self.heightFraction = 0.4
        }

        if let raw = defaults.string(forKey: Self.targetDisplayKey),
           let display = QuickTerminalTargetDisplay(rawValue: raw) {
            self.targetDisplay = display
        } else {
            self.targetDisplay = .active
        }

        self.hideOnFocusLoss = defaults.object(forKey: Self.hideOnFocusLossKey) != nil
            ? defaults.bool(forKey: Self.hideOnFocusLossKey)
            : true
    }

    // MARK: - Defaults

    /// Default hotkey: ⌃⌥Space (the v1 shortcut).
    static var defaultKeyCode: UInt32 { UInt32(kVK_Space) }
    static var defaultModifiers: UInt32 { UInt32(controlKey | optionKey) }

    /// Human-readable label for the current hotkey, e.g. "⌃⌥Space".
    /// Used by the menu item and the settings row.
    var hotkeyLabel: String {
        HotkeyFormatter.label(keyCode: keyCode, modifiers: modifiers)
    }

    /// Resets every preference to its default value.
    func reset() {
        enabled = true
        keyCode = Self.defaultKeyCode
        modifiers = Self.defaultModifiers
        screenEdge = .top
        heightFraction = 0.4
        targetDisplay = .active
        hideOnFocusLoss = true
    }

    // MARK: - Change notification

    /// Posted on `NotificationCenter` whenever any preference changes.
    /// `GlobalHotkeyManager` and `QuickTerminalController` observe this to
    /// re-arm / re-position without polling.
    static let didChangeNotification = Notification.Name("QuickTerminalSettingsDidChange")

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
