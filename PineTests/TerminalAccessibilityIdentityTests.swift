//
//  TerminalAccessibilityIdentityTests.swift
//  PineTests
//
//  What a terminal is called, on both surfaces that show one (#1533).
//
//  Two defects, one cause. The terminal view carried a role and an identifier
//  but no name, so VoiceOver announced every terminal in the window as "text
//  area". And the project tab bar's `accessibilityRepresentation` replaced the
//  whole tab with `Button(tab.name)`, which threw away the agent badge — the
//  amber marker that says an agent is blocked waiting for input. Quick
//  Terminal announced it correctly the whole time; the two surfaces had
//  drifted apart.
//

import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import Pine

@Suite("Terminal accessibility identity (#1533)", .serialized)
@MainActor
struct TerminalAccessibilityIdentityTests {

    // MARK: - The surface has a name

    @Test("the terminal surface publishes a name, not just a role")
    func terminalSurfaceIsNamed() throws {
        let tab = TerminalTab(name: "Terminal 1")
        defer { tab.stop() }

        #expect(
            tab.terminalView.accessibilityRole() == .textArea,
            "the pre-existing role must survive"
        )
        #expect(
            tab.terminalView.accessibilityIdentifier()
                == AccessibilityID.terminalSurface
        )
        #expect(
            tab.terminalView.accessibilityLabel() == "Terminal 1",
            """
            the terminal surface announces \
            \(String(describing: tab.terminalView.accessibilityLabel())) — \
            with no name, every terminal in a split window is "text area"
            """
        )
    }

    /// The name is read at query time, so a shell that renames its tab
    /// through OSC is heard. A label pushed once at construction is not.
    @Test("a renamed terminal announces its new name without being re-pushed")
    func terminalSurfaceNameFollowsTheShell() throws {
        let tab = TerminalTab(name: "Terminal 1")
        defer { tab.stop() }

        tab.name = "~/pine — vim"

        #expect(
            tab.terminalView.accessibilityLabel() == "~/pine — vim",
            "the surface is still announcing the name it was born with"
        )
    }

    /// The same for an agent attached after the terminal already existed,
    /// which is the only way agent detection ever attaches one.
    @Test("an agent detected later is announced by the terminal surface")
    func terminalSurfaceNameFollowsAgentDetection() throws {
        let tab = TerminalTab(name: "Terminal 2")
        defer { tab.stop() }
        let session = Self.session(agentType: .claudeCode)

        tab.agentSession = session

        let announced = try #require(tab.terminalView.accessibilityLabel())
        #expect(announced.contains("Terminal 2"))
        #expect(announced.contains(session.agentType.displayName))
        #expect(
            announced.contains(
                AgentTabBadge.userFacingState(for: session).displayName
            ),
            "the surface announces \"\(announced)\" without the agent's state"
        )
    }

    // MARK: - The tab bar keeps the badge

    /// The regression: the project tab bar's accessibility representation
    /// overwrote the label with the bare tab name.
    @Test("the project tab bar announces the agent badge it draws")
    func projectTabAnnouncesTheAgentBadge() throws {
        let tab = TerminalTab(name: "Terminal 3")
        defer { tab.stop() }
        let session = Self.session(agentType: .codex)
        tab.agentSession = session

        let hosted = AccessibilityTreeProbe.host(
            TerminalNativeTabItem(
                tab: tab,
                isActive: true,
                canClose: true,
                onSelect: {},
                onClose: {}
            ),
            size: NSSize(width: 220, height: 28)
        )
        defer { hosted.tearDown() }

        let element = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.terminalTab(tab.stableLabel)
            ),
            "the terminal tab is not in the published tree"
        )
        let announced = try #require(
            AccessibilityTreeProbe.label(of: element)
        )

        #expect(announced.contains("Terminal 3"))
        #expect(
            announced.contains(session.agentType.displayName),
            """
            the tab announces "\(announced)". The badge beside the name is the \
            only signal that an agent is running in this terminal, and \
            `accessibilityRepresentation` replaced the label that carried it.
            """
        )
        #expect(
            announced.contains(
                AgentTabBadge.userFacingState(for: session).displayName
            )
        )
    }

    /// Both surfaces have to agree. This is the assertion that fails if one
    /// of them is changed alone.
    @Test("Quick Terminal and the project tab bar speak the same identity")
    func bothSurfacesShareOneIdentity() throws {
        let tab = TerminalTab(name: "Terminal 4")
        defer { tab.stop() }
        tab.agentSession = Self.session(agentType: .gemini)

        #expect(
            QuickTerminalContentView.agentIdentityAccessibilityLabel(for: tab)
                == TerminalTabIdentityLabel.accessibilityLabel(for: tab)
        )
        #expect(
            tab.terminalView.accessibilityLabel()
                == TerminalTabIdentityLabel.accessibilityLabel(for: tab)
        )
    }

    /// A terminal with no agent must not be announced with trailing commas
    /// where the badge would have been — VoiceOver reads punctuation aloud.
    @Test("a terminal with no agent is announced as its name alone")
    func plainTerminalIsAnnouncedPlainly() throws {
        let tab = TerminalTab(name: "Terminal 5")
        defer { tab.stop() }

        #expect(
            TerminalTabIdentityLabel.accessibilityLabel(for: tab)
                == "Terminal 5"
        )
    }

    // MARK: - Fixture

    private static func session(agentType: AgentType) -> AgentSession {
        let session = AgentSession(
            agentType: agentType,
            startedAt: Date(timeIntervalSince1970: 5_000)
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 5_001,
            processGeneration: 1,
            startIdentifier: "terminal-identity-fixture",
            observedStartedAt: Date(timeIntervalSince1970: 5_000),
            startIsAuthoritative: true
        ))
        return session
    }
}
