//
//  GitAndNotificationObserverTests.swift
//  PineTests
//
//  Regression coverage for the notification resolver extraction in #1133.
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct GitAndNotificationObserverTests {

    // MARK: - Navigate change

    @Test("Navigate-change resolver maps the supported direction strings")
    func navigateChangeMapsSupportedDirections() {
        let cases: [(payload: String, expected: ContentView.ChangeDirection)] = [
            (payload: "next", expected: .next),
            (payload: "previous", expected: .previous)
        ]

        for testCase in cases {
            let notification = Notification(
                name: .navigateChange,
                userInfo: ["direction": testCase.payload]
            )
            let resolved = GitAndNotificationObserver.resolveChangeDirection(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == testCase.expected)
        }
    }

    @Test("Navigate-change resolver preserves the previous fallback for other strings")
    func navigateChangePreservesPreviousFallback() {
        let fallbackPayloads = ["", "NEXT", "next ", "unexpected"]

        for payload in fallbackPayloads {
            let notification = Notification(
                name: .navigateChange,
                userInfo: ["direction": payload]
            )
            let resolved = GitAndNotificationObserver.resolveChangeDirection(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == .previous)
        }
    }

    @Test("Navigate-change resolver rejects missing and non-string payloads")
    func navigateChangeRejectsInvalidPayloads() {
        let notifications = [
            Notification(name: .navigateChange),
            Notification(name: .navigateChange, userInfo: [:]),
            Notification(name: .navigateChange, userInfo: ["direction": NSNull()]),
            Notification(name: .navigateChange, userInfo: ["direction": 1]),
            Notification(name: .navigateChange, userInfo: ["direction": InlineDiffAction.accept])
        ]

        for notification in notifications {
            let resolved = GitAndNotificationObserver.resolveChangeDirection(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == nil)
        }
    }

    @Test("Navigate-change resolver ignores notifications for non-key windows")
    func navigateChangeRequiresKeyWindow() {
        let notification = Notification(
            name: .navigateChange,
            userInfo: ["direction": "next"]
        )

        let resolved = GitAndNotificationObserver.resolveChangeDirection(
            from: notification,
            isKeyWindow: false
        )

        #expect(resolved == nil)
    }

    // MARK: - Inline diff action

    @Test("Inline-diff resolver preserves every typed action")
    func inlineDiffPreservesTypedActions() {
        let actions: [InlineDiffAction] = [.accept, .revert, .acceptAll, .revertAll]

        for action in actions {
            let notification = Notification(
                name: .inlineDiffAction,
                userInfo: ["action": action]
            )
            let resolved = GitAndNotificationObserver.resolveInlineDiffAction(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved?.rawValue == action.rawValue)
        }
    }

    @Test("Inline-diff resolver rejects missing and incorrectly typed payloads")
    func inlineDiffRejectsInvalidPayloads() {
        let notifications = [
            Notification(name: .inlineDiffAction),
            Notification(name: .inlineDiffAction, userInfo: [:]),
            Notification(name: .inlineDiffAction, userInfo: ["action": NSNull()]),
            Notification(name: .inlineDiffAction, userInfo: ["action": 1]),
            Notification(name: .inlineDiffAction, userInfo: ["action": "accept"])
        ]

        for notification in notifications {
            let resolved = GitAndNotificationObserver.resolveInlineDiffAction(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == nil)
        }
    }

    @Test("Inline-diff resolver ignores notifications for non-key windows")
    func inlineDiffRequiresKeyWindow() {
        let notification = Notification(
            name: .inlineDiffAction,
            userInfo: ["action": InlineDiffAction.accept]
        )

        let resolved = GitAndNotificationObserver.resolveInlineDiffAction(
            from: notification,
            isKeyWindow: false
        )

        #expect(resolved == nil)
    }
}
