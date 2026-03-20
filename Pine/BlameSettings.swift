//
//  BlameSettings.swift
//  Pine
//

import Foundation

/// Manages blame gutter visibility persistence in UserDefaults.
enum BlameSettings {
    private static let key = "blameVisible"

    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setVisible(_ visible: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: key)
    }

    static func toggle(in defaults: UserDefaults = .standard) {
        setVisible(!isVisible(in: defaults), in: defaults)
    }
}
