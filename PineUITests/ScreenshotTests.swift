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
        attachScreenshot(screenshot, name: "screenshot-editor")
    }

    // MARK: - Terminal

    func testCaptureTerminal() throws {
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
        attachScreenshot(screenshot, name: "screenshot-terminal")
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
            ]
        )
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Wait for file tree to fully load
        Thread.sleep(forTimeInterval: 2.0)

        // Expand folders to show the tree structure
        for folderName in ["Sources", "Models", "Views", "Tests"] {
            let folderRow = app.staticTexts["fileNode_\(folderName)"]
            if waitForExistence(folderRow, timeout: 3) {
                expandFolder(folderRow, in: sidebar)
            }
        }

        // Let the tree settle after expanding
        Thread.sleep(forTimeInterval: 1.0)

        let screenshot = app.windows.firstMatch.screenshot()
        attachScreenshot(screenshot, name: "screenshot-sidebar")
    }

    /// Tries to expand a folder row in the sidebar outline.
    private func expandFolder(_ row: XCUIElement, in sidebar: XCUIElement) {
        // Strategy 1: double-click the row text
        row.doubleClick()
        sleep(1)

        // Strategy 2: click the disclosure triangle near the row
        let triangles = sidebar.disclosureTriangles
        for index in 0..<triangles.count {
            let triangle = triangles.element(boundBy: index)
            guard triangle.exists else { continue }
            let rowFrame = row.frame
            let triFrame = triangle.frame
            if abs(triFrame.midY - rowFrame.midY) < 10 {
                triangle.click()
                sleep(1)
                return
            }
        }
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
        attachScreenshot(screenshot, name: "screenshot-minimap")
    }

    // MARK: - Markdown Preview

    func testCaptureMarkdownPreview() throws {
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
