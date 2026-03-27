//
//  FeatureFlagsTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("FeatureFlags Tests")
@MainActor
struct FeatureFlagsTests {

    private let suiteName = "PineTests.FeatureFlags.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default values

    @Test func allFeaturesEnabledByDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        for feature in Feature.allCases {
            #expect(flags.isEnabled(feature), "Feature \(feature.rawValue) should be enabled by default")
        }
    }

    @Test func defaultValuePropertyIsTrue() {
        for feature in Feature.allCases {
            #expect(feature.defaultValue == true)
        }
    }

    // MARK: - Enable / Disable

    @Test func disableFeature() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.parallelSearch, false)
        #expect(flags.isEnabled(.parallelSearch) == false)
    }

    @Test func enableFeatureAfterDisable() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.minimap, false)
        #expect(flags.isEnabled(.minimap) == false)

        flags.setEnabled(.minimap, true)
        #expect(flags.isEnabled(.minimap) == true)
    }

    @Test func toggleFeature() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        #expect(flags.isEnabled(.quickOpen) == true)

        let newValue = flags.toggle(.quickOpen)
        #expect(newValue == false)
        #expect(flags.isEnabled(.quickOpen) == false)

        let restored = flags.toggle(.quickOpen)
        #expect(restored == true)
        #expect(flags.isEnabled(.quickOpen) == true)
    }

    @Test func disablingOneDoesNotAffectOthers() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.autoSave, false)

        for feature in Feature.allCases where feature != .autoSave {
            #expect(flags.isEnabled(feature) == true,
                    "Feature \(feature.rawValue) should still be enabled")
        }
    }

    // MARK: - Persistence

    @Test func flagPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.syntaxHighlighting, false)

        #expect(defaults.bool(forKey: Feature.syntaxHighlighting.rawValue) == false)
    }

    @Test func flagLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(false, forKey: Feature.parallelSearch.rawValue)

        let flags = FeatureFlags(defaults: defaults)
        #expect(flags.isEnabled(.parallelSearch) == false)
    }

    @Test func persistenceAcrossInstances() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags1 = FeatureFlags(defaults: defaults)
        flags1.setEnabled(.minimap, false)
        flags1.setEnabled(.autoSave, false)

        let flags2 = FeatureFlags(defaults: defaults)
        #expect(flags2.isEnabled(.minimap) == false)
        #expect(flags2.isEnabled(.autoSave) == false)
        #expect(flags2.isEnabled(.quickOpen) == true)
    }

    // MARK: - Reset

    @Test func resetAllRestoresDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        for feature in Feature.allCases {
            flags.setEnabled(feature, false)
        }
        for feature in Feature.allCases {
            #expect(flags.isEnabled(feature) == false)
        }

        flags.resetAll()

        for feature in Feature.allCases {
            #expect(flags.isEnabled(feature) == true,
                    "Feature \(feature.rawValue) should be restored to default")
        }
    }

    @Test func resetAllClearsUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.parallelSearch, false)
        flags.resetAll()

        #expect(defaults.object(forKey: Feature.parallelSearch.rawValue) == nil)
    }

    @Test func resetSingleFeature() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.quickOpen, false)
        flags.setEnabled(.minimap, false)

        flags.reset(.quickOpen)

        #expect(flags.isEnabled(.quickOpen) == true)
        #expect(flags.isEnabled(.minimap) == false, "Other features should not be affected")
    }

    @Test func resetSingleClearsUserDefaultsKey() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.autoSave, false)
        flags.reset(.autoSave)

        #expect(defaults.object(forKey: Feature.autoSave.rawValue) == nil)
    }

    // MARK: - Feature enum

    @Test func allCasesHaveDisplayName() {
        for feature in Feature.allCases {
            #expect(!feature.displayName.isEmpty)
        }
    }

    @Test func allCasesHaveExplanation() {
        for feature in Feature.allCases {
            #expect(!feature.explanation.isEmpty)
        }
    }

    @Test func featureIdsAreUnique() {
        let ids = Feature.allCases.map(\.id)
        #expect(Set(ids).count == ids.count, "Feature IDs must be unique")
    }

    @Test func featureRawValuesAreUserDefaultsKeys() {
        // Verify convention: rawValue is used as UserDefaults key
        for feature in Feature.allCases {
            #expect(feature.rawValue.hasPrefix("feature"))
        }
    }

    // MARK: - Command-line usage

    @Test func commandLineDefaultsWriteSimulation() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Simulate: defaults write com.batonogov.pine featureParallelSearch -bool NO
        defaults.set(false, forKey: "featureParallelSearch")

        let flags = FeatureFlags(defaults: defaults)
        #expect(flags.isEnabled(.parallelSearch) == false)
    }

    // MARK: - Auto-save integration

    @Test func autoSaveRespectsFeatureFlag() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        let manager = TabManager()
        manager.featureFlags = flags

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatureFlagsTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)

        // Enable auto-save in UserDefaults
        UserDefaults.standard.set(true, forKey: TabManager.autoSaveKey)
        defer { UserDefaults.standard.removeObject(forKey: TabManager.autoSaveKey) }

        manager.openTab(url: url)
        manager.setAutoSaveDelay(0.05)

        // Disable auto-save feature flag
        flags.setEnabled(.autoSave, false)

        // Update content — should NOT schedule auto-save
        manager.updateContent("modified")
        #expect(manager.hasScheduledAutoSave == false,
                "Auto-save should not be scheduled when feature flag is disabled")
    }

    @Test func autoSaveWorksWhenFeatureFlagEnabled() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        let manager = TabManager()
        manager.featureFlags = flags

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatureFlagsTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)

        // Enable auto-save in UserDefaults
        UserDefaults.standard.set(true, forKey: TabManager.autoSaveKey)
        defer { UserDefaults.standard.removeObject(forKey: TabManager.autoSaveKey) }

        manager.openTab(url: url)
        manager.setAutoSaveDelay(0.05)

        // Enable auto-save feature flag (default)
        flags.setEnabled(.autoSave, true)

        // Update content — SHOULD schedule auto-save
        manager.updateContent("modified")
        #expect(manager.hasScheduledAutoSave == true,
                "Auto-save should be scheduled when feature flag is enabled")
        manager.cancelAutoSave()
    }

    // MARK: - Feature flag integration properties

    @Test func minimapFeatureFlagDefaultEnabled() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        #expect(flags.isEnabled(.minimap) == true)
    }

    @Test func syntaxHighlightingFeatureFlagDefaultEnabled() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        #expect(flags.isEnabled(.syntaxHighlighting) == true)
    }

    @Test func disablingMinimapDoesNotAffectSyntaxHighlighting() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let flags = FeatureFlags(defaults: defaults)
        flags.setEnabled(.minimap, false)
        #expect(flags.isEnabled(.syntaxHighlighting) == true)
    }
}
