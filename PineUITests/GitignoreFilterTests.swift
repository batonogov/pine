//
//  GitignoreFilterTests.swift
//  PineUITests
//
//  UI tests verifying that gitignored directories are hidden from the sidebar
//  while gitignored files remain visible.
//

import XCTest

final class GitignoreFilterTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create a git repo with .gitignore, a normal file,
        // a gitignored directory, and a gitignored file.
        projectURL = try createTempProject(files: [
            "main.swift": "// Hello\n",
            ".gitignore": "node_modules/\n.env\n",
            "node_modules/express/index.js": "module.exports = {};\n",
            ".env": "SECRET=123\n"
        ])

        // Initialize git so gitProvider picks up .gitignore
        try git("init", at: projectURL)
        try git("config", "user.email", "test@test.com", at: projectURL)
        try git("config", "user.name", "Test", at: projectURL)
        try git("add", ".", at: projectURL)
        try git("commit", "-m", "init", at: projectURL)
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Path to git binary, bypassing the xcrun shim which fails in App Sandbox.
    private let gitPath = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

    @discardableResult
    private func git(_ arguments: String..., at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = Array(arguments)
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tests

    func testGitignoredDirectoryHiddenFromSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // main.swift should be visible
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(
            waitForExistence(mainFile, timeout: 5),
            "main.swift should appear in sidebar"
        )

        // node_modules directory should NOT be visible (gitignored directory)
        let nodeModules = app.staticTexts["fileNode_node_modules"]
        XCTAssertFalse(
            nodeModules.waitForExistence(timeout: 2),
            "node_modules should be hidden from sidebar (gitignored directory)"
        )
    }

    func testGitignoredFileRemainsInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .env should be visible (gitignored file, not directory)
        let envFile = app.staticTexts["fileNode_.env"]
        XCTAssertTrue(
            waitForExistence(envFile, timeout: 5),
            ".env should remain visible in sidebar (gitignored files are kept)"
        )
    }

    func testNonIgnoredDirectoryRemainsInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .gitignore should be visible
        let gitignore = app.staticTexts["fileNode_.gitignore"]
        XCTAssertTrue(
            waitForExistence(gitignore, timeout: 5),
            ".gitignore should appear in sidebar"
        )
    }
}
