//
//  AgentHandoffSettings.swift
//  Pine
//
//  Explicit opt-in for Pine's read-only editor-context handoff (#933).
//

import Foundation

/// User-controlled permission for exposing bounded editor context to child
/// processes launched in Pine terminals.
///
/// The permission is deliberately off by default. Enabling it only exposes the
/// path of a read-only JSON snapshot to *new* terminal processes; it grants no
/// editor mutation, command execution, navigation, or undo authority.
@MainActor
@Observable
final class AgentHandoffSettings {
    static let shared = AgentHandoffSettings()

    enum Keys {
        static let readOnlyContextEnabled = "agentHandoff.readOnlyContextEnabled"
    }

    private let defaults: UserDefaults

    private(set) var isReadOnlyContextEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isReadOnlyContextEnabled = (
            defaults.object(forKey: Keys.readOnlyContextEnabled) as? Bool
        ) ?? false
    }

    func setReadOnlyContextEnabled(_ isEnabled: Bool) {
        guard isReadOnlyContextEnabled != isEnabled else { return }
        isReadOnlyContextEnabled = isEnabled
        defaults.set(isEnabled, forKey: Keys.readOnlyContextEnabled)
        NotificationCenter.default.post(
            name: .agentHandoffSettingsChanged,
            object: self
        )
    }
}
