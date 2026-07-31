//
//  PineUITestCase.swift
//  PineUITests
//
//  Base class for Pine UI tests with common helpers.
//

import XCTest

/// Base class providing common setup and helpers for Pine UI tests.
class PineUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--reset-state",
            "--disable-agent-detection",
            "--disable-metal",
            "--disable-quick-terminal",
            "--disable-terminal-seeding",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
    }

    // MARK: - Helpers

    /// Creates a temporary project directory with sample files for testing.
    @discardableResult
    func createTempProject(
        files: [String: String] = ["main.swift": "// Hello\n"],
        directories: [String] = [],
        projectName: String? = nil
    ) throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineUITest-\(UUID().uuidString)")
        let dir = if let projectName {
            baseDirectory.appendingPathComponent(projectName, isDirectory: true)
        } else {
            baseDirectory
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for dirName in directories {
            let subdir = dir.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        }

        for (name, content) in files {
            let file = dir.appendingPathComponent(name)
            // Create intermediate directories for nested paths like "subfolder/file.txt"
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: file, atomically: true, encoding: .utf8)
        }

        return dir
    }

    /// Launches the app with the given project directory.
    /// Uses environment variable instead of launch arguments to avoid
    /// macOS interpreting the path as a file-open request.
    func launchWithProject(_ projectURL: URL) {
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launch()
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    /// Launches the app with a project and a pre-filled search query.
    /// Uses `PINE_SEARCH_QUERY` env var because XCUITest synthetic events
    /// do not reliably update SwiftUI `.searchable` bindings on `NSSearchToolbarItem`.
    func launchWithProjectAndSearch(_ projectURL: URL, query: String) {
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launchEnvironment["PINE_SEARCH_QUERY"] = query
        app.launch()
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    /// Launches the app in clean state (Welcome window should appear).
    func launchClean() {
        app.launch()
        app.activate()
    }

    /// Overrides the deterministic locale configured by the base class.
    ///
    /// Keep locale changes explicit in the individual test so menu labels and
    /// application strings are asserted under the same language.
    func useLaunchLocale(language: String, locale: String) {
        replaceLaunchArgument("-AppleLanguages", with: "(\(language))")
        replaceLaunchArgument("-AppleLocale", with: locale)
    }

    /// Enables the production first-launch terminal path for tests that cover
    /// startup behavior instead of the suite's legacy empty-editor fixture.
    func enableInitialTerminalSeeding() {
        app.launchArguments.removeAll {
            $0 == "--disable-terminal-seeding"
        }
    }

    /// Waits for an element to exist with a timeout.
    @discardableResult
    func waitForExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Clicks a menu bar item, waiting for it to become available.
    func clickMenuBarItem(_ title: String, timeout: TimeInterval = 5) {
        let item = app.menuBars.menuBarItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "\(title) menu should be accessible")
        item.click()
    }

    /// Cleans up a temporary project directory.
    func cleanupProject(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("PineUITest-") {
            try? FileManager.default.removeItem(at: parent)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Finds one of Pine's document-scoped command panels by accessibility
    /// identifier. Command overlays are NSPanel-backed windows, not sheets.
    func commandOverlay(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func replaceLaunchArgument(
        _ key: String,
        with value: String
    ) {
        guard let index = app.launchArguments.firstIndex(of: key),
              app.launchArguments.indices.contains(index + 1) else {
            XCTFail("Missing \(key) in PineUITestCase launch arguments")
            return
        }
        app.launchArguments[index + 1] = value
    }

    // MARK: - Editor Tab Helpers

    /// Finds an editor tab button by file name.
    func editorTab(_ fileName: String) -> XCUIElement {
        app.buttons["editorTab_\(fileName)"].firstMatch
    }

    /// Finds the close button for an editor tab by file name.
    func editorTabCloseButton(_ fileName: String) -> XCUIElement {
        app.buttons["editorTabClose_\(fileName)"].firstMatch
    }

    /// Permanently opens a file from the sidebar and waits for its editor tab.
    /// Sidebar single-clicks intentionally create replaceable preview tabs;
    /// double-click is the explicit-open gesture used by tests that need
    /// several durable tabs.
    func openFile(_ name: String) {
        let fileNode = app.sidebarNodes["fileNode_\(name)"]
        XCTAssertTrue(
            waitForExistence(fileNode, timeout: 10),
            "\(name) should appear in the sidebar"
        )
        fileNode.doubleClick()
        XCTAssertTrue(
            waitForExistence(editorTab(name), timeout: 5),
            "\(name) tab should appear"
        )
    }

    /// Opens a replaceable transient preview through the real single-click
    /// sidebar interaction.
    func previewFile(_ name: String) {
        let fileNode = app.sidebarNodes["fileNode_\(name)"]
        XCTAssertTrue(
            waitForExistence(fileNode, timeout: 10),
            "\(name) should appear in the sidebar"
        )
        fileNode.click()
        XCTAssertTrue(
            waitForExistence(editorTab(name), timeout: 5),
            "\(name) preview tab should appear"
        )
    }
}

extension XCUIApplication {
    /// Sidebar folders remain static text while actionable file rows expose
    /// a button role. Querying by identifier across roles keeps interaction
    /// tests aligned with the semantic accessibility hierarchy.
    var sidebarNodes: XCUIElementQuery {
        descendants(matching: .any)
    }
}
