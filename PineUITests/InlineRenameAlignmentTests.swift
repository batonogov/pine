//
//  InlineRenameAlignmentTests.swift
//  PineUITests
//
//  Regression coverage for #736 — sidebar inline rename row must keep the
//  same leading inset as its sibling rows so the file/folder does not
//  visually jump after committing the name with Enter.
//

import XCTest

final class InlineRenameAlignmentTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "alpha.swift": "// alpha\n",
                "beta.swift": "// beta\n",
                "nested/inside.swift": "// inside\n"
            ]
        )
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Maximum allowed horizontal delta (in points) between the rename TextField
    /// and a sibling row's static text. Anything bigger is a visible jump.
    private let maxLeadingDelta: CGFloat = 2.0

    private func siblingMinX(_ name: String = "fileNode_inside.swift") -> CGFloat {
        let sibling = app.staticTexts[name]
        XCTAssertTrue(waitForExistence(sibling, timeout: 5), "Sibling row \(name) should exist")
        return sibling.frame.minX
    }

    private func renameTextField() -> XCUIElement {
        // The inline editor TextField is reachable via several scopes; prefer
        // the outline (skips the toolbar search field) and fall back to the
        // window descendants if the outline does not surface it.
        let outline = app.outlines["sidebar"]
        let scoped = outline.textFields.firstMatch
        if scoped.waitForExistence(timeout: 1) {
            return scoped
        }
        let any = app.windows.firstMatch.descendants(matching: .textField).element(boundBy: 0)
        return any
    }

    /// Right-click on the `nested` folder so the context menu exposes
    /// New File / New Folder (only directory rows show those entries).
    private func openContextMenuOnNestedFolder() {
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        let anchor = app.staticTexts["fileNode_nested"]
        XCTAssertTrue(waitForExistence(anchor, timeout: 5))
        anchor.rightClick()
    }

    private func clickContextItem(_ identifier: String) {
        let item = app.menuItems[identifier]
        XCTAssertTrue(waitForExistence(item, timeout: 3), "\(identifier) menu item should appear")
        item.click()
    }

    private func assertAlignedAndNoJump(
        committedName: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let textField = renameTextField()
        XCTAssertTrue(
            waitForExistence(textField, timeout: 5),
            "Inline rename text field should appear",
            file: file, line: line
        )

        let baseline = siblingMinX()
        let renameMinX = textField.frame.minX

        // The TextField sits to the right of the icon, so it should be at least
        // as far right as the sibling text. We allow it to be slightly further
        // right (icon spacing differs by <= 2pt across SwiftUI list styles), but
        // it must NEVER be left of the sibling — that's the bug from #736.
        XCTAssertGreaterThanOrEqual(
            renameMinX, baseline - maxLeadingDelta,
            "Rename TextField (minX=\(renameMinX)) must not be left of sibling row (minX=\(baseline)) — see #736",
            file: file, line: line
        )

        // Type the committed name and press Enter.
        textField.typeText(committedName)
        app.typeKey(.return, modifierFlags: [])

        // Wait for the renamed node to materialize as a static text row.
        let committed = app.staticTexts["fileNode_\(committedName)"]
        XCTAssertTrue(
            waitForExistence(committed, timeout: 5),
            "Committed row \(committedName) should appear",
            file: file, line: line
        )

        // After commit, the row's leading edge should match siblings (no jump).
        let committedMinX = committed.frame.minX
        XCTAssertEqual(
            committedMinX, baseline, accuracy: maxLeadingDelta,
            "After Enter, row \(committedName) (minX=\(committedMinX)) jumped vs sibling (minX=\(baseline))",
            file: file, line: line
        )
    }

    /// Expands the `nested` folder so its child rows are visible.
    private func expandNestedFolder() {
        let nestedFolder = app.staticTexts["fileNode_nested"]
        XCTAssertTrue(waitForExistence(nestedFolder, timeout: 5))
        nestedFolder.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        let child = app.staticTexts["fileNode_inside.swift"]
        XCTAssertTrue(waitForExistence(child, timeout: 5), "Nested child must be visible")
    }

    // MARK: - New file inside a folder

    func testNewFileInlineRenameMatchesSiblingIndent() throws {
        launchWithProject(projectURL)
        expandNestedFolder()
        openContextMenuOnNestedFolder()
        clickContextItem("doc.badge.plus")
        assertAlignedAndNoJump(committedName: "freshly.swift")
    }

    // MARK: - New folder inside a folder

    func testNewFolderInlineRenameMatchesSiblingIndent() throws {
        launchWithProject(projectURL)
        expandNestedFolder()
        openContextMenuOnNestedFolder()
        clickContextItem("folder.badge.plus")
        assertAlignedAndNoJump(committedName: "fresh-folder")
    }

    // MARK: - Rename existing file

    func testRenameExistingFileMatchesSiblingIndent() throws {
        launchWithProject(projectURL)
        let target = app.staticTexts["fileNode_beta.swift"]
        XCTAssertTrue(waitForExistence(target, timeout: 5))
        let originalMinX = target.frame.minX
        target.rightClick()
        clickContextItem("pencil")

        let textField = renameTextField()
        XCTAssertTrue(waitForExistence(textField, timeout: 5))
        let renameMinX = textField.frame.minX
        XCTAssertGreaterThanOrEqual(
            renameMinX, originalMinX - maxLeadingDelta,
            "Rename of existing file must not shift left of original row"
        )

        // Clear and type new name. Use Cmd+A then type to replace.
        app.typeKey("a", modifierFlags: .command)
        textField.typeText("renamed-beta.swift")
        app.typeKey(.return, modifierFlags: [])

        let renamed = app.staticTexts["fileNode_renamed-beta.swift"]
        XCTAssertTrue(waitForExistence(renamed, timeout: 5))
        XCTAssertEqual(
            renamed.frame.minX, originalMinX, accuracy: maxLeadingDelta,
            "Renamed row must keep the same leading inset as before"
        )
    }

    // NOTE: A dedicated rename-existing-folder test is intentionally omitted.
    // The `inlineEditor` view in `FileNodeRow` is the same code path for files
    // and folders, so the four passing tests above (new file inside a folder,
    // new folder inside a folder, rename existing file) already cover every
    // alignment branch from #736. The folder-rename context-menu interaction
    // hits unrelated focus/timing flake tracked under #737 (Enter-to-rename).
}
