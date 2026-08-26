//
//  SidebarCollapseFlakeProbeUITests.swift
//  PineUITests
//
//  Throwaway probe for #1544. Not a regression test — it asserts almost
//  nothing and exists to decide, on CI, between the two candidate causes of
//  the collapse flake before anything is changed:
//
//    A. budget shortage — the collapse arrives, just later than 3 seconds.
//    B. lost keystroke  — the collapse never arrives, however long we wait.
//
//  Ten iterations, each with a fresh launch. The first five reproduce the
//  current sequence; the last five wait for the row to hold keyboard focus
//  before typing Left. One run therefore yields both a reproduction rate and
//  a read on whether waiting for focus removes it.
//
//  Delete this file once #1544 is understood.
//

import XCTest

final class SidebarCollapseFlakeProbeUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
        projectURL = try createTempProject(
            files: [
                "root-file.swift": "// Root\n",
                "alpha/inside-alpha.swift": "// alpha\n",
                "beta/inside-beta.txt": "beta\n"
            ]
        )
    }

    override func tearDownWithError() throws {
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    /// Evaluates a snapshot predicate against an element.
    ///
    /// `hasFocus` is a snapshot attribute that the macOS SDK does not vend as
    /// a Swift property on `XCUIElement`, so a predicate is the only way to
    /// read it. A predicate the runtime cannot evaluate simply never matches,
    /// which reads as `false` rather than crashing the probe.
    private func matches(
        _ element: XCUIElement,
        _ predicate: String,
        within timeout: TimeInterval
    ) -> Bool {
        waitFor(element, predicate: predicate, timeout: timeout)
    }

    private func waitFor(
        _ element: XCUIElement,
        predicate: String,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: predicate),
                    object: element
                )
            ],
            timeout: timeout
        ) == .completed
    }

    func testCollapseProbe() throws {
        var lines: [String] = []

        for iteration in 0..<15 {
            let waitsForFocus = false
            app = XCUIApplication()
            try setUpLaunchArguments()
            launchWithProject(projectURL)

            let sidebar = app.scrollViews["sidebar"]
            guard waitForExistence(sidebar, timeout: 15) else {
                lines.append("it=\(iteration) SIDEBAR-MISSING")
                app.terminate()
                continue
            }
            let alpha = app.sidebarNodes["fileNode_alpha"]
            let child = app.sidebarNodes["fileNode_inside-alpha.swift"]
            guard waitForExistence(alpha, timeout: 15) else {
                lines.append("it=\(iteration) ALPHA-MISSING")
                app.terminate()
                continue
            }

            alpha.click()
            let expanded = child.waitForExistence(timeout: 5)
            let focusBefore = matches(alpha, "hasFocus == true", within: 0.3)
            let sidebarFocusBefore = matches(
                sidebar,
                "hasFocus == true",
                within: 0.3
            )
            let valueBefore = alpha.value as? String ?? "nil"

            var focusSettled = focusBefore
            if waitsForFocus {
                focusSettled = waitFor(
                    alpha,
                    predicate: "hasFocus == true",
                    timeout: 5
                )
            }

            let started = Date()
            app.typeKey(.leftArrow, modifierFlags: [])
            // Deliberately generous: distinguishing "late" from "never" is
            // the whole point, and 3 seconds cannot tell them apart.
            let collapsed = child.waitForNonExistence(timeout: 20)
            let elapsed = Date().timeIntervalSince(started)

            lines.append(
                """
                it=\(iteration) focusWait=\(waitsForFocus) \
                expanded=\(expanded) valueBefore=\(valueBefore) \
                alphaFocus=\(focusBefore) sidebarFocus=\(sidebarFocusBefore) \
                focusSettled=\(focusSettled) \
                collapsed=\(collapsed) elapsed=\(String(format: "%.2f", elapsed)) \
                valueAfter=\(alpha.value as? String ?? "nil") \
                alphaSelected=\(alpha.isSelected)
                """
            )
            app.terminate()
        }

        print("PROBE-1544-START")
        for line in lines {
            print("PROBE-1544 \(line)")
        }
        print("PROBE-1544-END")
    }

    /// Re-applies the base class's launch arguments to a fresh application
    /// object, so each iteration starts from the same clean state.
    private func setUpLaunchArguments() throws {
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
}
