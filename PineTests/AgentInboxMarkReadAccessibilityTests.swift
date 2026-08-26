//
//  AgentInboxMarkReadAccessibilityTests.swift
//  PineTests
//
//  Whether an Inbox row can be marked read without a right-click (#1533).
//
//  Marking read had exactly two routes. The context menu, which is not in the
//  accessibility tree and needs a pointer to raise. And the envelope button in
//  the recovery panel, which only appears for a task that is recoverable *and*
//  currently expanded — so for an ordinary row there was no route at all.
//
//  The rotor action added here is the route, and this suite invokes it rather
//  than reading it back: an action published with the right name and no wiring
//  is indistinguishable from the outside.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox mark-read accessibility (#1533)", .serialized)
@MainActor
struct AgentInboxMarkReadAccessibilityTests {

    private static let inboxSize = NSSize(width: 520, height: 540)

    @Test("every row offers marking read or unread as a rotor action")
    func everyRowOffersTheAction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hosted = fixture.host()
        defer { hosted.tearDown() }

        let rows = fixture.rows
        #expect(rows.count > 1, "the fixture must cover more than one row")

        for task in rows {
            let element = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: AccessibilityID.agentInboxRow(task.id)
                ),
                "the row for \(task.id) is not in the published tree"
            )
            let offered = AccessibilityTreeProbe.customActionNames(of: element)
            let expected = task.isUnread
                ? Self.markRead
                : Self.markUnread

            #expect(
                offered.contains(expected),
                """
                the row offers \(offered) — marking read is reachable by \
                right-click alone, and a context menu is not in the tree
                """
            )
        }
    }

    /// The name has to follow the row's state, or VoiceOver offers "Mark as
    /// Read" on a row that is already read.
    @Test("the action is named for what it will do to this row")
    func actionNameFollowsRowState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hosted = fixture.host()
        defer { hosted.tearDown() }

        let unread = try #require(fixture.rows.first { $0.isUnread })
        let read = try #require(fixture.rows.first { !$0.isUnread })

        let unreadActions = try Self.actionNames(for: unread.id, in: hosted)
        let readActions = try Self.actionNames(for: read.id, in: hosted)

        #expect(
            unreadActions.contains(Self.markRead),
            "an unread row offers \(unreadActions)"
        )
        #expect(
            !unreadActions.contains(Self.markUnread),
            "an unread row also offers marking it unread again"
        )
        #expect(
            readActions.contains(Self.markUnread),
            "a read row offers \(readActions)"
        )
        #expect(
            !readActions.contains(Self.markRead),
            "a read row also offers marking it read again"
        )
    }

    /// The load-bearing one: perform the action VoiceOver performs and
    /// require the registry to have changed.
    @Test("performing the action marks the task read")
    func performingTheActionMarksItRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hosted = fixture.host()
        defer { hosted.tearDown() }

        let unread = try #require(fixture.rows.first { $0.isUnread })
        let element = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.agentInboxRow(unread.id)
            )
        )

        #expect(
            AccessibilityTreeProbe.performCustomAction(
                named: Self.markRead,
                on: element
            ) == true,
            "the published action is not wired to anything"
        )
        #expect(
            fixture.registry.agentTasks.task(for: unread.id)?.isUnread == false,
            """
            the task is still unread after VoiceOver performed "Mark as Read" \
            on it
            """
        )
    }

    /// And back again, from the row's own state rather than a stored toggle.
    @Test("performing the action on a read task marks it unread")
    func performingTheActionMarksItUnread() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hosted = fixture.host()
        defer { hosted.tearDown() }

        let read = try #require(fixture.rows.first { !$0.isUnread })
        let element = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.agentInboxRow(read.id)
            )
        )

        #expect(
            AccessibilityTreeProbe.performCustomAction(
                named: Self.markUnread,
                on: element
            ) == true
        )
        #expect(
            fixture.registry.agentTasks.task(for: read.id)?.isUnread == true
        )
    }

    // MARK: - Helpers

    /// `Strings.agentInboxMarkRead` is a `LocalizedStringKey`, so SwiftUI
    /// resolves it through the environment locale the probe pins rather than
    /// the process locale. `String(localized:locale:)` cannot express that —
    /// its `locale` only formats interpolations — so the expectation reads
    /// the same `en.lproj` SwiftUI just read. Anything else passes on CI's
    /// English runner and fails on a Russian developer machine.
    private static let markRead = englishValue(forKey: "agentInbox.markRead")
    private static let markUnread = englishValue(
        forKey: "agentInbox.markUnread"
    )

    private static func englishValue(forKey key: String) -> String {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func actionNames(
        for taskID: UUID,
        in hosted: AccessibilityTreeProbe.Hosted
    ) throws -> [String] {
        let element = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.agentInboxRow(taskID)
            )
        )
        return AccessibilityTreeProbe.customActionNames(of: element)
    }

    @MainActor
    private final class Fixture {
        let registry: ProjectRegistry
        private let suiteName: String
        private let defaults: UserDefaults

        init() throws {
            suiteName = "AgentInboxMarkReadAccessibilityTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(),
                agentDetectionProcessRunner: { _, _, _, _ in
                    ProcessRunResult(
                        stdout: "",
                        stderr: "",
                        exitCode: 0,
                        timedOut: false
                    )
                },
                agentDetectionPollInterval: 3_600,
                agentDetectionInitialPollDelay: 3_600
            )
            registry.recentProjects = []
            registry.agentTasks.seedMarketingInboxForUITesting(
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        /// The seeded tasks, which deliberately mix read and unread.
        var rows: [AgentTask] {
            registry.agentTasks.tasks
        }

        func host() -> AccessibilityTreeProbe.Hosted {
            AccessibilityTreeProbe.host(
                AgentInboxView(registry: registry),
                size: AgentInboxMarkReadAccessibilityTests.inboxSize
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
