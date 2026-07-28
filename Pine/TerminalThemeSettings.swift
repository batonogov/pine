//
//  TerminalThemeSettings.swift
//  Pine
//
//  User-facing terminal theme and appearance preferences (#1244).
//
//  Replaces the previous fixed One Dark / Catppuccin Latte switch with a
//  selectable theme model. The selected theme's active variant (light or
//  dark) is resolved against the user's Appearance policy and the system's
//  effective appearance, then applied to every live terminal session.
//
//  The settings are persisted in UserDefaults and broadcast via
//  `Notification.Name.terminalThemeChanged` so existing project terminals and
//  the Quick Terminal re-apply colors without restarting their shells or
//  losing scrollback.
//

import Foundation

/// How the terminal theme responds to the system appearance.
enum TerminalAppearancePolicy: String, CaseIterable, Sendable {
    /// Follow the system's effective appearance (default).
    case followSystem
    /// Always use the theme's light variant.
    case alwaysLight
    /// Always use the theme's dark variant.
    case alwaysDark

    /// Localization key for the human-readable policy name.
    var nameKey: String {
        switch self {
        case .followSystem:
            return "terminal.appearance.followSystem"
        case .alwaysLight:
            return "terminal.appearance.alwaysLight"
        case .alwaysDark:
            return "terminal.appearance.alwaysDark"
        }
    }
}

/// Centralised terminal theme and appearance preferences.
///
/// `selectedThemeID` stores the stable identifier of the chosen
/// `TerminalTheme`; `appearancePolicy` controls which variant (light/dark) is
/// active. Both are persisted in `UserDefaults` and applied immediately —
/// `didSet` posts `Notification.Name.terminalThemeChanged` so live terminal
/// sessions repaint without restarting their shells.
///
/// `currentScheme(isDarkAppearance:)` resolves the active color scheme by
/// combining the policy with the passed-in effective-appearance flag. Callers
/// pass the system flag so the model stays free of AppKit dependencies (and
/// unit-testable).
@MainActor
@Observable
final class TerminalThemeSettings {
    static let shared = TerminalThemeSettings(
        defaults: PineSettingsDefaults.shared()
    )

    enum Keys {
        static let themeID = "terminal.theme.id"
        static let appearancePolicy = "terminal.appearance.policy"
    }

    private let defaults: UserDefaults

    /// Delivery channel used by both the settings model and its terminal-tab
    /// observers. Keeping the injected center visible inside the module makes
    /// isolated tests exercise the same live-repaint path as production.
    let notificationCenter: NotificationCenter

    /// Stable identifier of the selected built-in theme.
    private(set) var selectedThemeID: String {
        didSet {
            guard selectedThemeID != oldValue else { return }
            defaults.set(selectedThemeID, forKey: Keys.themeID)
            notifyChanged()
        }
    }

    /// How the theme variant is chosen.
    var appearancePolicy: TerminalAppearancePolicy {
        didSet {
            guard appearancePolicy != oldValue else { return }
            defaults.set(appearancePolicy.rawValue, forKey: Keys.appearancePolicy)
            notifyChanged()
        }
    }

    /// The resolved `TerminalTheme` for `selectedThemeID`. Falls back to the
    /// default ("pine") theme if the stored id is unknown.
    var selectedTheme: TerminalTheme {
        TerminalTheme.theme(forID: selectedThemeID)
    }

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let storedID = defaults.string(forKey: Keys.themeID)
        if let storedID,
           TerminalTheme.builtIn.contains(where: { $0.id == storedID }) {
            self.selectedThemeID = storedID
        } else {
            self.selectedThemeID = TerminalTheme.defaultID
            if storedID?.isEmpty == false {
                defaults.set(TerminalTheme.defaultID, forKey: Keys.themeID)
            }
        }

        if let storedPolicy = defaults.string(forKey: Keys.appearancePolicy),
           let policy = TerminalAppearancePolicy(rawValue: storedPolicy) {
            self.appearancePolicy = policy
        } else {
            self.appearancePolicy = .followSystem
        }
    }

    // MARK: - Resolution

    /// Returns the active color scheme for the selected theme, taking the
    /// appearance policy into account.
    ///
    /// - Parameter isDarkAppearance: Whether the system's effective appearance
    ///   is currently dark. Ignored when the policy is not `followSystem`.
    /// - Returns: The resolved `TerminalColorScheme` to apply.
    func currentScheme(isDarkAppearance: Bool) -> TerminalColorScheme {
        let theme = selectedTheme
        switch appearancePolicy {
        case .followSystem:
            return theme.scheme(forDarkAppearance: isDarkAppearance)
        case .alwaysLight:
            return theme.light
        case .alwaysDark:
            return theme.dark
        }
    }

    /// Convenience overload that queries the live system appearance directly.
    /// Use only from the main thread / MainActor context where `NSApp` is valid.
    func currentScheme() -> TerminalColorScheme {
        currentScheme(isDarkAppearance: TerminalPalette.isDarkMode)
    }

    /// Whether the terminal should currently present its dark variant, given
    /// the policy and the passed-in system flag. Used by tests and by the
    /// preview to decide which variant label to show.
    func isDarkActive(isDarkAppearance: Bool) -> Bool {
        switch appearancePolicy {
        case .followSystem:
            return isDarkAppearance
        case .alwaysLight:
            return false
        case .alwaysDark:
            return true
        }
    }

    /// Selects a theme by id and broadcasts the change. Unknown identifiers
    /// normalize to the built-in default so the picker always has one selected
    /// row, including after a theme is removed in a later Pine version.
    func setTheme(id: String) {
        selectedThemeID = TerminalTheme.theme(forID: id).id
    }

    /// Resets both theme and appearance policy to their defaults.
    func reset() {
        selectedThemeID = TerminalTheme.defaultID
        appearancePolicy = .followSystem
    }

    // MARK: - Broadcasting

    /// Posts the change notification so live terminal sessions repaint.
    private func notifyChanged() {
        notificationCenter.post(name: .terminalThemeChanged, object: self)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted after the selected terminal theme or appearance policy changes.
    /// Observed by `TerminalTab` (project terminals) and the Quick Terminal
    /// so they re-apply colors without restarting their shells or losing
    /// scrollback (#1244).
    static let terminalThemeChanged = Notification.Name("terminalThemeChanged")
}
