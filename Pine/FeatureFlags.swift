//
//  FeatureFlags.swift
//  Pine
//
//  Runtime feature flags backed by UserDefaults for toggling experimental features.
//

import Foundation

/// Individual feature flag definition.
enum Feature: String, CaseIterable, Identifiable {
    case parallelSearch = "featureParallelSearch"
    case quickOpen = "featureQuickOpen"
    case minimap = "featureMinimap"
    case autoSave = "featureAutoSave"
    case syntaxHighlighting = "featureSyntaxHighlighting"

    var id: String { rawValue }

    /// Human-readable name for the settings UI.
    var displayName: String {
        switch self {
        case .parallelSearch: String(localized: "featureFlags.parallelSearch")
        case .quickOpen: String(localized: "featureFlags.quickOpen")
        case .minimap: String(localized: "featureFlags.minimap")
        case .autoSave: String(localized: "featureFlags.autoSave")
        case .syntaxHighlighting: String(localized: "featureFlags.syntaxHighlighting")
        }
    }

    /// Brief description of what this flag controls.
    var explanation: String {
        switch self {
        case .parallelSearch: String(localized: "featureFlags.parallelSearch.description")
        case .quickOpen: String(localized: "featureFlags.quickOpen.description")
        case .minimap: String(localized: "featureFlags.minimap.description")
        case .autoSave: String(localized: "featureFlags.autoSave.description")
        case .syntaxHighlighting: String(localized: "featureFlags.syntaxHighlighting.description")
        }
    }

    /// Default value when no UserDefaults entry exists. All features are enabled by default.
    var defaultValue: Bool { true }
}

/// Centralized runtime feature flag manager.
/// Read flags via `isEnabled(_:)`, toggle via `setEnabled(_:_:)`.
/// All flags default to `true` — toggle off if issues are found.
///
/// Also usable from the command line:
/// `defaults write com.batonogov.pine featureParallelSearch -bool NO`
@MainActor @Observable
final class FeatureFlags {
    static let shared = FeatureFlags()

    private let defaults: UserDefaults

    /// In-memory cache of flag values, synced with UserDefaults.
    private var cache: [Feature: Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Populate cache from defaults (or use default values).
        for feature in Feature.allCases {
            let key = feature.rawValue
            if defaults.object(forKey: key) != nil {
                cache[feature] = defaults.bool(forKey: key)
            } else {
                cache[feature] = feature.defaultValue
            }
        }
    }

    /// Check whether a feature is currently enabled.
    func isEnabled(_ feature: Feature) -> Bool {
        cache[feature] ?? feature.defaultValue
    }

    /// Enable or disable a feature at runtime. Persists to UserDefaults.
    func setEnabled(_ feature: Feature, _ enabled: Bool) {
        cache[feature] = enabled
        defaults.set(enabled, forKey: feature.rawValue)
    }

    /// Toggle a feature's state. Returns the new value.
    @discardableResult
    func toggle(_ feature: Feature) -> Bool {
        let newValue = !isEnabled(feature)
        setEnabled(feature, newValue)
        return newValue
    }

    /// Reset all flags to their default values.
    func resetAll() {
        for feature in Feature.allCases {
            cache[feature] = feature.defaultValue
            defaults.removeObject(forKey: feature.rawValue)
        }
    }

    /// Reset a single flag to its default value.
    func reset(_ feature: Feature) {
        cache[feature] = feature.defaultValue
        defaults.removeObject(forKey: feature.rawValue)
    }
}
