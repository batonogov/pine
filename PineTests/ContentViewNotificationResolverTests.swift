//
//  ContentViewNotificationResolverTests.swift
//  PineTests
//
//  Regression coverage for the ContentView notification extraction in #1133.
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct ContentViewNotificationResolverTests {

    // MARK: - Reveal in sidebar

    @Test("Reveal-in-sidebar resolver preserves a URL payload")
    func revealInSidebarPreservesURL() {
        let expectedURL = URL(fileURLWithPath: "/tmp/pine/sidebar.swift")
        let notification = Notification(
            name: .revealInSidebar,
            userInfo: ["url": expectedURL]
        )

        let resolved = ContentView.resolveRevealInSidebarURL(from: notification)

        #expect(resolved == expectedURL)
    }

    @Test("Reveal-in-sidebar resolver rejects missing and incorrectly typed payloads")
    func revealInSidebarRejectsInvalidPayloads() {
        let notifications = [
            Notification(name: .revealInSidebar),
            Notification(name: .revealInSidebar, userInfo: [:]),
            Notification(name: .revealInSidebar, userInfo: ["url": NSNull()]),
            Notification(name: .revealInSidebar, userInfo: ["url": 1]),
            Notification(name: .revealInSidebar, userInfo: ["url": "/tmp/pine/sidebar.swift"])
        ]

        for notification in notifications {
            #expect(ContentView.resolveRevealInSidebarURL(from: notification) == nil)
        }
    }

    // MARK: - Send text to terminal

    @Test("Terminal-text resolver preserves non-empty text, including whitespace")
    func terminalTextPreservesNonEmptyText() {
        let payloads = ["echo pine", " ", "\n", "  padded  "]

        for payload in payloads {
            let notification = Notification(
                name: .sendTextToTerminal,
                userInfo: ["text": payload]
            )

            let resolved = ContentView.resolveTerminalText(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == payload)
        }
    }

    @Test("Terminal-text resolver rejects an empty string")
    func terminalTextRejectsEmptyString() {
        let notification = Notification(
            name: .sendTextToTerminal,
            userInfo: ["text": ""]
        )

        let resolved = ContentView.resolveTerminalText(
            from: notification,
            isKeyWindow: true
        )

        #expect(resolved == nil)
    }

    @Test("Terminal-text resolver rejects missing and incorrectly typed payloads")
    func terminalTextRejectsInvalidPayloads() {
        let notifications = [
            Notification(name: .sendTextToTerminal),
            Notification(name: .sendTextToTerminal, userInfo: [:]),
            Notification(name: .sendTextToTerminal, userInfo: ["text": NSNull()]),
            Notification(name: .sendTextToTerminal, userInfo: ["text": 1]),
            Notification(name: .sendTextToTerminal, userInfo: ["text": Data()])
        ]

        for notification in notifications {
            let resolved = ContentView.resolveTerminalText(
                from: notification,
                isKeyWindow: true
            )

            #expect(resolved == nil)
        }
    }

    @Test("Terminal-text resolver ignores notifications for non-key windows")
    func terminalTextRequiresKeyWindow() {
        let notification = Notification(
            name: .sendTextToTerminal,
            userInfo: ["text": "echo pine"]
        )

        let resolved = ContentView.resolveTerminalText(
            from: notification,
            isKeyWindow: false
        )

        #expect(resolved == nil)
    }
}
