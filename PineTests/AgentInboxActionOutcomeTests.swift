//
//  AgentInboxActionOutcomeTests.swift
//  PineTests
//
//  Which Inbox action results close the popover and which keep it open with
//  an actionable status (#1491), and — for every distinguishable failure —
//  what the popover then says happened and what to do about it (#1541).
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox action outcome")
struct AgentInboxActionOutcomeTests {
    /// Every failure the Inbox can report, paired with the result that
    /// produces it. Kept as one table because the whole point of #1541 is
    /// that these do not collapse into each other: an entry lost here is a
    /// cause that silently starts sharing another one's sentence.
    private static let failuresByResult:
        [(result: AgentInboxRecoveryResult, failure: AgentRecoveryFailure)] = [
            (.taskMissing, .taskGone),
            (.projectUnavailable, .projectWindowUnavailable),
            (.changedWhilePreparing, .changedWhilePreparing),
            (.launchRejected, .launchRejected),
            (.unavailable(.taskNotRecoverable), .notRecoverable),
            (.unavailable(.projectMissing), .projectFolderMissing),
            (.unavailable(.worktreeMissing), .worktreeMissing),
            (.unavailable(.executableMissing), .agentExecutableMissing),
            (.unavailable(.adapterUnavailable), .adapterUnavailable),
            (.unavailable(.vendorIdentityMissing), .sessionIdentityMissing),
            (.unavailable(.vendorIdentityInvalid), .sessionIdentityInvalid),
            (.unavailable(.versionProbeFailed), .versionProbeFailed),
            (.unavailable(.versionChanged), .versionChanged),
        ]

    private static let english = Locale(identifier: "en_US")

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

    // MARK: - Result to cause

    /// The seam #1541 is about. Every one of these results used to arrive at
    /// the same `.recoveryUnavailable` token; nothing downstream could tell a
    /// missing worktree from a changed agent version, because the difference
    /// had already been thrown away here.
    @Test("every recovery result carries its own cause")
    func everyRecoveryResultCarriesItsOwnCause() {
        for (result, expected) in Self.failuresByResult {
            #expect(
                AgentRecoveryFailure.forResult(result) == expected,
                "\(result) must report \(expected)"
            )
        }
    }

    @Test("a started or resumed session reports no failure at all")
    func successfulRecoveryHasNoCause() {
        #expect(
            AgentRecoveryFailure.forResult(
                .openedNewSession(terminalID: UUID())
            ) == nil
        )
        #expect(
            AgentRecoveryFailure.forResult(.resumed(terminalID: UUID())) == nil
        )
    }

    /// The table above is only as good as its coverage: a fourteenth failure
    /// added to the enum and never mapped would leave every assertion green
    /// while being unreachable from any result.
    @Test("every failure case is reachable from some result")
    func everyFailureIsReachable() {
        let reached = Set(Self.failuresByResult.map(\.failure))
        let unreachable = Set(AgentRecoveryFailure.allCases)
            .subtracting(reached)
        #expect(
            reached == Set(AgentRecoveryFailure.allCases),
            "unreachable failures: \(unreachable)"
        )
    }

    /// The planner's nine refusal reasons must stay nine causes. Folding two
    /// of them onto one case compiles and reads plausibly.
    @Test("each planner reason maps to a distinct cause")
    func plannerReasonsAreNotInterchangeable() {
        let reasons: [AgentTaskRecoveryUnavailableReason] = [
            .taskNotRecoverable,
            .projectMissing,
            .worktreeMissing,
            .executableMissing,
            .adapterUnavailable,
            .vendorIdentityMissing,
            .vendorIdentityInvalid,
            .versionProbeFailed,
            .versionChanged,
        ]
        let mapped = reasons.map(AgentRecoveryFailure.forReason)

        #expect(
            Set(mapped).count == reasons.count,
            "two planner reasons share one cause: \(mapped)"
        )
    }

    // MARK: - Cause and next step to text

    @Test("every failure has its own cause sentence")
    func causesAreDistinct() {
        let causes = AgentRecoveryFailure.allCases.map {
            Strings.agentRecoveryCauseText($0, locale: Self.english)
        }

        #expect(
            Set(causes).count == AgentRecoveryFailure.allCases.count,
            "two failures render the same cause: \(causes)"
        )
    }

    /// A cause with no way forward is the dead end #1494 asked us not to
    /// ship: the user is told something went wrong and left there.
    @Test("every failure offers a next step, resolved and non-empty")
    func everyFailureOffersANextStep() {
        for failure in AgentRecoveryFailure.allCases {
            let cause = Strings.agentRecoveryCauseText(
                failure,
                locale: Self.english
            )
            let step = Strings.agentRecoveryNextStepText(
                failure,
                locale: Self.english
            )

            #expect(!cause.isEmpty, "\(failure) has no cause text")
            #expect(!step.isEmpty, "\(failure) has no next step")
            #expect(
                cause != step,
                "\(failure) repeats its cause as its next step"
            )
            // An unresolved key is announced verbatim by VoiceOver.
            #expect(
                !cause.hasPrefix("agentRecovery."),
                "\(failure) exposes its cause key: \(cause)"
            )
            #expect(
                !step.hasPrefix("agentRecovery."),
                "\(failure) exposes its next-step key: \(step)"
            )
        }
    }

    @Test("a failed recovery keeps the popover open with its own cause")
    func failedRecoveryKeepsPopoverVisibleWithItsCause() {
        for (result, failure) in Self.failuresByResult {
            #expect(
                AgentInboxActionOutcome.forRecovery(result)
                    == .keepVisible(.recoveryUnavailable(failure)),
                "\(result) must keep the Inbox open and report \(failure)"
            )
        }
    }

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

    // MARK: - Status to text

    /// The enum carries the distinction; only this edge makes it visible.
    /// Swapping the keys inside `AgentInboxView.statusMessage` compiles and
    /// leaves every enum-level assertion above green, so both mappings are
    /// pinned against the exact strings the user reads and hears.
    @MainActor
    @Test("each status maps to its own visible and spoken text")
    func statusesMapToTheirOwnText() {
        #expect(
            AgentInboxView.statusMessage(.routeUnavailable)
                == Strings.agentInboxRouteUnavailable
        )
        #expect(
            AgentInboxView.statusDetail(.routeUnavailable)
                == Strings.agentInboxRouteUnavailableNextStep
        )
        for failure in AgentRecoveryFailure.allCases {
            #expect(
                AgentInboxView.statusMessage(.recoveryUnavailable(failure))
                    == Strings.agentRecoveryCause(failure)
            )
            #expect(
                AgentInboxView.statusDetail(.recoveryUnavailable(failure))
                    == Strings.agentRecoveryNextStep(failure)
            )
        }
    }

    @MainActor
    @Test("no two statuses are rendered as the same text")
    func statusesAreNotInterchangeable() {
        let statuses: [AgentInboxActionStatus] =
            [.routeUnavailable]
            + AgentRecoveryFailure.allCases.map {
                .recoveryUnavailable($0)
            }

        // `LocalizedStringKey` is `Equatable` but not `Hashable`, so the
        // caption keys are compared pairwise rather than through a `Set`.
        let messages = statuses.map(AgentInboxView.statusMessage)
        for (left, right) in pairs(of: messages.indices) {
            #expect(
                messages[left] != messages[right],
                "\(statuses[left]) and \(statuses[right]) share one caption"
            )
        }

        let announcements = statuses.map {
            AgentInboxView.statusAnnouncement($0, locale: Self.english)
        }
        #expect(Set(announcements).count == statuses.count)
    }

    private func pairs(
        of indices: Range<Int>
    ) -> [(Int, Int)] {
        indices.flatMap { left in
            indices.filter { $0 > left }.map { (left, $0) }
        }
    }

    /// Focus never leaves the popover and the only visible change is a
    /// caption at its bottom edge, so the announcement is the entire feedback
    /// a screen-reader user gets. Dropping the next step from it — easy, and
    /// invisible on screen — puts that user back at the dead end.
    @MainActor
    @Test("every status is spoken as its cause and its next step")
    func announcementsCarryBothHalves() {
        for failure in AgentRecoveryFailure.allCases {
            let spoken = AgentInboxView.statusAnnouncement(
                .recoveryUnavailable(failure),
                locale: Self.english
            )

            #expect(
                spoken.contains(
                    Strings.agentRecoveryCauseText(
                        failure,
                        locale: Self.english
                    )
                ),
                "\(failure) is not announced with its cause"
            )
            #expect(
                spoken.contains(
                    Strings.agentRecoveryNextStepText(
                        failure,
                        locale: Self.english
                    )
                ),
                "\(failure) is not announced with its next step"
            )
        }

        let routeSpoken = AgentInboxView.statusAnnouncement(
            .routeUnavailable,
            locale: Self.english
        )
        #expect(
            routeSpoken.contains(
                Strings.agentInboxRouteUnavailableText(locale: Self.english)
            )
        )
        #expect(
            routeSpoken.contains(
                Strings.agentInboxRouteUnavailableNextStepText(
                    locale: Self.english
                )
            )
        )
    }

    @MainActor
    @Test("every status resolves to real spoken text, not a catalog key")
    func everyStatusHasResolvedSpokenText() {
        let statuses: [AgentInboxActionStatus] =
            [.routeUnavailable]
            + AgentRecoveryFailure.allCases.map {
                .recoveryUnavailable($0)
            }

        for status in statuses {
            let spoken = AgentInboxView.statusAnnouncement(
                status,
                locale: Self.english
            )
            #expect(!spoken.isEmpty, "\(status) must have a spoken form")
            #expect(
                !spoken.hasPrefix("agentInbox."),
                "\(status) announced its catalog key instead of its text"
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
                    statusDetail: nil,
                    announcement: nil
                )
        )
    }

    @MainActor
    @Test("a failure keeps the popover open, captioned, advised and spoken")
    func keepVisibleEffectsStayOpenAndSpeak() {
        let statuses: [AgentInboxActionStatus] =
            [.routeUnavailable]
            + AgentRecoveryFailure.allCases.map {
                .recoveryUnavailable($0)
            }

        for status in statuses {
            let effects = AgentInboxView.effects(
                of: .keepVisible(status),
                locale: Self.english
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
                effects.statusDetail
                    == AgentInboxView.statusDetail(status),
                "\(status) must carry its next step, not only its cause"
            )
            #expect(
                effects.announcement == AgentInboxView.statusAnnouncement(
                    status,
                    locale: Self.english
                ),
                "\(status) must be spoken, not only shown"
            )
        }
    }

    @MainActor
    @Test("a failure runs the caption and the announcement, and no dismiss")
    func failureEffectsAreAppliedWithoutDismissing() {
        var messages: [LocalizedStringKey] = []
        var details: [LocalizedStringKey?] = []
        var announcements: [String] = []
        var dismissals = 0

        AgentInboxView.applyEffects(
            AgentInboxView.effects(
                of: .keepVisible(.recoveryUnavailable(.worktreeMissing)),
                locale: Self.english
            ),
            setStatusMessage: { message, detail in
                messages.append(message)
                details.append(detail)
            },
            announce: { announcements.append($0) },
            dismiss: { dismissals += 1 }
        )

        #expect(
            messages == [Strings.agentRecoveryCause(.worktreeMissing)]
        )
        #expect(
            details == [Strings.agentRecoveryNextStep(.worktreeMissing)]
        )
        #expect(
            announcements == [
                AgentInboxView.statusAnnouncement(
                    .recoveryUnavailable(.worktreeMissing),
                    locale: Self.english
                )
            ]
        )
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
            setStatusMessage: { message, _ in messages.append(message) },
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
            view.actionStatus.detail
                == Strings.agentInboxRouteUnavailableNextStep,
            "a dead route must also say what to do about it"
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

    /// The failures are not interchangeable at this seam either: the view
    /// must caption itself with the status it was handed, not with a
    /// constant, and it must carry the next step through as well.
    @MainActor
    @Test("the view captions a failed recovery with that failure's cause")
    func viewWiresRecoveryFailureToItsOwnCaption() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let view = AgentInboxView(registry: fixture.registry)

        view.apply(.keepVisible(.recoveryUnavailable(.versionChanged)))

        #expect(
            view.actionStatus.message
                == Strings.agentRecoveryCause(.versionChanged)
        )
        #expect(
            view.actionStatus.detail
                == Strings.agentRecoveryNextStep(.versionChanged)
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
        #expect(view.actionStatus.detail == nil)
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
