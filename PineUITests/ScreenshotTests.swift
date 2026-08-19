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
        // The marketing launch path hides every SwiftUI/AppKit Welcome owner.
        // This avoids closing only one of the duplicate fallback windows that
        // macOS 26 can expose to XCUITest.
        XCTAssertTrue(
            welcomeWindow.waitForNonExistence(timeout: 5),
            "Welcome should hide before capturing Agent Inbox"
        )
        let releaseTask = inboxWindow.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "Draft the release announcement"
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

    func testMarketingShellFixtureStaysOutOfProjectAndCoversBothShells() throws {
        projectURL = try createTempProject(projectName: "Pine Demo")
        let projectURL = try XCTUnwrap(projectURL)

        let configURL = try configureMarketingShell(for: projectURL)

        XCTAssertEqual(
            configURL.deletingLastPathComponent().standardizedFileURL,
            projectURL.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertFalse(
            configURL.standardizedFileURL.path.hasPrefix(
                projectURL.standardizedFileURL.path + "/"
            ),
            "Marketing shell fixtures must not appear in the project tree"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configURL.appendingPathComponent(".zshrc").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configURL.appendingPathComponent(".bash_profile").path
            )
        )
        XCTAssertEqual(app.launchEnvironment["PS1"], "pine@mac \\W $ ")
        XCTAssertEqual(app.launchEnvironment["PROMPT"], "pine@mac %1~ %# ")
    }

    func testCaptureTerminal() throws {
        let swiftCode = """
        import Foundation

        struct WorkspaceRoute {
            let project: URL
            let terminalID: UUID
        }

        func routeAgentTask(
            _ taskID: UUID,
            through routes: [UUID: WorkspaceRoute]
        ) -> WorkspaceRoute? {
            routes[taskID]
        }
        """
        projectURL = try createTempProject(files: [
            "WorkspaceRouter.swift": swiftCode
        ], projectName: "Pine Demo")
        try configureMarketingShell(for: try XCTUnwrap(projectURL))
        launchWithProject(try XCTUnwrap(projectURL))

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open a file first
        let fileRow = app.sidebarNodes["fileNode_WorkspaceRouter.swift"]
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

    /// Keeps personal dotfiles, runner identity, and temporary paths out of
    /// the marketing capture. GitHub's macOS account may still use bash while
    /// developer machines normally use zsh, so configure both login shells.
    @discardableResult
    private func configureMarketingShell(for projectURL: URL) throws -> URL {
        let configURL = projectURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".pine-marketing-shell",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)

        let zshConfiguration = #"""
        precmd() { print -Pn '\e]0;Terminal 1\a' }
        print -P ''
        print -P '%F{8}$ git diff --stat%f'
        print -P '%F{cyan} Sources/WorkspaceRouter.swift%f | 28 +++++++++++++++++++'
        print -P '%F{cyan} Tests/WorkspaceRouterTests.swift%f | 17 +++++++++++'
        print -P ' 2 files changed, 45 insertions(+)'
        print -P ''
        print -P '%F{8}$ swift test%f'
        print -P '%F{green}✓ 42 tests passed%f'
        print -P ''
        PROMPT='%F{green}pine@mac%f %F{cyan}%1~%f %# '
        """#
        try zshConfiguration.write(
            to: configURL.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        let bashConfiguration = #"""
        export BASH_SILENCE_DEPRECATION_WARNING=1
        PROMPT_COMMAND='printf "\033]0;Terminal 1\007"'
        printf '\n\033[2m$ git diff --stat\033[0m\n'
        printf '\033[36m Sources/WorkspaceRouter.swift\033[0m | 28 +++++++++++++++++++\n'
        printf '\033[36m Tests/WorkspaceRouterTests.swift\033[0m | 17 +++++++++++\n'
        printf ' 2 files changed, 45 insertions(+)\n\n'
        printf '\033[2m$ swift test\033[0m\n'
        printf '\033[32m✓ 42 tests passed\033[0m\n\n'
        PS1='\[\e[32m\]pine@mac\[\e[0m\] \[\e[36m\]\W\[\e[0m\] \$ '
        """#
        try bashConfiguration.write(
            to: configURL.appendingPathComponent(".bash_profile"),
            atomically: true,
            encoding: .utf8
        )

        app.launchEnvironment["ZDOTDIR"] = configURL.path
        app.launchEnvironment["HOME"] = configURL.path
        app.launchEnvironment["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        // Environment fallbacks keep the prompt deterministic even if a
        // runner-specific login shell skips its user startup file.
        app.launchEnvironment["PS1"] = "pine@mac \\W $ "
        app.launchEnvironment["PROMPT"] = "pine@mac %1~ %# "
        return configURL
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
