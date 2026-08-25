//
//  AccessibilityLocalizationSmokeTests.swift
//  PineUITests
//

import AppKit
import XCTest

/// Focused release-critical accessibility/localization coverage. The class is
/// skipped in the ordinary seven-shard UI suite and enabled by CI's small
/// four-configuration matrix.
final class AccessibilityLocalizationSmokeTests: PineUITestCase {
    private var configuration: SmokeConfiguration!
    private var diagnosticContext = "setup"

    override func setUpWithError() throws {
        try super.setUpWithError()
        configuration = try SmokeConfiguration.environment()

        XCTAssertEqual(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            configuration.reduceMotion,
            "The runner must apply the requested Reduce Motion state"
        )
        XCTAssertEqual(
            NSWorkspace.shared
                .accessibilityDisplayShouldDifferentiateWithoutColor,
            configuration.differentiateWithoutColor,
            "The runner must apply Differentiate Without Color"
        )
    }

    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0,
           app?.state != .notRunning {
            captureDiagnostics(named: "failure-\(diagnosticContext)")
        }
        app?.terminate()
        try super.tearDownWithError()
    }

    func testSupportedLocalesRenderCriticalSurfaces() throws {
        let catalog = try SmokeLocalizationCatalog.load()
        let projectURL = try createTempProject(
            files: [
                "main.swift": "func main() {}\n",
                "notes.md": "# Notes\n",
            ],
            projectName: "Accessibility Matrix"
        )
        defer { cleanupProject(projectURL) }

        for locale in configuration.locales {
            try verifyWelcome(locale: locale, catalog: catalog)
            try verifyProject(
                projectURL,
                locale: locale,
                catalog: catalog
            )
        }
    }

    func testKeyboardOnlyCriticalJourney() throws {
        guard configuration.keyboardJourney else {
            throw XCTSkip("Keyboard journey runs once in the English matrix lane")
        }

        let catalog = try SmokeLocalizationCatalog.load()
        let locale = try XCTUnwrap(configuration.locales.first)
        let marker = "// accessibility keyboard save\n"
        let projectURL = try createTempProject(
            files: [
                "main.swift": "func main() {}\n",
                "notes.md": "# Notes\n",
            ],
            projectName: "Keyboard Journey"
        )
        defer { cleanupProject(projectURL) }

        diagnosticContext = "keyboard-journey"
        configureApplication(locale: locale)
        app.launchArguments.append("--ui-test-a11y-dirty-buffer")
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launchEnvironment["PINE_UI_TEST_DIRTY_FILE"] = "main.swift"
        app.launchEnvironment["PINE_UI_TEST_DIRTY_MARKER"] = marker
        launchConfiguredApplication()

        let sidebar = app.scrollViews["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))

        let mainNode = app.sidebarNodes["fileNode_main.swift"].firstMatch
        focusSidebarByKeyboard(selecting: mainNode, prefix: "m")
        app.typeKey(.return, modifierFlags: .command)
        let mainTab = editorTab("main.swift")
        XCTAssertTrue(mainTab.waitForExistence(timeout: 5))

        // The narrowly scoped DEBUG fixture dirties the file only after this
        // keyboard journey opens it. Saving itself remains a real Cmd-S path.
        let saveTitle = try catalog.value(
            for: "menu.save",
            locale: locale.language
        )
        let saveItem = app.menuItems[saveTitle].firstMatch
        let saveEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: saveItem
        )
        wait(for: [saveEnabled], timeout: 5)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(
            waitForFile(projectURL.appending(path: "main.swift"), toContain: marker),
            "Cmd-S should persist the seeded dirty buffer"
        )

        let notesNode = app.sidebarNodes["fileNode_notes.md"].firstMatch
        focusSidebarByKeyboard(
            selecting: notesNode,
            prefix: "n",
            backwards: true
        )
        app.typeKey(.return, modifierFlags: .command)
        let notesTab = editorTab("notes.md")
        XCTAssertTrue(notesTab.waitForExistence(timeout: 5))
        XCTAssertTrue(notesTab.isSelected)

        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForSelection(mainTab))

        app.typeKey("t", modifierFlags: .command)
        let newTerminal = app.buttons["newTerminalButton"].firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTerminalTabCount(2))

        let maximize = app.buttons["maximizeTerminalButton"].firstMatch
        XCTAssertTrue(maximize.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForLabel(
                maximize,
                toEqual: try catalog.value(
                    for: "terminal.restore",
                    locale: locale.language
                )
            )
        )
        app.typeKey(.return, modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForLabel(
                maximize,
                toEqual: try catalog.value(
                    for: "terminal.maximize",
                    locale: locale.language
                )
            )
        )

        // Native menu equivalents intentionally cover Accessibility events
        // that bypass Pine's physical-key local monitor.
        for _ in 0..<4 where !mainTab.isSelected && !notesTab.isSelected {
            app.typeKey(.tab, modifierFlags: .control)
        }
        XCTAssertTrue(
            mainTab.isSelected || notesTab.isSelected,
            "Control-Tab should leave the terminal pane for an editor pane"
        )

        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.descendants(matching: .any)["agentInbox"]
                .firstMatch.waitForExistence(timeout: 5),
            "Cmd-Shift-I should reach Agent Inbox without a pointer"
        )
    }

    func testRepresentativeAndPseudolocalizedLayouts() throws {
        guard configuration.captureLayout else {
            throw XCTSkip("Layout capture runs only in representative lanes")
        }

        let catalog = try SmokeLocalizationCatalog.load()
        let locale = configuration.pseudolocalized
            ? LocaleCase(language: "en", locale: "en_US")
            : try XCTUnwrap(configuration.locales.first)
        let projectURL = try createTempProject(
            files: [
                "a-very-long-primary-source-file-name.swift": "let value = 1\n",
                "another-long-release-notes-document.md": "# Release\n",
            ],
            projectName: "Long Localization Layout"
        )
        defer { cleanupProject(projectURL) }

        diagnosticContext = "layout-welcome"
        configureApplication(
            locale: locale,
            pseudolocalized: configuration.pseudolocalized
        )
        launchConfiguredApplication()
        let welcome = app.windows["welcome"].firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        assertContained(app.buttons["welcomeOpenFolderButton"], in: welcome)
        assertContained(app.buttons["welcomeAgentInboxButton"], in: welcome)
        captureDiagnostics(named: "layout-welcome")
        app.terminate()

        diagnosticContext = "layout-project"
        configureApplication(
            locale: locale,
            pseudolocalized: configuration.pseudolocalized
        )
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        launchConfiguredApplication()
        openFile("a-very-long-primary-source-file-name.swift")
        openFile("another-long-release-notes-document.md")
        let projectWindow = app.windows.firstMatch
        assertContained(
            editorTab("a-very-long-primary-source-file-name.swift"),
            in: projectWindow
        )
        assertContained(
            editorTab("another-long-release-notes-document.md"),
            in: projectWindow
        )
        app.buttons["terminalToggleButton"].firstMatch.click()
        XCTAssertTrue(
            app.buttons["newTerminalButton"].firstMatch
                .waitForExistence(timeout: 10)
        )
        captureDiagnostics(named: "layout-project-tabs-terminal")

        diagnosticContext = "layout-settings"
        openSettings(locale: locale)
        let generalPane = app.descendants(matching: .any)[
            "generalSettingsPane"
        ].firstMatch
        XCTAssertTrue(generalPane.waitForExistence(timeout: 10))
        let settingsWindow = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first {
                $0.frame.insetBy(dx: -1, dy: -1).contains(generalPane.frame)
            },
            "A Settings window should contain the General pane"
        )
        captureDiagnostics(named: "layout-settings-general")

        let terminalTitle = try catalog.value(
            for: "settings.tab.terminal",
            locale: locale.language
        )
        let terminalTab = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", terminalTitle)
        ).firstMatch
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 5))
        terminalTab.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["terminalAppearancePicker"]
                .firstMatch.waitForExistence(timeout: 5)
        )
        assertContained(terminalTab, in: settingsWindow)
        captureDiagnostics(named: "layout-settings-terminal")
        app.terminate()

        diagnosticContext = "layout-unsaved-alert"
        configureApplication(
            locale: locale,
            pseudolocalized: configuration.pseudolocalized
        )
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        launchConfiguredApplication()
        openFile("a-very-long-primary-source-file-name.swift")
        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(
            NSPasteboard.general.setString("// dirty layout\n", forType: .string)
        )
        app.menuBars.menuBarItems.element(boundBy: 2).click()
        let paste = app.menuItems.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                locale.pasteMenuRoot
            )
        ).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.click()
        editorTabCloseButton("a-very-long-primary-source-file-name.swift").click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        for button in alert.buttons.allElementsBoundByIndex {
            assertContained(button, in: alert)
        }
        captureDiagnostics(named: "layout-unsaved-alert")
    }

    private func verifyWelcome(
        locale: LocaleCase,
        catalog: SmokeLocalizationCatalog
    ) throws {
        diagnosticContext = "\(locale.language)-welcome"
        configureApplication(locale: locale)
        launchConfiguredApplication()

        let welcome = app.windows["welcome"].firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        let openFolder = app.buttons["welcomeOpenFolderButton"].firstMatch
        try assertLocalizedButton(
            openFolder,
            key: "sidebar.openFolderButton",
            locale: locale,
            catalog: catalog
        )
        let inbox = app.buttons["welcomeAgentInboxButton"].firstMatch
        try assertLocalizedButton(
            inbox,
            key: "menu.agentInbox",
            locale: locale,
            catalog: catalog
        )
        inbox.click()

        let emptyInbox = app.descendants(matching: .any)["agentInboxEmpty"]
            .firstMatch
        XCTAssertTrue(emptyInbox.waitForExistence(timeout: 5))
        XCTAssertTrue(
            emptyInbox.label.contains(
                try catalog.value(for: "agentInbox.empty", locale: locale.language)
            )
        )
        app.terminate()
    }

    private func verifyProject(
        _ projectURL: URL,
        locale: LocaleCase,
        catalog: SmokeLocalizationCatalog
    ) throws {
        diagnosticContext = "\(locale.language)-project"
        configureApplication(locale: locale)
        let dirtyMarker = "// accessibility \(locale.language) save\n"
        app.launchArguments.append("--ui-test-a11y-dirty-buffer")
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launchEnvironment["PINE_UI_TEST_DIRTY_FILE"] = "main.swift"
        app.launchEnvironment["PINE_UI_TEST_DIRTY_MARKER"] = dirtyMarker
        launchConfiguredApplication()
        openFile("main.swift")

        let terminalToggle = app.buttons["terminalToggleButton"].firstMatch
        try assertLocalizedButton(
            terminalToggle,
            key: "terminal.label",
            locale: locale,
            catalog: catalog
        )
        terminalToggle.click()

        let newTerminal = app.buttons["newTerminalButton"].firstMatch
        let maximize = app.buttons["maximizeTerminalButton"].firstMatch
        let hide = app.buttons["hideTerminalButton"].firstMatch
        try assertLocalizedButton(
            newTerminal,
            key: "terminal.new",
            locale: locale,
            catalog: catalog
        )
        try assertLocalizedButton(
            maximize,
            key: "terminal.maximize",
            locale: locale,
            catalog: catalog
        )
        try assertLocalizedButton(
            hide,
            key: "terminal.hide",
            locale: locale,
            catalog: catalog
        )
        newTerminal.click()
        XCTAssertTrue(waitForTerminalTabCount(2))
        maximize.click()
        XCTAssertTrue(
            waitForLabel(
                maximize,
                toEqual: try catalog.value(
                    for: "terminal.restore",
                    locale: locale.language
                )
            )
        )
        maximize.click()
        XCTAssertTrue(
            waitForLabel(
                maximize,
                toEqual: try catalog.value(
                    for: "terminal.maximize",
                    locale: locale.language
                )
            )
        )
        hide.click()
        XCTAssertTrue(newTerminal.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editorTab("main.swift").exists)

        try verifyCommandOverlay(
            CommandOverlayExpectation(
                menuKey: "menu.quickOpen",
                overlayID: "quickOpenOverlay",
                fieldID: "quickOpenSearchField",
                placeholderKey: "quickOpen.placeholder"
            ),
            locale: locale,
            catalog: catalog
        )
        try verifyCommandOverlay(
            CommandOverlayExpectation(
                menuKey: "menu.commandPalette",
                overlayID: "commandPaletteOverlay",
                fieldID: "commandPaletteSearchField",
                placeholderKey: "commandPalette.placeholder"
            ),
            locale: locale,
            catalog: catalog
        )
        try verifyCommandOverlay(
            CommandOverlayExpectation(
                menuKey: "menu.symbolNavigator",
                overlayID: "symbolNavigatorOverlay",
                fieldID: "symbolSearchField",
                placeholderKey: "symbolNavigator.placeholder"
            ),
            locale: locale,
            catalog: catalog
        )

        app.menuBars.menuBarItems["Pine"].click()
        let updateTitle = try catalog.value(
            for: "menu.checkForUpdates",
            locale: locale.language
        )
        let updateItem = app.menuItems[updateTitle].firstMatch
        XCTAssertTrue(updateItem.waitForExistence(timeout: 5))
        XCTAssertEqual(updateItem.elementType, .menuItem)
        XCTAssertFalse(updateItem.label.isEmpty)
        app.typeKey(.escape, modifierFlags: [])

        try verifyLocalizedSaveAlert(
            fileURL: projectURL.appending(path: "main.swift"),
            marker: dirtyMarker,
            locale: locale,
            catalog: catalog
        )

        openSettings(locale: locale)
        let generalTitle = try catalog.value(
            for: "settings.tab.general",
            locale: locale.language
        )
        let terminalTitle = try catalog.value(
            for: "settings.tab.terminal",
            locale: locale.language
        )
        let generalTab = app.buttons[generalTitle].firstMatch
        let terminalTab = app.buttons[terminalTitle].firstMatch
        XCTAssertTrue(generalTab.waitForExistence(timeout: 10))
        XCTAssertEqual(generalTab.elementType, .button)
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 5))
        XCTAssertEqual(terminalTab.elementType, .button)
        terminalTab.click()

        let cursorPicker = app.descendants(matching: .any)[
            "terminalCursorShapePicker"
        ].firstMatch
        XCTAssertTrue(cursorPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(cursorPicker.isEnabled)
        let cursorValue = try XCTUnwrap(cursorPicker.value as? String)
        XCTAssertEqual(
            cursorValue,
            try catalog.value(
                for: "terminal.cursor.shape.verticalBar",
                locale: locale.language
            ),
            "The cursor picker should expose its localized AX value"
        )
        app.terminate()
    }

    private func verifyLocalizedSaveAlert(
        fileURL: URL,
        marker: String,
        locale: LocaleCase,
        catalog: SmokeLocalizationCatalog
    ) throws {
        editorTabCloseButton("main.swift").click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))

        // The message text is the question, and it names the file — the HIG
        // order, and the wording #1541 replaced "Unsaved Changes" with.
        let question = String(
            format: try catalog.value(
                for: "dialog.unsavedChanges.question %@",
                locale: locale.language
            ),
            "main.swift"
        )
        XCTAssertTrue(alert.staticTexts[question].firstMatch.exists)
        let consequence = try catalog.value(
            for: "dialog.unsavedChanges.consequence",
            locale: locale.language
        )
        XCTAssertTrue(
            alert.staticTexts[consequence].firstMatch.exists,
            "The save alert should carry the consequence as informative text"
        )
        for key in [
            "dialog.unsavedChanges.save",
            "dialog.unsavedChanges.dontSave",
            "dialog.unsavedChanges.cancel",
        ] {
            let label = try catalog.value(for: key, locale: locale.language)
            let button = alert.buttons[label].firstMatch
            XCTAssertTrue(button.exists, "The save alert should expose \(key)")
            XCTAssertEqual(button.elementType, .button)
            XCTAssertTrue(button.isEnabled)
        }

        // Return invokes the alert's default Save action, proving the AX
        // default action while avoiding a locale-specific pointer target.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editorTab("main.swift").waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            waitForFile(fileURL, toContain: marker),
            "The default Save action should persist the localized fixture"
        )
    }

    private func verifyCommandOverlay(
        _ expectation: CommandOverlayExpectation,
        locale: LocaleCase,
        catalog: SmokeLocalizationCatalog
    ) throws {
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let menuTitle = try catalog.value(
            for: expectation.menuKey,
            locale: locale.language
        )
        let menuItem = app.menuItems[menuTitle].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        let overlay = commandOverlay(expectation.overlayID)
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let field = overlay.textFields[expectation.fieldID].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.elementType, .textField)
        XCTAssertEqual(
            field.placeholderValue,
            try catalog.value(
                for: expectation.placeholderKey,
                locale: locale.language
            )
        )
        XCTAssertTrue(field.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
    }

    private func assertLocalizedButton(
        _ button: XCUIElement,
        key: String,
        locale: LocaleCase,
        catalog: SmokeLocalizationCatalog
    ) throws {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing \(key)")
        XCTAssertEqual(button.elementType, .button, "\(key) must expose AXButton")
        XCTAssertEqual(
            button.label,
            try catalog.value(for: key, locale: locale.language),
            "\(key) must render the explicit \(locale.language) translation"
        )
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isHittable)
    }

    private func configureApplication(
        locale: LocaleCase,
        pseudolocalized: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "--reset-state",
            "--disable-agent-detection",
            "--disable-metal",
            "--disable-quick-terminal",
            "--disable-terminal-seeding",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(\(locale.language))",
            "-AppleLocale", locale.locale,
            "-AppleInterfaceStyle", configuration.appearance,
            "-NSShowNonLocalizedStrings", "YES",
        ]
        if pseudolocalized {
            app.launchArguments += ["-NSDoubleLocalizedStrings", "YES"]
        }
        app.launchEnvironment["PINE_UI_TEST_SETTINGS_SUITE"] =
            "PineUITests.Settings.A11y.\(UUID().uuidString)"
    }

    private func launchConfiguredApplication() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func openSettings(locale: LocaleCase) {
        app.menuBars.menuBarItems["Pine"].click()
        let root = locale.settingsMenuRoot
        let settings = app.menuItems.matching(
            NSPredicate(format: "label CONTAINS[c] %@", root)
        ).firstMatch
        XCTAssertTrue(
            settings.waitForExistence(timeout: 5),
            "The app menu should expose localized Settings containing \(root)"
        )
        settings.click()
    }

    private func focusSidebarByKeyboard(
        selecting target: XCUIElement,
        prefix: String,
        backwards: Bool = false,
        maxPresses: Int = 30
    ) {
        let modifiers: XCUIElement.KeyModifierFlags = backwards ? .shift : []
        for _ in 0..<maxPresses {
            app.typeText(prefix)
            if target.isSelected {
                return
            }
            app.typeKey(.tab, modifierFlags: modifiers)
        }
        XCTFail("Tab traversal should focus and select \(target.identifier)")
    }

    private func waitForSelection(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForTerminalTabCount(
        _ count: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let tabs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminalTab_")
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= %d", count),
            object: tabs
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(
        _ element: XCUIElement,
        toEqual label: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFile(
        _ url: URL,
        toContain text: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? String(contentsOf: url, encoding: .utf8))?.contains(text) == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func assertContained(
        _ element: XCUIElement,
        in container: XCUIElement
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(
            container.frame.insetBy(dx: -1, dy: -1).contains(element.frame),
            "\(element.identifier) must remain inside its containing surface"
        )
    }

    private func captureDiagnostics(named name: String) {
        guard app.state != .notRunning else { return }
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let screenshot = app.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = safeName
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let tree = app.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "\(safeName)-ax-tree"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)

        guard let root = ProcessInfo.processInfo.environment[
            "PINE_A11Y_DIAGNOSTICS"
        ] else { return }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? screenshot.pngRepresentation.write(
            to: directory.appending(path: "\(safeName).png")
        )
        try? tree.write(
            to: directory.appending(path: "\(safeName)-ax-tree.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private struct SmokeConfiguration {
    let name: String
    let locales: [LocaleCase]
    let appearance: String
    let reduceMotion: Bool
    let differentiateWithoutColor: Bool
    let keyboardJourney: Bool
    let captureLayout: Bool
    let pseudolocalized: Bool

    static func environment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PINE_A11Y_SMOKE_ENABLED"] == "1" else {
            throw XCTSkip("Enabled only by the accessibility smoke matrix")
        }
        let locales = try parseLocales(environment["PINE_A11Y_LOCALES"])
        return Self(
            name: environment["PINE_A11Y_CONFIGURATION"] ?? "unknown",
            locales: locales,
            appearance: environment["PINE_A11Y_APPEARANCE"] ?? "Light",
            reduceMotion: bool(environment["PINE_A11Y_REDUCE_MOTION"]),
            differentiateWithoutColor: bool(
                environment["PINE_A11Y_DIFFERENTIATE_WITHOUT_COLOR"]
            ),
            keyboardJourney: bool(environment["PINE_A11Y_KEYBOARD_JOURNEY"]),
            captureLayout: bool(environment["PINE_A11Y_CAPTURE_LAYOUT"]),
            pseudolocalized: bool(environment["PINE_A11Y_PSEUDOLOCALIZED"])
        )
    }

    private static func parseLocales(_ rawValue: String?) throws -> [LocaleCase] {
        let locales = try (rawValue ?? "").split(separator: ";").map { entry in
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].isEmpty == false,
                  fields[1].isEmpty == false else {
                throw SmokeConfigurationError.invalidLocales(rawValue ?? "")
            }
            return LocaleCase(
                language: String(fields[0]),
                locale: String(fields[1])
            )
        }
        guard locales.isEmpty == false else {
            throw SmokeConfigurationError.invalidLocales(rawValue ?? "")
        }
        return locales
    }

    private static func bool(_ value: String?) -> Bool {
        value == "1" || value?.lowercased() == "true"
    }
}

private struct LocaleCase {
    let language: String
    let locale: String

    var settingsMenuRoot: String {
        switch language {
        case "de": "Einstellungen"
        case "es", "pt-BR": "Ajustes"
        case "fr": "Réglages"
        case "ja": "設定"
        case "ko": "설정"
        case "ru": "Настройки"
        case "zh-Hans": "设置"
        default: "Settings"
        }
    }

    var pasteMenuRoot: String {
        switch language {
        case "de": "Einsetzen"
        case "es": "Pegar"
        case "fr": "Coller"
        case "ja": "ペースト"
        case "ko": "붙여넣기"
        case "pt-BR": "Colar"
        case "ru": "Вставить"
        case "zh-Hans": "粘贴"
        default: "Paste"
        }
    }
}

private enum SmokeConfigurationError: Error {
    case invalidLocales(String)
}

private struct CommandOverlayExpectation {
    let menuKey: String
    let overlayID: String
    let fieldID: String
    let placeholderKey: String
}

private struct SmokeLocalizationCatalog: Decodable {
    let strings: [String: SmokeCatalogEntry]

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appending(path: "Pine/Localizable.xcstrings")
        )
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func value(for key: String, locale: String) throws -> String {
        guard let value = strings[key]?.localizations?[locale]?.stringUnit?.value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              value != key else {
            throw SmokeCatalogError.missingTranslation(key: key, locale: locale)
        }
        return value
    }
}

private struct SmokeCatalogEntry: Decodable {
    let localizations: [String: SmokeCatalogLocalization]?
}

private struct SmokeCatalogLocalization: Decodable {
    let stringUnit: SmokeCatalogStringUnit?
}

private struct SmokeCatalogStringUnit: Decodable {
    let value: String
}

private enum SmokeCatalogError: Error {
    case missingTranslation(key: String, locale: String)
}
