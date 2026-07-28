//
//  PineSettingsDefaults.swift
//  Pine
//
//  Selects an isolated preferences suite for UI tests that mutate Settings.
//

import Foundation

nonisolated enum PineSettingsDefaults {
    static let uiTestSuiteEnvironmentKey = "PINE_UI_TEST_SETTINGS_SUITE"

    /// Production always uses the application domain. UI tests may opt into a
    /// unique suite, but only together with the existing reset-state launch
    /// contract and a namespaced value, so an ambient environment variable
    /// cannot silently redirect a normal Pine launch.
    static func shared() -> UserDefaults {
        guard let suiteName = uiTestSuiteName(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        ),
        let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return defaults
    }

    static func uiTestSuiteName(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        guard arguments.contains("--reset-state"),
              let suiteName = environment[uiTestSuiteEnvironmentKey],
              suiteName.hasPrefix("PineUITests.Settings."),
              suiteName.count > "PineUITests.Settings.".count else {
            return nil
        }
        return suiteName
    }

    static func cleanUpUITestSuite() {
        guard let suiteName = uiTestSuiteName(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        ),
        let defaults = UserDefaults(suiteName: suiteName) else {
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
    }
}
