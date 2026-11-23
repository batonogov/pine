import XCTest

final class OpenCodeTaskUITests: PineUITestCase {
    func testRequestSheetOpensWithoutLaunchingAnAgent() throws {
        let project = try createTempProject()
        defer { cleanupProject(project) }
        launchWithProject(project)

        let button = app.buttons["openCodeTaskToolbarButton"].firstMatch
        XCTAssertTrue(waitForExistence(button, timeout: 10))
        button.click()

        let input = app.textViews["openCodeTaskInput"].firstMatch
        let send = app.buttons["openCodeTaskSend"].firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 5))
        XCTAssertTrue(waitForExistence(send, timeout: 5))
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(app.buttons["openCodeTaskCancel"].exists)
    }
}
