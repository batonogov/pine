//
//  SettingsUITests.swift
//  PineUITests
//

import XCTest

final class SettingsUITests: PineUITestCase {
    private var settingsSuiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        settingsSuiteName = "PineUITests.Settings.\(UUID().uuidString)"
        app.launchEnvironment["PINE_UI_TEST_SETTINGS_SUITE"] = settingsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let defaults = UserDefaults(suiteName: settingsSuiteName) {
            defaults.removePersistentDomain(forName: settingsSuiteName)
        }
        try super.tearDownWithError()
    }

    func testSettingsExposeContextualHelp() throws {
        launchClean()
        openSettings()

        let helpButton = app.buttons["settingsHelpButton"].firstMatch
        XCTAssertTrue(
            helpButton.waitForExistence(timeout: 10),
            "Settings should expose native help for the selected pane"
        )
    }

    func testTerminalPaneExposesThemeAndQuickTerminalControls() throws {
        launchClean()
        openSettings()

        let terminalTab = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(
            terminalTab.waitForExistence(timeout: 10),
            "The consolidated Settings scene should expose Terminal"
        )
        terminalTab.click()

        let appearance = app.descendants(matching: .any)[
            "terminalAppearancePicker"
        ].firstMatch
        XCTAssertTrue(
            appearance.waitForExistence(timeout: 5),
            "Terminal appearance policy should be reachable"
        )

        let scrollView = app.scrollViews["terminalSettingsScrollView"].firstMatch
        XCTAssertTrue(scrollView.exists, "Terminal settings should be scrollable")
        let cursorPicker = app.descendants(matching: .any)[
            "terminalCursorShapePicker"
        ].firstMatch
        let cursorBlink = app.descendants(matching: .any)[
            "terminalCursorBlinkToggle"
        ].firstMatch
        for _ in 0..<2 where cursorBlink.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            cursorPicker.waitForExistence(timeout: 5),
            "Terminal cursor shape should be reachable"
        )
        XCTAssertTrue(
            cursorBlink.waitForExistence(timeout: 5),
            "Terminal cursor blinking should be reachable"
        )
        XCTAssertTrue(cursorPicker.isHittable)
        XCTAssertTrue(cursorBlink.isHittable)
        let verticalBarSegment = pickerSegment(
            labeled: "Vertical Bar",
            in: cursorPicker
        )
        let blockSegment = pickerSegment(labeled: "Block", in: cursorPicker)
        XCTAssertTrue(verticalBarSegment.waitForExistence(timeout: 5))
        XCTAssertTrue(blockSegment.waitForExistence(timeout: 5))
        XCTAssertEqual(
            cursorPicker.value as? String,
            "Vertical Bar",
            "Fresh settings should select the thin vertical-bar default"
        )
        let initialBlinkState = checkboxState(cursorBlink)
        XCTAssertEqual(
            initialBlinkState,
            true,
            "Fresh settings should enable cursor blinking"
        )

        // XCUI's click invokes the native radio button's AXPress action and
        // does not depend on the runner's global Full Keyboard Access setting.
        blockSegment.click()
        let blockSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Block"),
            object: cursorPicker
        )
        wait(for: [blockSelected], timeout: 5)
        XCTAssertEqual(cursorPicker.value as? String, "Block")
        XCTAssertEqual(
            checkboxState(cursorBlink),
            initialBlinkState,
            "Changing shape must preserve blinking"
        )

        cursorBlink.click()
        XCTAssertEqual(
            checkboxState(cursorBlink),
            false,
            "Blinking should be independently mutable"
        )
        XCTAssertEqual(
            cursorPicker.value as? String,
            "Block",
            "Changing blinking must preserve the selected shape"
        )

        let selectedTheme = app.descendants(matching: .any)[
            "terminalThemeRow_solarized"
        ].firstMatch
        for _ in 0..<2 where selectedTheme.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            selectedTheme.waitForExistence(timeout: 5),
            "Terminal theme rows should be reachable"
        )
        XCTAssertTrue(
            selectedTheme.isHittable,
            "Solarized theme row should be hittable before mutation"
        )
        selectedTheme.click()
        XCTAssertTrue(
            selectedTheme.isSelected,
            "Clicking Solarized should update the selected accessibility trait"
        )

        let enabledToggle = app.descendants(matching: .any)[
            "quickTerminalEnabledToggle"
        ].firstMatch
        for _ in 0..<5 where enabledToggle.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            enabledToggle.waitForExistence(timeout: 5),
            "Quick Terminal controls should be embedded in Terminal Settings"
        )
        XCTAssertTrue(enabledToggle.isHittable)

        let recorder = app.descendants(matching: .any)[
            "quickTerminalHotkeyRecorder"
        ].firstMatch
        let edgePicker = app.descendants(matching: .any)[
            "quickTerminalScreenEdgePicker"
        ].firstMatch
        let sizeSlider = app.descendants(matching: .any)[
            "quickTerminalSizeSlider"
        ].firstMatch
        let displayPicker = app.descendants(matching: .any)[
            "quickTerminalTargetDisplayPicker"
        ].firstMatch
        let focusToggle = app.descendants(matching: .any)[
            "quickTerminalHideOnFocusLossToggle"
        ].firstMatch
        let resetButton = app.descendants(matching: .any)[
            "quickTerminalResetButton"
        ].firstMatch

        for control in [
            recorder,
            edgePicker,
            sizeSlider,
            displayPicker,
            focusToggle,
            resetButton,
        ] {
            XCTAssertTrue(
                control.waitForExistence(timeout: 5),
                "\(control.identifier) should be reachable"
            )
        }

        if recorder.isEnabled == false {
            enabledToggle.click()
        }
        XCTAssertTrue(recorder.isEnabled)

        for _ in 0..<4 where recorder.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            recorder.isHittable,
            "The hotkey recorder should be keyboard-focusable and clickable"
        )
        let idleRecorderValue = String(describing: recorder.value)
        recorder.click()
        XCTAssertNotEqual(
            String(describing: recorder.value),
            idleRecorderValue,
            "Starting capture should expose its recording state accessibly"
        )
        recorder.click()

        for _ in 0..<4 where edgePicker.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(edgePicker.isHittable)
        XCTAssertTrue(
            String(describing: edgePicker.value).contains("Top"),
            "The edge picker should expose its persisted selection"
        )
        // SwiftUI hosts Picker menus in ThemeWidgetControlViewService on
        // Tahoe and the current macOS beta, outside Pine's XCUITest query
        // tree. Unit tests cover the binding's mutation/persistence matrix;
        // this test verifies the real control's value and enabled state.

        for _ in 0..<4 where sizeSlider.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(sizeSlider.isHittable)
        let originalSize = String(describing: sizeSlider.value)
        sizeSlider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(
            String(describing: sizeSlider.value),
            originalSize,
            "Adjusting the size slider should update its accessible value"
        )

        for _ in 0..<4 where displayPicker.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(displayPicker.isHittable)
        XCTAssertTrue(
            String(describing: displayPicker.value).contains("Active Display"),
            "The display picker should expose its persisted selection"
        )

        for _ in 0..<4 where focusToggle.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(focusToggle.isHittable)
        let originalFocusPolicy = String(describing: focusToggle.value)
        focusToggle.click()
        XCTAssertNotEqual(
            String(describing: focusToggle.value),
            originalFocusPolicy,
            "The focus-loss policy should be mutable"
        )

        for _ in 0..<4 where enabledToggle.isHittable == false {
            scrollView.swipeDown()
        }
        XCTAssertTrue(
            enabledToggle.isHittable,
            "The master toggle should be hittable before disabling controls"
        )
        let enabledValue = String(describing: enabledToggle.value)
        enabledToggle.click()
        XCTAssertNotEqual(
            String(describing: enabledToggle.value),
            enabledValue,
            "The master toggle should mutate immediate settings state"
        )
        XCTAssertTrue(
            recorder.isEnabled,
            "The recorder must remain available to recover from a conflicting hotkey"
        )
        XCTAssertFalse(edgePicker.isEnabled)
        XCTAssertFalse(sizeSlider.isEnabled)
        XCTAssertFalse(displayPicker.isEnabled)
        XCTAssertFalse(focusToggle.isEnabled)

        enabledToggle.click()
        for _ in 0..<3 where resetButton.isHittable == false {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            resetButton.isHittable,
            "Reset should be hittable after scrolling to Quick Terminal"
        )
        resetButton.click()
        XCTAssertTrue(
            String(describing: edgePicker.value).contains("Top"),
            "Reset should restore the default screen edge"
        )
        XCTAssertTrue(
            String(describing: displayPicker.value).contains("Active Display"),
            "Reset should restore the default target display"
        )
        XCTAssertEqual(
            String(describing: sizeSlider.value),
            originalSize,
            "Reset should restore the default Quick Terminal size"
        )
        XCTAssertEqual(
            String(describing: focusToggle.value),
            originalFocusPolicy,
            "Reset should restore the default focus-loss policy"
        )
        for _ in 0..<5 where selectedTheme.isHittable == false {
            scrollView.swipeDown()
        }
        let pineTheme = app.descendants(matching: .any)[
            "terminalThemeRow_pine"
        ].firstMatch
        XCTAssertTrue(pineTheme.waitForExistence(timeout: 5))
        XCTAssertTrue(
            pineTheme.isHittable,
            "Pine theme row should be hittable before restoring the default"
        )
        pineTheme.click()
        XCTAssertTrue(
            pineTheme.isSelected,
            "Clicking Pine should restore the selected accessibility trait"
        )
    }

    func testEverySettingsPaneUsesLocalizedLabels() throws {
        launchClean()
        openSettings(
            menuTitle: "Settings…",
            generalTabTitle: "General"
        )

        assertSettingsPanes([
            (
                tab: "General",
                contentIdentifier: "generalSettingsPane",
                expectedLabels: [
                    "Auto Save",
                    "Insert Final Newline",
                    "Strip Trailing Whitespace",
                    "Format on Save",
                    "Smart List Continuation",
                    "Word Wrap",
                    "Minimap",
                ],
                expectedIdentifiers: ["generalFontSizeSlider"]
            ),
            (
                tab: "Terminal",
                contentIdentifier: "terminalAppearancePicker",
                expectedLabels: [
                    "Cursor",
                    "Shape",
                    "Vertical Bar",
                    "Block",
                    "Underline",
                    "Blink cursor",
                ],
                expectedIdentifiers: [
                    "terminalCursorShapePicker",
                    "terminalCursorBlinkToggle",
                ]
            ),
            (
                tab: "Language Servers",
                contentIdentifier: "lsp-settings-executable",
                expectedLabels: [],
                expectedIdentifiers: []
            ),
            (
                tab: "Agent Handoff",
                contentIdentifier: "agentHandoffReadOnlyContextToggle",
                expectedLabels: [],
                expectedIdentifiers: []
            ),
            (
                tab: "Key Bindings & Tasks",
                contentIdentifier: "keyBindingsSettingsPane",
                expectedLabels: [
                    "Open File",
                    "Reload",
                ],
                expectedIdentifiers: []
            ),
        ])
    }

    func testEverySettingsPaneUsesRussianLabelsWithoutRawKeys() throws {
        useLaunchLocale(language: "ru", locale: "ru_RU")
        launchClean()
        openSettings(
            menuTitle: "Настройки…",
            generalTabTitle: "Основные"
        )

        assertSettingsPanes([
            (
                tab: "Основные",
                contentIdentifier: "generalSettingsPane",
                expectedLabels: [
                    "Автосохранение",
                    "Добавлять перевод строки в конце",
                    "Удалять пробелы в конце строк",
                    "Форматировать при сохранении",
                    "Продолжать списки автоматически",
                    "Переносить строки",
                    "Мини-карта",
                ],
                expectedIdentifiers: ["generalFontSizeSlider"]
            ),
            (
                tab: "Терминал",
                contentIdentifier: "terminalAppearancePicker",
                expectedLabels: [
                    "Курсор",
                    "Форма",
                    "Вертикальная черта",
                    "Блок",
                    "Подчёркивание",
                    "Мигание курсора",
                ],
                expectedIdentifiers: [
                    "terminalCursorShapePicker",
                    "terminalCursorBlinkToggle",
                ]
            ),
            (
                tab: "Языковые серверы",
                contentIdentifier: "lsp-settings-executable",
                expectedLabels: [],
                expectedIdentifiers: []
            ),
            (
                tab: "Передача контекста",
                contentIdentifier: "agentHandoffReadOnlyContextToggle",
                expectedLabels: [],
                expectedIdentifiers: []
            ),
            (
                tab: "Сочетания клавиш и задачи",
                contentIdentifier: "keyBindingsSettingsPane",
                expectedLabels: [
                    "Открыть файл",
                    "Перезагрузить",
                ],
                expectedIdentifiers: []
            ),
        ])
    }

    private func assertSettingsPanes(
        _ panes: [(
            tab: String,
            contentIdentifier: String,
            expectedLabels: [String],
            expectedIdentifiers: [String]
        )]
    ) {
        for pane in panes {
            let tab = app.buttons[pane.tab].firstMatch
            XCTAssertTrue(
                tab.waitForExistence(timeout: 5),
                "Settings should expose the \(pane.tab) tab"
            )
            tab.click()

            let content = app.descendants(matching: .any)[
                pane.contentIdentifier
            ].firstMatch
            XCTAssertTrue(
                content.waitForExistence(timeout: 5),
                "\(pane.tab) should expose its localized content"
            )

            for label in pane.expectedLabels {
                let element = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", label)
                ).firstMatch
                XCTAssertTrue(
                    element.waitForExistence(timeout: 2),
                    "\(pane.tab) should expose the localized \(label) control"
                )
            }

            for identifier in pane.expectedIdentifiers {
                let element = app.descendants(matching: .any)[
                    identifier
                ].firstMatch
                XCTAssertTrue(
                    element.waitForExistence(timeout: 2),
                    "\(pane.tab) should expose the \(identifier) control"
                )
            }

            let rawLabels = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "settings."
                )
            ).allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(
                rawLabels.isEmpty,
                "\(pane.tab) exposes raw localization keys: \(rawLabels)"
            )
        }
    }

    /// SwiftUI's segmented `Picker` exposes its selectable children as native
    /// radio buttons on macOS. Query that semantic role for interaction; the
    /// selected shape is announced by the parent picker's explicit AX value.
    private func pickerSegment(
        labeled label: String,
        in picker: XCUIElement
    ) -> XCUIElement {
        picker.radioButtons[label].firstMatch
    }

    /// XCTest bridges macOS checkbox values as Bool, NSNumber, or String
    /// depending on the runner/runtime combination.
    private func checkboxState(_ checkbox: XCUIElement) -> Bool? {
        if let value = checkbox.value as? Bool {
            return value
        }
        if let value = checkbox.value as? NSNumber {
            return value.boolValue
        }
        guard let value = checkbox.value as? String else { return nil }
        switch value.lowercased() {
        case "1", "true", "on":
            return true
        case "0", "false", "off":
            return false
        default:
            return nil
        }
    }

    private func openSettings(
        menuTitle: String = "Settings…",
        generalTabTitle: String = "General"
    ) {
        let appMenu = app.menuBars.menuBarItems["Pine"]
        XCTAssertTrue(
            appMenu.waitForExistence(timeout: 10),
            "Pine application menu should be available"
        )
        appMenu.click()
        let settingsItem = app.menuItems[menuTitle].firstMatch
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 5),
            "Application menu should expose Settings"
        )
        settingsItem.click()

        XCTAssertTrue(
            app.buttons[generalTabTitle].firstMatch.waitForExistence(timeout: 10),
            "The consolidated Settings scene should open"
        )
    }
}
