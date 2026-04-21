//
//  HCLFormatOnSaveTests.swift
//  PineUITests
//
//  UI tests for HCL/Terraform format-on-save.
//  Verifies the app does not crash when saving .tf files
//  with terraform/tofu installed (issue: precondition failure
//  in RealProcessRunner on main thread).
//

import XCTest

final class HCLFormatOnSaveTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Write formatOnSave as a proper boolean into UserDefaults.
        // Launch arguments store values as strings, and EditorSettings
        // reads with `object(forKey:) as? Bool` which returns nil for strings.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["write", "io.github.batonogov.pine", "editor.formatOnSave", "-bool", "YES"]
        proc.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        try proc.run()
        proc.waitUntilExit()

        projectURL = try createTempProject(files: [
            "main.tf": "resource \"aws_instance\" \"example\" {\n  ami           = \"ami-12345\"\n  instance_type = \"t2.micro\"\n}\n"
        ])
    }

    override func tearDownWithError() throws {
        // Restore formatOnSave to its default (off)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["delete", "io.github.batonogov.pine", "editor.formatOnSave"]
        proc.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        try? proc.run()
        proc.waitUntilExit()

        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Save .tf file does not crash

    func testSaveTerraformFileWithFormatOnSaveDoesNotCrash() throws {
        // Skip if neither terraform nor tofu is installed
        let hasTerraform = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/terraform")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/terraform")
        let hasTofu = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tofu")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tofu")
        try XCTSkipUnless(hasTerraform || hasTofu, "terraform or tofu must be installed")

        launchWithProject(projectURL)

        openFile("main.tf")

        // Save via File menu — this triggers format-on-save for .tf
        app.activate()
        clickMenuBarItem("File")

        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(
            waitForExistence(saveItem, timeout: 3),
            "Save menu item should exist"
        )
        saveItem.click()

        // If the app crashed (precondition failure on main thread),
        // the window will disappear. Verify the app is still alive.
        let tab = editorTab("main.tf")
        XCTAssertTrue(
            waitForExistence(tab, timeout: 5),
            "App should still be running after saving .tf file — editor tab must exist"
        )

        // Verify the file was actually written to disk
        let content = try String(contentsOf: projectURL.appendingPathComponent("main.tf"), encoding: .utf8)
        XCTAssertFalse(content.isEmpty, "Saved file should not be empty")
    }
}
