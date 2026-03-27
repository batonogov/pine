//
//  ScreenshotTests.swift
//  PineUITests
//
//  On-demand screenshot capture for assets/ directory.
//  Skipped in CI — run locally: xcodebuild test ... -only-testing:PineUITests/ScreenshotTests
//

import XCTest

final class ScreenshotTests: PineUITestCase {

    /// Screenshots are on-demand only — skip in CI.
    private func skipInCI() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Screenshot tests run on demand, not in CI")
        }
    }

    /// Path to the assets/ directory at the repo root.
    private var assetsDirectory: URL {
        // __FILE__ is inside PineUITests/, repo root is one level up
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PineUITests/
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("assets", isDirectory: true)
    }

    /// Saves a screenshot to assets/ with the given filename.
    private func saveScreenshot(_ screenshot: XCUIScreenshot, name: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: assetsDirectory.path) {
            try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        }
        let fileURL = assetsDirectory.appendingPathComponent(name)
        try screenshot.pngRepresentation.write(to: fileURL)
    }

    private var projectURL: URL?

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Welcome Window

    func testCaptureWelcomeWindow() throws {
        try skipInCI()

        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear"
        )

        // Small delay to let animations settle
        Thread.sleep(forTimeInterval: 1.0)

        let screenshot = app.windows["welcome"].screenshot()
        try saveScreenshot(screenshot, name: "screenshot-welcome.png")
    }

    // MARK: - Editor with File

    func testCaptureEditorWithFile() throws {
        try skipInCI()

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
        ])
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open the main file
        let fileRow = app.staticTexts["fileNode_GreetingService.swift"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "File should appear in sidebar")
        fileRow.click()

        // Wait for syntax highlighting to settle
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        try saveScreenshot(screenshot, name: "screenshot-editor.png")
    }

    // MARK: - Terminal

    func testCaptureTerminal() throws {
        try skipInCI()

        projectURL = try createTempProject(files: [
            "main.swift": "print(\"Hello, Pine!\")\n"
        ])
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open a file first
        let fileRow = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(fileRow, timeout: 5) { fileRow.click() }

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
        try saveScreenshot(screenshot, name: "screenshot-terminal.png")
    }

    // MARK: - Sidebar (file tree)

    func testCaptureSidebar() throws {
        try skipInCI()

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
            ]
        )
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Wait for file tree to fully load
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        try saveScreenshot(screenshot, name: "screenshot-sidebar.png")
    }

    // MARK: - Minimap

    func testCaptureMinimap() throws {
        try skipInCI()

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
        ])
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open the file
        let fileRow = app.staticTexts["fileNode_Calculator.swift"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "File should appear in sidebar")
        fileRow.click()

        // Minimap should be visible by default
        let minimap = app.groups["minimap"]
        XCTAssertTrue(waitForExistence(minimap, timeout: 5), "Minimap should be visible")

        // Wait for syntax highlighting and minimap to render
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        try saveScreenshot(screenshot, name: "screenshot-minimap.png")
    }

    // MARK: - Markdown Preview

    func testCaptureMarkdownPreview() throws {
        try skipInCI()

        let markdown = """
        # Pine Editor

        A **minimal** native macOS code editor built with SwiftUI.

        ## Features

        - Syntax highlighting for 20+ languages
        - Built-in terminal emulator
        - Git integration with blame view
        - Minimap and code folding
        - Project-wide search

        ## Getting Started

        ```swift
        let editor = PineEditor()
        editor.open(project: "~/Code/myapp")
        ```

        > Pine is designed to be fast, lightweight, and beautiful.
        """

        projectURL = try createTempProject(files: [
            "README.md": markdown
        ])
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.staticTexts["fileNode_README.md"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "README.md should appear")
        fileRow.click()

        // Wait for markdown preview to render
        Thread.sleep(forTimeInterval: 2.0)

        let screenshot = app.windows.firstMatch.screenshot()
        try saveScreenshot(screenshot, name: "screenshot-markdown.png")
    }
}
