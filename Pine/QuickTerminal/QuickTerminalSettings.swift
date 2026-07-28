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
//  `QuickTerminalController` share the injected change-notification channel
//  and re-apply the effective runtime state without recreating the session.
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
    /// The display that contains Pine's key window, falling back to AppKit's
    /// keyboard-focus screen and then the menu-bar display.
    case active
    /// The primary display containing the menu bar.
    case main

    var id: String { rawValue }
}

@MainActor
@Observable
final class QuickTerminalSettings {
    static let shared = QuickTerminalSettings(
        defaults: PineSettingsDefaults.shared()
    )

    // MARK: - UserDefaults keys

    private static let enabledKey = "quickTerminal.enabled"
    private static let keyCodeKey = "quickTerminal.hotkey.keyCode"
    private static let modifiersKey = "quickTerminal.hotkey.modifiers"
    private static let screenEdgeKey = "quickTerminal.screenEdge"
    private static let heightFractionKey = "quickTerminal.heightFraction"
    private static let targetDisplayKey = "quickTerminal.targetDisplay"
    private static let hideOnFocusLossKey = "quickTerminal.hideOnFocusLoss"
    private static let supportedHotkeyModifiers = UInt32(
        controlKey | optionKey | cmdKey | shiftKey
    )
    private static let primaryHotkeyModifiers = UInt32(
        controlKey | optionKey | cmdKey
    )
    /// Carbon virtual key codes published by HIToolbox's `Events.h` occupy
    /// the 0x00 ... 0x7E range. Reject larger persisted values before they
    /// reach `RegisterEventHotKey`, which otherwise fails without a useful
    /// recovery path.
    private static let maxCarbonVirtualKeyCode = UInt32(kVK_UpArrow)
    private static let defaultHeightFraction = 0.4

    private let defaults: UserDefaults
    /// Shared with runtime observers so isolated settings instances can drive
    /// the same immediate-apply path without posting into global process state.
    let notificationCenter: NotificationCenter
    private var notificationSuppressionDepth = 0
    private var hasPendingNotification = false

    // MARK: - Stored properties (immediate-apply via didSet)

    /// Master switch. When `false` the global hotkey is unregistered and the
    /// menu item is disabled.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            notifyChange()
        }
    }

    /// Carbon virtual-key code for the global hotkey (e.g. `kVK_Space` = 49).
    private(set) var keyCode: UInt32 {
        didSet {
            guard keyCode != oldValue else { return }
            defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
            notifyChange()
        }
    }

    /// Carbon modifier bit-field (`controlKey | optionKey` etc.).
    private(set) var modifiers: UInt32 {
        didSet {
            guard modifiers != oldValue else { return }
            defaults.set(Int(modifiers), forKey: Self.modifiersKey)
            notifyChange()
        }
    }

    /// Screen edge the panel drops down from.
    var screenEdge: QuickTerminalScreenEdge {
        didSet {
            guard screenEdge != oldValue else { return }
            defaults.set(screenEdge.rawValue, forKey: Self.screenEdgeKey)
            notifyChange()
        }
    }

    /// Fraction of the screen's usable dimension the panel occupies
    /// (0.2 … 0.8). For top/bottom edges this is the height fraction; for
    /// left/right edges it is the width fraction.
    var heightFraction: Double {
        didSet {
            // Clamp to a finite, sane range so AppKit never receives a frame
            // containing NaN or infinity from corrupt defaults or callers.
            let normalized = Self.normalizedHeightFraction(heightFraction)
            if heightFraction.isFinite == false
                || normalized != heightFraction {
                defaults.set(normalized, forKey: Self.heightFractionKey)
                heightFraction = normalized
                return
            }
            guard heightFraction != oldValue else { return }
            defaults.set(heightFraction, forKey: Self.heightFractionKey)
            notifyChange()
        }
    }

    /// Which display the panel appears on.
    var targetDisplay: QuickTerminalTargetDisplay {
        didSet {
            guard targetDisplay != oldValue else { return }
            defaults.set(targetDisplay.rawValue, forKey: Self.targetDisplayKey)
            notifyChange()
        }
    }

    /// When `true`, the panel hides itself if it loses keyboard focus
    /// (click-through to another app). Matches iTerm2's "hide on focus loss".
    var hideOnFocusLoss: Bool {
        didSet {
            guard hideOnFocusLoss != oldValue else { return }
            defaults.set(hideOnFocusLoss, forKey: Self.hideOnFocusLossKey)
            notifyChange()
        }
    }

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        // `object(forKey:)` distinguishes "never set" from "set to false".
        if defaults.object(forKey: Self.enabledKey) != nil {
            self.enabled = defaults.bool(forKey: Self.enabledKey)
        } else {
            // Enabled by default — the v1 shipped with the hotkey always on.
            self.enabled = true
        }

        let storedKeyCode = defaults.object(forKey: Self.keyCodeKey) as? Int
        let storedModifiers = defaults.object(forKey: Self.modifiersKey) as? Int
        let restoredHotkey = Self.validatedHotkey(
            keyCode: storedKeyCode.flatMap(UInt32.init(exactly:)),
            modifiers: storedModifiers.flatMap(UInt32.init(exactly:))
        )
        self.keyCode = restoredHotkey?.keyCode ?? Self.defaultKeyCode
        self.modifiers = restoredHotkey?.modifiers ?? Self.defaultModifiers
        if storedKeyCode != nil || storedModifiers != nil,
           restoredHotkey == nil {
            defaults.set(Int(Self.defaultKeyCode), forKey: Self.keyCodeKey)
            defaults.set(Int(Self.defaultModifiers), forKey: Self.modifiersKey)
        }

        if let raw = defaults.string(forKey: Self.screenEdgeKey),
           let edge = QuickTerminalScreenEdge(rawValue: raw) {
            self.screenEdge = edge
        } else {
            self.screenEdge = .top
        }

        if let stored = defaults.object(forKey: Self.heightFractionKey) as? Double {
            let normalized = Self.normalizedHeightFraction(stored)
            self.heightFraction = normalized
            if stored.isFinite == false || stored != normalized {
                defaults.set(normalized, forKey: Self.heightFractionKey)
            }
        } else {
            self.heightFraction = Self.defaultHeightFraction
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

    /// Updates both halves of the hotkey atomically from the runtime
    /// observer's point of view. Persistence still happens per field, while
    /// hotkey registration sees only the complete combination.
    @discardableResult
    func setHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard let hotkey = Self.validatedHotkey(
            keyCode: keyCode,
            modifiers: modifiers
        ) else {
            return false
        }
        // Persist the pair even when only one in-memory component changes.
        // Otherwise, changing just the key while keeping the default modifiers
        // leaves no modifier value on disk and the next launch rejects the
        // incomplete pair as corrupt.
        defaults.set(Int(hotkey.keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(hotkey.modifiers), forKey: Self.modifiersKey)
        performBatch {
            self.keyCode = hotkey.keyCode
            self.modifiers = hotkey.modifiers
        }
        return true
    }

    /// Resets every preference to its default value.
    func reset() {
        performBatch {
            enabled = true
            keyCode = Self.defaultKeyCode
            modifiers = Self.defaultModifiers
            screenEdge = .top
            heightFraction = Self.defaultHeightFraction
            targetDisplay = .active
            hideOnFocusLoss = true
        }
    }

    // MARK: - Change notification

    /// Posted on `NotificationCenter` whenever any preference changes.
    /// `GlobalHotkeyManager` and `QuickTerminalController` observe this to
    /// re-arm / re-position without polling.
    static let didChangeNotification = Notification.Name("QuickTerminalSettingsDidChange")

    private func notifyChange() {
        guard notificationSuppressionDepth == 0 else {
            hasPendingNotification = true
            return
        }
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private func performBatch(_ updates: () -> Void) {
        notificationSuppressionDepth += 1
        updates()
        notificationSuppressionDepth -= 1
        guard notificationSuppressionDepth == 0, hasPendingNotification else {
            return
        }
        hasPendingNotification = false
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private static func validatedHotkey(
        keyCode: UInt32?,
        modifiers: UInt32?
    ) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let keyCode,
              keyCode <= maxCarbonVirtualKeyCode,
              let modifiers else {
            return nil
        }
        let supportedModifiers = modifiers & supportedHotkeyModifiers
        guard supportedModifiers & primaryHotkeyModifiers != 0 else {
            return nil
        }
        return (keyCode, supportedModifiers)
    }

    private static func normalizedHeightFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHeightFraction }
        return min(max(value, 0.2), 0.8)
    }
}

/// Owns the production subscription that applies Quick Terminal preferences
/// to a runtime service such as the Carbon global-hotkey registrar.
///
/// Keeping subscription setup in one testable owner prevents the launch path
/// from silently dropping its opaque NotificationCenter token and guarantees
/// that atomic hotkey updates are observed as one complete settings snapshot.
@MainActor
final class QuickTerminalSettingsRuntimeBinding {
    private let settings: QuickTerminalSettings
    private let notificationCenter: NotificationCenter
    private let apply: @MainActor (QuickTerminalSettings) -> Void
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(
        settings: QuickTerminalSettings,
        apply: @escaping @MainActor (QuickTerminalSettings) -> Void
    ) {
        self.settings = settings
        self.notificationCenter = settings.notificationCenter
        self.apply = apply

        apply(settings)
        observer = notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentSettings()
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    private func applyCurrentSettings() {
        apply(settings)
    }
}
