//
//  QuickTerminalContentHostedTests.swift
//  PineTests
//
//  Hosted accessibility and renderer wiring smoke for issue #1420.
//

import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
@testable import Pine

@Suite("Quick Terminal hosted content (#1420)", .serialized)
@MainActor
struct QuickTerminalContentHostedTests {
    @Test("Hosted content exposes agent identity and attaches terminal container")
    func hostedAgentBadgeAndTerminalAttachment() throws {
        let paneState = TerminalPaneState()
        paneState.addTab(workingDirectory: nil)
        let tab = try #require(paneState.activeTab)
        defer { tab.stop() }
        let session = AgentSession(
            agentType: .codex,
            startedAt: Date(timeIntervalSince1970: 9_000)
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 9_001,
            processGeneration: 1,
            startIdentifier: "quick-hosted-generation",
            observedStartedAt: Date(timeIntervalSince1970: 9_000),
            startIsAuthoritative: true
        ))
        tab.agentSession = session

        let hosted = NSHostingView(
            rootView: QuickTerminalContentView(paneState: paneState)
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 800, height: 320)
        let window = NSWindow(
            contentRect: hosted.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosted
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hosted.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        hosted.layoutSubtreeIfNeeded()

        let container = try #require(findTerminalContainer(in: hosted))
        #expect(container.terminalPaneState === paneState)
        #expect(paneState.presentationOwner === container)
        #expect(tab.presentationOwner === container)
        #expect(tab.terminalView.superview === container)
        #expect(container.window === window)
        #expect(
            tab.terminalView.accessibilityIdentifier()
                == AccessibilityID.terminalSurface
        )

        #expect(
            AccessibilityID.quickTerminalContent == "quickTerminalContent"
        )
        #expect(
            AccessibilityID.quickTerminalAgentIdentity
                == "quickTerminalAgentIdentity"
        )
        let identityLabel = QuickTerminalContentView
            .agentIdentityAccessibilityLabel(for: tab)
        #expect(identityLabel.contains(tab.name))
        #expect(identityLabel.contains("Codex"))
        #expect(identityLabel.contains(
            AgentTabBadge.userFacingState(for: session).displayName
        ))
        #expect(hosted.fittingSize.height > 0)

        let forcedCoreGraphics = ProcessInfo.processInfo.environment[
            "PINE_DISABLE_METAL"
        ] != nil
        #expect(
            PineTerminalView.isMetalExplicitlyDisabled == forcedCoreGraphics
        )
        if forcedCoreGraphics,
           let terminalView = tab.terminalView as? PineTerminalView {
            #expect(!terminalView.isUsingMetalRenderer)
        }
    }

    private func findTerminalContainer(in view: NSView) -> TerminalContainerView? {
        if let container = view as? TerminalContainerView { return container }
        for subview in view.subviews {
            if let match = findTerminalContainer(in: subview) { return match }
        }
        return nil
    }

    private func drainMainRunLoop() {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
