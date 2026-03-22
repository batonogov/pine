//
//  LineNumberGutterUITests.swift
//  PineUITests
//
//  Tests that the line number gutter appears alongside the code editor.
//

import XCTest

final class LineNumberGutterUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let a = 1\nlet b = 2\nlet c = 3\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// Line number gutter should appear when a file is opened in the editor.
    func testGutterAppearsWhenFileOpened() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(waitForExistence(editor, timeout: 5), "Code editor should appear")

        let gutter = app.descendants(matching: .any)["lineNumberGutter"].firstMatch
        XCTAssertTrue(waitForExistence(gutter, timeout: 5), "Line number gutter should appear")
    }

    /// Line number gutter should be positioned to the left of the code editor.
    func testGutterIsLeftOfEditor() throws {
        launchWithProject(projectURL)

        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(waitForExistence(editor, timeout: 5), "Code editor should appear")

        let gutter = app.descendants(matching: .any)["lineNumberGutter"].firstMatch
        XCTAssertTrue(waitForExistence(gutter, timeout: 5), "Line number gutter should appear")

        // Gutter's left edge should be at or before editor's left edge
        XCTAssertLessThanOrEqual(
            gutter.frame.minX, editor.frame.minX,
            "Gutter should be positioned at or to the left of the editor"
        )
    }

    /// Line number gutter should have the same vertical position as the code editor.
    func testGutterVerticallyAlignedWithEditor() throws {
        launchWithProject(projectURL)

        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(waitForExistence(editor, timeout: 5), "Code editor should appear")

        let gutter = app.descendants(matching: .any)["lineNumberGutter"].firstMatch
        XCTAssertTrue(waitForExistence(gutter, timeout: 5), "Line number gutter should appear")

        // Gutter and editor should share the same top Y position (within tolerance)
        XCTAssertEqual(
            gutter.frame.minY, editor.frame.minY,
            accuracy: 2,
            "Gutter should be vertically aligned with the editor"
        )
    }
}
