//
//  WordWrapSettingsTests.swift
//  PineTests
//
//  Created by Claude on 24.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("WordWrapSettings Tests")
struct WordWrapSettingsTests {

    // MARK: - Default value

    @Test("Word wrap defaults to true (enabled)")
    func defaultValue() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        let enabled = WordWrapSettings.isEnabled(in: defaults)
        #expect(enabled == true)
    }

    // MARK: - Persistence

    @Test("Word wrap persists false to UserDefaults")
    func persistFalse() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        WordWrapSettings.setEnabled(false, in: defaults)
        #expect(WordWrapSettings.isEnabled(in: defaults) == false)
    }

    @Test("Word wrap persists true to UserDefaults")
    func persistTrue() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        WordWrapSettings.setEnabled(false, in: defaults)
        WordWrapSettings.setEnabled(true, in: defaults)
        #expect(WordWrapSettings.isEnabled(in: defaults) == true)
    }

    // MARK: - Toggle

    @Test("Toggle flips word wrap from true to false")
    func toggleFromTrue() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        // Default is true
        WordWrapSettings.toggle(in: defaults)
        #expect(WordWrapSettings.isEnabled(in: defaults) == false)
    }

    @Test("Toggle flips word wrap from false to true")
    func toggleFromFalse() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        WordWrapSettings.setEnabled(false, in: defaults)
        WordWrapSettings.toggle(in: defaults)
        #expect(WordWrapSettings.isEnabled(in: defaults) == true)
    }

    @Test("Double toggle returns to original state")
    func doubleToggle() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        let original = WordWrapSettings.isEnabled(in: defaults)
        WordWrapSettings.toggle(in: defaults)
        WordWrapSettings.toggle(in: defaults)
        #expect(WordWrapSettings.isEnabled(in: defaults) == original)
    }

    // MARK: - Isolation between UserDefaults suites

    @Test("Different UserDefaults suites are independent")
    func isolatedDefaults() {
        guard let defaults1 = UserDefaults(suiteName: UUID().uuidString),
              let defaults2 = UserDefaults(suiteName: UUID().uuidString) else { return }
        WordWrapSettings.setEnabled(false, in: defaults1)
        #expect(WordWrapSettings.isEnabled(in: defaults1) == false)
        #expect(WordWrapSettings.isEnabled(in: defaults2) == true)
    }

    // MARK: - Storage key

    @Test("Uses expected UserDefaults key")
    func storageKey() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        // Before any write, the key should not exist
        #expect(defaults.object(forKey: "wordWrapEnabled") == nil)
        WordWrapSettings.setEnabled(false, in: defaults)
        #expect(defaults.object(forKey: "wordWrapEnabled") != nil)
    }
}
