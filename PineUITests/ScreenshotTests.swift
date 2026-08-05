//
//  ScreenshotTests.swift
//  PineUITests
//
//  On-demand screenshot capture using XCTAttachment (Apple Way).
//  Run locally or in CI: xcodebuild test ... -only-testing:PineUITests/ScreenshotTests
//  Screenshots are saved in the .xcresult bundle. Extract with:
//    scripts/update-screenshots.sh
//

import XCTest

final class ScreenshotTests: PineUITestCase {

    /// Attaches a screenshot to the test result with the given name.
    private func attachScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var projectURL: URL?

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Welcome Window

    func testCaptureWelcomeWindow() throws {
        // Marketing captures must never inherit personal project history from
        // the machine that generated them.
        app.launchArguments += ["--clear-recent-projects"]
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear"
        )

        // Small delay to let animations settle
        Thread.sleep(forTimeInterval: 1.0)

        let screenshot = app.windows["welcome"].screenshot()
        attachScreenshot(screenshot, name: "screenshot-welcome")
    }

    // MARK: - Agent Inbox

    func testCaptureAgentInbox() throws {
        app.launchArguments += [
            "--clear-recent-projects",
            "--ui-test-agent-inbox-marketing",
        ]
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear"
        )

        let inboxButton = app.buttons["welcomeAgentInboxButton"]
        XCTAssertTrue(
            waitForExistence(inboxButton, timeout: 5),
            "Agent Inbox should be available from Welcome"
        )
        inboxButton.click()

        let inboxWindow = app.windows["Agent Inbox"]
        XCTAssertTrue(
            waitForExistence(inboxWindow, timeout: 10),
            "Agent Inbox window should appear"
        )
        // SwiftUI may create the new window behind Welcome on macOS 27.
        // Close Welcome after the Inbox exists so no window covers the shot.
        let closeWelcome = welcomeWindow.buttons[
            XCUIIdentifierCloseWindow
        ].firstMatch
        XCTAssertTrue(closeWelcome.exists, "Welcome close button should exist")
        closeWelcome.click()
        XCTAssertTrue(
            welcomeWindow.waitForNonExistence(timeout: 5),
            "Welcome should close before capturing Agent Inbox"
        )
        let releaseTask = inboxWindow.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "Approve the release announcement"
            )
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(releaseTask, timeout: 5),
            "Marketing tasks should populate Agent Inbox"
        )

        Thread.sleep(forTimeInterval: 1.0)

        let screenshot = inboxWindow.screenshot()
        attachScreenshot(screenshot, name: "screenshot-agent-inbox")
    }

    // MARK: - Editor with File

    func testCaptureEditorWithFile() throws {
        let swiftCode = """
        import Foundation

        /// A simple greeting service.
        struct GreetingService {
            let name: String

            func greet() -> String {
                return "Hello, \\(name)!"
            }

            func farewell() -> String {
                return "Goodbye, \\(name)!"
            }
        }

        let service = GreetingService(name: "World")
        print(service.greet())
        print(service.farewell())
        """

        projectURL = try createTempProject(files: [
            "GreetingService.swift": swiftCode,
            "README.md": "# Demo Project\n\nA sample project.\n",
            "main.swift": "// Entry point\nimport Foundation\n"
        ], projectName: "Pine Demo")
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open the main file
        let fileRow = app.sidebarNodes["fileNode_GreetingService.swift"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "File should appear in sidebar")
        fileRow.doubleClick()

        // Wait for syntax highlighting to settle
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-editor")
    }

    // MARK: - Terminal

    func testCaptureTerminal() throws {
        projectURL = try createTempProject(files: [
            "main.swift": "print(\"Hello, Pine!\")\n"
        ], projectName: "Pine Demo")
        try configureMarketingShell(for: try XCTUnwrap(projectURL))
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open a file first
        let fileRow = app.sidebarNodes["fileNode_main.swift"]
        if waitForExistence(fileRow, timeout: 5) { fileRow.doubleClick() }

        // Show terminal via status bar toggle
        let toggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        XCTAssertTrue(waitForExistence(toggle, timeout: 10), "Terminal toggle should exist")
        toggle.click()

        // Wait for terminal to appear
        let newTerminalButton = app.descendants(matching: .any)["newTerminalButton"].firstMatch
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should become visible"
        )

        // Let terminal initialize
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-terminal")
    }

    /// Keeps personal dotfiles and temporary paths out of the marketing capture.
    private func configureMarketingShell(for projectURL: URL) throws {
        let configURL = projectURL.deletingLastPathComponent()
            .appendingPathComponent("zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        let configuration = """
        precmd() { print -Pn '\\e]0;Terminal 1\\a' }
        PROMPT='%F{green}➜%f  %F{cyan}%1~%f '
        """
        try configuration.write(
            to: configURL.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
        app.launchEnvironment["ZDOTDIR"] = configURL.path
    }

    // MARK: - Sidebar (file tree)

    func testCaptureSidebar() throws {
        projectURL = try createTempProject(
            files: [
                "Sources/App.swift": "// App entry point\n",
                "Sources/Models/User.swift": "struct User {}\n",
                "Sources/Models/Post.swift": "struct Post {}\n",
                "Sources/Views/MainView.swift": "// Main view\n",
                "Tests/AppTests.swift": "// Tests\n",
                "Package.swift": "// swift-tools-version: 6.0\n",
                "README.md": "# Project\n"
            ],
            directories: [
                "Sources/Models",
                "Sources/Views",
                "Tests"
            ],
            projectName: "Pine Demo"
        )
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Wait for file tree to fully load
        Thread.sleep(forTimeInterval: 2.0)

        // Expand folders to show the tree structure
        for folderName in ["Sources", "Models", "Views", "Tests"] {
            let folderRow = app.sidebarNodes["fileNode_\(folderName)"]
            if waitForExistence(folderRow, timeout: 3) {
                expandFolder(folderRow, in: sidebar)
            }
        }

        // Let the tree settle after expanding
        Thread.sleep(forTimeInterval: 1.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-sidebar")
    }

    /// Tries to expand a folder row in the sidebar.
    /// The new ScrollView-based sidebar toggles expansion on a single tap.
    private func expandFolder(_ row: XCUIElement, in sidebar: XCUIElement) {
        row.click()
        sleep(1)
    }

    // MARK: - Minimap

    func testCaptureMinimap() throws {
        // Create a file with enough content to make the minimap useful
        let lines = (1...80).map { "let line\($0) = \($0) * \($0)" }.joined(separator: "\n")
        let swiftCode = """
        import Foundation

        struct Calculator {
        \(lines)

            func sum() -> Int {
                return line1 + line2 + line3
            }
        }
        """

        projectURL = try createTempProject(files: [
            "Calculator.swift": swiftCode
        ], projectName: "Pine Demo")
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open the file
        let fileRow = app.sidebarNodes["fileNode_Calculator.swift"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "File should appear in sidebar")
        fileRow.doubleClick()

        // Minimap should be visible by default
        let minimap = app.groups["minimap"]
        XCTAssertTrue(waitForExistence(minimap, timeout: 5), "Minimap should be visible")

        // Wait for syntax highlighting and minimap to render
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-minimap")
    }

    // MARK: - Markdown Preview

    func testCaptureMarkdownPreview() throws {
        let markdown = """
        # Pine Editor

        A **native** macOS code editor for modern CLI-agent workflows.

        ## Features

        - Syntax highlighting for 37 languages
        - Split editor and terminal panes
        - LSP diagnostics and code intelligence
        - Git context and live agent activity
        - Minimap, folding, and project search

        ## Getting Started

        ```swift
        let editor = PineEditor()
        editor.open(project: "~/Code/myapp")
        ```

        > Keep the agent in the terminal and the code in view.
        """

        projectURL = try createTempProject(files: [
            "README.md": markdown
        ], projectName: "Pine Demo")
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.sidebarNodes["fileNode_README.md"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "README.md should appear")
        fileRow.doubleClick()

        // Wait for the editor tab to confirm the file opened.
        let editorTab = app.descendants(matching: .any)["editorTab_README.md"].firstMatch
        XCTAssertTrue(
            waitForExistence(editorTab, timeout: 10),
            "README.md tab should appear after opening the file"
        )

        // Enable markdown preview mode explicitly via the toggle button in the tab bar
        let previewToggle = app.descendants(matching: .any)["markdownPreviewToggle"].firstMatch
        XCTAssertTrue(
            waitForExistence(previewToggle, timeout: 5),
            "Markdown preview toggle should appear for .md files"
        )
        previewToggle.click()

        // Wait for markdown preview to render
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-markdown")
    }
}
