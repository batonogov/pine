//
//  TerminalFontAccessibilityTests.swift
//  PineTests
//
//  Issue #1649: the Terminal font section must publish its controls in the
//  real accessibility tree. The Settings UI sweep and the font persistence
//  UI test query exactly these attributes; SwiftUI's menu-style `Picker`
//  drops its label from the tree unless `.accessibilityLabel` is set
//  explicitly (the pattern the cursor picker already uses), and its slider
//  drops custom accessibility values, exposing the raw point size.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Terminal font settings accessibility")
@MainActor
struct TerminalFontAccessibilityTests {
    @Test("Font controls publish labels, values, and identifiers")
    func fontControlsPublishAccessibilityAttributes() throws {
        let fixture = try HostedTerminalSettings()
        defer { fixture.tearDown() }
        let elements = AccessibilityTreeProbe.elements(under: fixture.hosted.root)

        let picker = try #require(
            AccessibilityTreeProbe.element(
                under: fixture.hosted.root,
                identifier: "terminalFontFamilyPicker"
            )
        )
        #expect(AccessibilityTreeProbe.role(of: picker) == .popUpButton)
        // The Settings pane sweep matches `label == "Font family"`.
        #expect(
            AccessibilityTreeProbe.label(of: picker) == "Font family"
        )
        #expect(
            AccessibilityTreeProbe.attribute("accessibilityValue", of: picker)
                as? String == "Automatic"
        )

        let slider = try #require(
            AccessibilityTreeProbe.element(
                under: fixture.hosted.root,
                identifier: "terminalFontSizeSlider"
            )
        )
        #expect(AccessibilityTreeProbe.role(of: slider) == .slider)
        #expect(AccessibilityTreeProbe.label(of: slider) == "Size")
        // SwiftUI drops custom accessibility values on sliders: the raw
        // point size is what XCUITest sees, which is why the UI test drives
        // the stepper buttons instead of `adjust(toNormalizedSliderPosition:)`.
        #expect(
            AccessibilityTreeProbe.attribute("accessibilityValue", of: slider)
                as? NSNumber == NSNumber(value: TerminalFontSettings.defaultSize)
        )

        // The slider's minimum/maximum value labels are real buttons that
        // step the value — the UI test's drive mechanism.
        let buttonLabels = Set(
            elements
                .filter { AccessibilityTreeProbe.role(of: $0) == .button }
                .compactMap { AccessibilityTreeProbe.label(of: $0) }
        )
        #expect(
            buttonLabels.contains(
                String(Int(TerminalFontSettings.minimumSize))
            )
        )
        #expect(
            buttonLabels.contains(
                String(Int(TerminalFontSettings.maximumSize))
            )
        )
    }

    @Test("Slider step buttons drive the persisted font size")
    func stepButtonsDrivePersistedValue() throws {
        let fixture = try HostedTerminalSettings()
        defer { fixture.tearDown() }
        let buttons = AccessibilityTreeProbe.elements(under: fixture.hosted.root)
            .filter { AccessibilityTreeProbe.role(of: $0) == .button }
        let stepUp = try #require(buttons.first {
            AccessibilityTreeProbe.label(of: $0)
                == String(Int(TerminalFontSettings.maximumSize))
        })
        let stepDown = try #require(buttons.first {
            AccessibilityTreeProbe.label(of: $0)
                == String(Int(TerminalFontSettings.minimumSize))
        })

        #expect(fixture.font.fontSize == TerminalFontSettings.defaultSize)
        #expect(AccessibilityTreeProbe.performPress(stepUp) == true)
        #expect(
            fixture.font.fontSize == TerminalFontSettings.defaultSize + 1
        )
        #expect(
            fixture.defaults.double(
                forKey: TerminalFontSettings.Keys.fontSize
            ) == TerminalFontSettings.defaultSize + 1
        )
        #expect(AccessibilityTreeProbe.performPress(stepDown) == true)
        #expect(fixture.font.fontSize == TerminalFontSettings.defaultSize)
    }
}

@MainActor
private struct HostedTerminalSettings {
    let defaults: UserDefaults
    let font: TerminalFontSettings
    let hosted: AccessibilityTreeProbe.Hosted

    init() throws {
        let suiteName = "TerminalFontAccessibilityTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        font = TerminalFontSettings(
            defaults: defaults,
            availableFontFamilies: { [] }
        )
        hosted = AccessibilityTreeProbe.host(
            TerminalSettingsView(
                shell: ShellSettings(
                    defaults: defaults,
                    defaultShellPath: "/bin/zsh"
                ),
                theme: TerminalThemeSettings(defaults: defaults),
                cursor: TerminalCursorSettings(defaults: defaults),
                font: font,
                quickTerminal: QuickTerminalSettings(defaults: defaults),
                viewportHeight: 1_080
            ),
            size: NSSize(width: 720, height: 1_080)
        )
    }

    func tearDown() {
        hosted.tearDown()
    }
}
