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

    /// Argument name a UI test uses to seed the terminal font size, e.g.
    /// `-uitestTerminalFontSize 16`.
    static let uiTestTerminalFontSizeArgument = "-uitestTerminalFontSize"

    /// Seeds `terminal.font.size` in the UI-test settings suite (#1649).
    ///
    /// XCUITest provably cannot drive this SwiftUI slider (four idioms failed
    /// on CI: `adjust(toNormalizedSliderPosition:)` misreads the raw
    /// point-size AXValue as normalized, synthesized track clicks don't move
    /// the knob, the min/max label buttons don't step under synthesized
    /// clicks, and arrow keys after a knob click don't step), so the
    /// persistence UI test seeds the value here and exercises the read +
    /// persistence paths instead. Gated on the same suite contract as
    /// `shared()` so a stray argument can never affect a normal launch.
    static func seedUITestTerminalFontSize(
        arguments: [String],
        environment: [String: String]
    ) {
        guard let suiteName = uiTestSuiteName(
            arguments: arguments,
            environment: environment
        ),
        let index = arguments.firstIndex(of: uiTestTerminalFontSizeArgument),
        arguments.indices.contains(index + 1),
        let requestedSize = Double(arguments[index + 1]),
        let defaults = UserDefaults(suiteName: suiteName) else {
            return
        }
        defaults.set(
            TerminalFontSettings.normalizedSize(requestedSize),
            forKey: TerminalFontSettings.Keys.fontSize
        )
    }
}
