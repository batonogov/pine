//
//  ProjectDialogOwnerReadinessTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@Suite("Project Dialog Owner Readiness Tests")
@MainActor
struct ProjectDialogOwnerReadinessTests {
    @Test func delayedOwnerBindingIsObservedWithoutFixedDelay() async {
        let projectManager = ProjectManager()
        let window = NSWindow()
        var waitCount = 0

        let resolved = await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: 6,
            waitForNextAttempt: {
                waitCount += 1
                if waitCount == 3 {
                    projectManager.bindDialogOwnerWindow(window)
                }
                await Task.yield()
            },
            isEligible: { _ in true }
        )

        #expect(resolved === window)
        #expect(waitCount == 3)
    }

    @Test func missingOwnerStopsAtBound() async {
        let projectManager = ProjectManager()
        var waitCount = 0

        let resolved = await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: 3,
            waitForNextAttempt: {
                waitCount += 1
                await Task.yield()
            },
            isEligible: { _ in true }
        )

        #expect(resolved == nil)
        #expect(waitCount == 3)
    }

    @Test func cancelledWaitStopsBeforePolling() async {
        let projectManager = ProjectManager()
        var waitCount = 0
        let task = Task { @MainActor in
            await projectManager.awaitDialogOwnerWindow(
                maximumAttempts: 10,
                waitForNextAttempt: {
                    waitCount += 1
                    await Task.yield()
                },
                isEligible: { _ in true }
            )
        }

        task.cancel()
        let resolved = await task.value

        #expect(resolved == nil)
        #expect(waitCount == 0)
    }

    @Test func lostOwnerIsRecoveredBeforeWaiting() async {
        let projectManager = ProjectManager()
        let window = NSWindow()
        var recoveryCount = 0
        var waitCount = 0

        let resolved = await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: 3,
            waitForNextAttempt: {
                waitCount += 1
                await Task.yield()
            },
            isEligible: { _ in true },
            recoverOwner: {
                recoveryCount += 1
                projectManager.bindDialogOwnerWindow(window)
                return window
            }
        )

        #expect(resolved === window)
        #expect(recoveryCount == 1)
        #expect(waitCount == 0)
    }

    @Test func ineligibleBoundOwnerIsReplacedByRecoveredOwner() async {
        let projectManager = ProjectManager()
        let staleWindow = NSWindow()
        let recoveredWindow = NSWindow()
        var recoveryCount = 0
        var waitCount = 0
        projectManager.bindDialogOwnerWindow(staleWindow)

        let resolved = await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: 3,
            waitForNextAttempt: {
                waitCount += 1
                await Task.yield()
            },
            isEligible: { $0 === recoveredWindow },
            recoverOwner: {
                recoveryCount += 1
                projectManager.bindDialogOwnerWindow(recoveredWindow)
                return recoveredWindow
            }
        )

        #expect(resolved === recoveredWindow)
        #expect(projectManager.dialogOwnerWindow === recoveredWindow)
        #expect(recoveryCount == 1)
        #expect(waitCount == 0)
    }
}
