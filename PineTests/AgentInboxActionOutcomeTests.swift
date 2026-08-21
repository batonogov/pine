//
//  AgentInboxActionOutcomeTests.swift
//  PineTests
//
//  Which Inbox action results close the popover and which keep it open with
//  an actionable status (#1491).
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox action outcome")
struct AgentInboxActionOutcomeTests {
    // MARK: - Navigation

    @Test("a focused route dismisses the popover")
    func focusedRouteDismisses() {
        let route = AgentTaskRoute(
            paneID: UUID(),
            tabID: UUID(),
            terminalID: UUID()
        )

        #expect(
            AgentInboxActionOutcome.forNavigation(.focused(route)) == .dismiss
        )
    }

    @Test("every failed navigation keeps the popover visible")
    func failedNavigationKeepsPopoverVisible() {
        let failures: [AgentInboxNavigationResult] = [
            .taskMissing,
            .projectUnavailable,
            .routeStale,
        ]

        for failure in failures {
            #expect(
                AgentInboxActionOutcome.forNavigation(failure)
                    == .keepVisible(.routeUnavailable),
                "\(failure) must not close the Inbox"
            )
        }
    }

    // MARK: - Status to text

    /// The enum carries the distinction; only this edge makes it visible.
    /// Swapping the two keys inside `AgentInboxView.statusMessage` compiles
    /// and leaves every enum-level assertion above green, so both mappings
    /// are pinned against the exact strings the user reads and hears.
    @MainActor
    @Test("each status maps to its own visible and spoken text")
    func statusesMapToTheirOwnText() {
        #expect(
            AgentInboxView.statusMessage(.routeUnavailable)
                == Strings.agentInboxRouteUnavailable
        )
        #expect(
            AgentInboxView.statusMessage(.recoveryUnavailable)
                == Strings.agentInboxRecoveryUnavailable
        )
        #expect(
            AgentInboxView.statusAnnouncement(
                .routeUnavailable,
                locale: Locale(identifier: "en_US")
            ) == "Exact session is no longer available"
        )
        #expect(
            AgentInboxView.statusAnnouncement(
                .recoveryUnavailable,
                locale: Locale(identifier: "en_US")
            ) == "Safe recovery is unavailable"
        )
    }

    @MainActor
    @Test("the two statuses are never rendered as the same text")
    func statusesAreNotInterchangeable() {
        let locale = Locale(identifier: "en_US")
        #expect(
            AgentInboxView.statusMessage(.routeUnavailable)
                != AgentInboxView.statusMessage(.recoveryUnavailable)
        )
        #expect(
            AgentInboxView.statusAnnouncement(.routeUnavailable, locale: locale)
                != AgentInboxView.statusAnnouncement(
                    .recoveryUnavailable,
                    locale: locale
                )
        )
    }

    @MainActor
    @Test("every status resolves to real spoken text, not a catalog key")
    func everyStatusHasResolvedSpokenText() {
        let locale = Locale(identifier: "en_US")
        for status: AgentInboxActionStatus in [
            .routeUnavailable,
            .recoveryUnavailable,
        ] {
            let spoken = AgentInboxView.statusAnnouncement(
                status,
                locale: locale
            )
            // A screen-reader user gets no other signal: focus stays in the
            // popover and only an 11-point caption changes. An unresolved
            // key would be announced verbatim.
            #expect(!spoken.isEmpty, "\(status) must have a spoken form")
            #expect(
                !spoken.hasPrefix("agentInbox."),
                "\(status) announced its catalog key instead of its text"
            )
        }
    }

    // MARK: - Recovery

    @Test("a started or resumed session dismisses the popover")
    func successfulRecoveryDismisses() {
        let successes: [AgentInboxRecoveryResult] = [
            .openedNewSession(terminalID: UUID()),
            .resumed(terminalID: UUID()),
        ]

        for success in successes {
            #expect(
                AgentInboxActionOutcome.forRecovery(success) == .dismiss,
                "\(success) must close the Inbox"
            )
        }
    }

    @Test("every failed recovery keeps the popover visible")
    func failedRecoveryKeepsPopoverVisible() {
        let failures: [AgentInboxRecoveryResult] = [
            .taskMissing,
            .projectUnavailable,
            .unavailable(.taskNotRecoverable),
            .unavailable(.projectMissing),
            .unavailable(.worktreeMissing),
            .unavailable(.executableMissing),
            .unavailable(.adapterUnavailable),
            .unavailable(.vendorIdentityMissing),
            .unavailable(.vendorIdentityInvalid),
            .unavailable(.versionProbeFailed),
            .unavailable(.versionChanged),
            .changedWhilePreparing,
            .launchRejected,
        ]

        for failure in failures {
            #expect(
                AgentInboxActionOutcome.forRecovery(failure)
                    == .keepVisible(.recoveryUnavailable),
                "\(failure) must not close the Inbox"
            )
        }
    }

    // MARK: - What the popover does about a verdict

    /// `apply(_:)` is three conditional statements over data nothing else
    /// reads. Swapping the two verdicts, adding a dismiss to the failure
    /// branch, or deleting the announcement all compile, render identically,
    /// and leave every mapping assertion above green.
    @MainActor
    @Test("a reached session closes the popover and says nothing")
    func dismissEffectsCloseSilently() {
        #expect(
            AgentInboxView.effects(of: .dismiss) == AgentInboxView
                .ActionEffects(
                    dismisses: true,
                    statusMessage: nil,
                    announcement: nil
                )
        )
    }

    @MainActor
    @Test("a failure keeps the popover open, captioned and spoken")
    func keepVisibleEffectsStayOpenAndSpeak() {
        let locale = Locale(identifier: "en_US")

        for status: AgentInboxActionStatus in [
            .routeUnavailable,
            .recoveryUnavailable,
        ] {
            let effects = AgentInboxView.effects(
                of: .keepVisible(status),
                locale: locale
            )

            #expect(
                !effects.dismisses,
                "\(status) must not close the Inbox"
            )
            #expect(
                effects.statusMessage
                    == AgentInboxView.statusMessage(status)
            )
            #expect(
                effects.announcement == AgentInboxView.statusAnnouncement(
                    status,
                    locale: locale
                ),
                "\(status) must be spoken, not only shown"
            )
        }
    }

    @MainActor
    @Test("a failure runs the caption and the announcement, and no dismiss")
    func failureEffectsAreAppliedWithoutDismissing() {
        var messages: [LocalizedStringKey] = []
        var announcements: [String] = []
        var dismissals = 0

        AgentInboxView.applyEffects(
            AgentInboxView.effects(
                of: .keepVisible(.routeUnavailable),
                locale: Locale(identifier: "en_US")
            ),
            setStatusMessage: { messages.append($0) },
            announce: { announcements.append($0) },
            dismiss: { dismissals += 1 }
        )

        #expect(messages == [Strings.agentInboxRouteUnavailable])
        #expect(announcements == ["Exact session is no longer available"])
        #expect(dismissals == 0)
    }

    @MainActor
    @Test("a success dismisses without captioning or announcing anything")
    func successEffectsOnlyDismiss() {
        var messages: [LocalizedStringKey] = []
        var announcements: [String] = []
        var dismissals = 0

        AgentInboxView.applyEffects(
            AgentInboxView.effects(of: .dismiss),
            setStatusMessage: { messages.append($0) },
            announce: { announcements.append($0) },
            dismiss: { dismissals += 1 }
        )

        #expect(messages.isEmpty)
        #expect(announcements.isEmpty)
        #expect(dismissals == 1)
    }

    // MARK: - Which of the view's own hooks each effect reaches

    /// The last untested step. `effects(of:)` and `applyEffects(...)` are
    /// pinned above, but nothing observes the wiring between them and the
    /// view's own hooks. Handing the caption or the announcement to a no-op
    /// leaves every assertion above green while removing the only two signals
    /// a user gets when a route is dead: an 11-point caption at the bottom
    /// edge of a popover that never takes focus, and what VoiceOver says.
    ///
    /// The caption is asserted as a key, not as rendered text:
    /// `@Environment(\.locale)` on a view that is not installed resolves to
    /// the process locale, so the exact wording is pinned by the
    /// locale-explicit tests above and this one asserts that each effect
    /// reached the hook it belongs to.
    @MainActor
    @Test("the view captions, speaks, and keeps the popover open on failure")
    func viewWiresFailureToItsOwnHooks() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        var announcements: [String] = []
        var dismissals = 0
        let view = AgentInboxView(
            registry: fixture.registry,
            onDismiss: { dismissals += 1 },
            onAccessibilityAnnouncement: { announcements.append($0) }
        )

        view.apply(.keepVisible(.routeUnavailable))

        // The caption is the visible half of "keeps the popover visible with
        // an actionable status", and it is written to the view's own storage
        // — the one hook a test can otherwise not see reaching anything.
        #expect(
            view.actionStatus.message == Strings.agentInboxRouteUnavailable,
            "a dead route must caption the popover it leaves open"
        )
        #expect(
            announcements.count == 1,
            "a dead route must be spoken exactly once"
        )
        #expect(
            announcements.first?.isEmpty == false,
            "the announcement must carry real text"
        )
        #expect(dismissals == 0, "a failure must never close the Inbox")
    }

    /// The two failures are not interchangeable at this seam either: the view
    /// must caption itself with the status it was handed, not with a constant.
    @MainActor
    @Test("the view captions a failed recovery with the recovery status")
    func viewWiresRecoveryFailureToItsOwnCaption() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let view = AgentInboxView(registry: fixture.registry)

        view.apply(.keepVisible(.recoveryUnavailable))

        #expect(
            view.actionStatus.message == Strings.agentInboxRecoveryUnavailable
        )
    }

    @MainActor
    @Test("the view closes on success without captioning or announcing")
    func viewWiresSuccessToItsDismissal() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        var announcements: [String] = []
        var dismissals = 0
        let view = AgentInboxView(
            registry: fixture.registry,
            onDismiss: { dismissals += 1 },
            onAccessibilityAnnouncement: { announcements.append($0) }
        )

        view.apply(.dismiss)

        #expect(dismissals == 1, "reaching the session must close the Inbox")
        #expect(
            announcements.isEmpty,
            "success needs no announcement: the user was just moved there"
        )
        #expect(
            view.actionStatus.message == nil,
            "success must leave no failure caption behind"
        )
    }

    // MARK: - Fixture

    /// An isolated registry for the view seam.
    ///
    /// `ProjectRegistry()` otherwise reads and writes `UserDefaults.standard`
    /// and starts the real `ps`-polling agent detector — neither of which this
    /// suite is about, and both of which leak between runs.
    @MainActor
    private final class RegistryFixture {
        let registry: ProjectRegistry
        private let suiteName: String
        private let defaults: UserDefaults

        init() throws {
            suiteName = "AgentInboxActionOutcomeTests.\(UUID().uuidString)"
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
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
