//
//  TerminalProcessConfirmationTests.swift
//  PineTests
//
//  Tests for the shared terminal foreground-process confirmation logic
//  in TabCloseHelper (issue #970).
//

import Testing
import AppKit
@testable import Pine

/// Tests for `TabCloseHelper.confirmTerminalStop` and
/// `TabCloseHelper.confirmTerminalProcessStop` — the shared decision logic
/// that guards every path that stops or removes terminal tabs.
@Suite("Terminal Process Confirmation")
@MainActor
struct TerminalProcessConfirmationTests {

    // MARK: - confirmTerminalStop (pure decision function)

    @Test func noForegroundProcess_doesNotPresentAlert_proceedsImmediately() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: false,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    @Test func foregroundProcess_userConfirms_proceeds() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: true,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn // "Close Terminal"
            }
        )
        #expect(result == true)
        #expect(alertCalled == true)
    }

    @Test func foregroundProcess_userCancels_aborts() async {
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: true,
            presentAlert: { .alertSecondButtonReturn } // "Cancel"
        )
        #expect(result == false)
    }

    // MARK: - confirmTerminalProcessStop (tabs-based convenience)

    @Test func emptyTabs_proceedsImmediately() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [],
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    @Test func tabsWithoutForegroundProcess_proceedsImmediately() async {
        // Newly created TerminalTabs have hasForegroundProcess == false
        // because no process has been started. We use this to verify the
        // no-warning fast path with real tab objects.
        let tab = TerminalTab(name: "Test Terminal")
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [tab],
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    // MARK: - Default alert (production path)

    @Test func defaultAlertIsUsedWhenNoInjectionProvided() async {
        // Verify the default parameter compiles and runs without crashing.
        // We can't meaningfully test the modal result in a headless test
        // (it would present a real NSAlert), so we only verify the no-process
        // fast path which never calls the alert.
        let result = await TabCloseHelper.confirmTerminalStop(hasForegroundProcess: false)
        #expect(result == true)
    }

    @Test func defaultAlertIsUsedForTabsOverload_noProcess() async {
        let tab = TerminalTab(name: "Idle Terminal")
        let result = await TabCloseHelper.confirmTerminalProcessStop(tabs: [tab])
        #expect(result == true)
    }

    // MARK: - Multiple tabs aggregation

    @Test func multipleTabs_allIdle_proceedsImmediately() async {
        let tabs = (0..<5).map { TerminalTab(name: "Terminal \($0)") }
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: tabs,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }
}
