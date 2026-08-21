//
//  AgentInboxPresentationCoordinatorTests.swift
//  PineTests
//
//  End-to-end coverage for the Agent Inbox presentation workflow (#1491):
//  host selection, restore-and-focus, and the single-request rule.
//

import Testing

@testable import Pine

@Suite("Agent Inbox presentation coordinator", .serialized)
@MainActor
struct AgentInboxPresentationCoordinatorTests {
    // MARK: - Existing hosts

    @Test("the chosen host is focused and receives the deferred request")
    func routesToChosenHost() {
        let fixture = Fixture()
        let host = fixture.addProject(name: "alpha", isKey: true)
        let presenter = fixture.registerAnchor(for: host)

        #expect(fixture.coordinator.present() == .routedToExistingHost)
        // Delivery is deferred so a menu command cannot present the popover
        // inside its own synchronous dispatch.
        #expect(presenter.presentationCount == 0)

        fixture.environment.flushDeliveries()

        #expect(presenter.presentationCount == 1)
        #expect(fixture.environment.journal == [
            "activate",
            "focus(alpha)",
            "activate",
            "deliver",
            "present(alpha)",
        ])
    }

    /// `AgentInboxHosting` promises restore-then-focus, and this pins that
    /// ordering — but it is a **protocol contract test, not evidence of a
    /// user-visible behavior**. `AppDelegate.agentInboxHostOptions` derives
    /// eligibility from `NSWindow.isVisible`, which reads `false` while a
    /// window is in the Dock, and `visibleWelcomeWindow()` rejects
    /// miniaturized windows outright — so this workflow never selects a
    /// miniaturized host and cannot reach `restoreHostFromMiniaturized()`.
    ///
    /// The gap is narrower than "minimized hosts are not restored": a
    /// minimized Welcome window *is* brought back, because selection skips it,
    /// the decision falls through to `.createWelcomeHost`, and
    /// `ensureWelcomeVisible()` deminiaturizes it. What no code does is return
    /// the user to a minimized **project** window: that window is silently
    /// bypassed in favour of Welcome. #1491's "minimized hosts are restored
    /// before presentation" is therefore **not covered** for project windows;
    /// widening eligibility changes where ⇧⌘I lands and belongs in its own
    /// change (#1507). This test exists so that change inherits a specified
    /// workflow rather than an unspecified one.
    @Test("the hosting contract restores a host before it focuses it")
    func hostingContractRestoresBeforeFocusing() {
        let fixture = Fixture()
        let host = fixture.addProject(
            name: "alpha",
            isKey: true,
            isMiniaturized: true
        )
        let presenter = fixture.registerAnchor(for: host)

        fixture.coordinator.present()
        fixture.environment.flushDeliveries()

        #expect(fixture.environment.journal == [
            "activate",
            "restore(alpha)",
            "focus(alpha)",
            "activate",
            "deliver",
            "present(alpha)",
        ])
        #expect(!host.isHostMiniaturized)
        #expect(presenter.presentationCount == 1)
    }

    @Test("a host that is already on screen is not restored")
    func doesNotRestoreVisibleHost() {
        let fixture = Fixture()
        let host = fixture.addProject(name: "alpha", isKey: true)
        fixture.registerAnchor(for: host)

        fixture.coordinator.present()
        fixture.environment.flushDeliveries()

        #expect(!fixture.environment.journal.contains("restore(alpha)"))
    }

    @Test("one request never opens a popover in a second window")
    func requestNeverFansOut() {
        let fixture = Fixture()
        let background = fixture.addProject(name: "background", isKey: false)
        let key = fixture.addProject(name: "key", isKey: true)
        let welcome = fixture.addWelcome(name: "welcome", isKey: false)
        let backgroundAnchor = fixture.registerAnchor(for: background)
        let keyAnchor = fixture.registerAnchor(for: key)
        let welcomeAnchor = fixture.registerAnchor(for: welcome)

        fixture.coordinator.present()
        fixture.environment.flushDeliveries()

        #expect(keyAnchor.presentationCount == 1)
        #expect(backgroundAnchor.presentationCount == 0)
        #expect(welcomeAnchor.presentationCount == 0)
        #expect(!fixture.environment.journal.contains("focus(background)"))
        #expect(!fixture.environment.journal.contains("focus(welcome)"))
    }

    /// A window that is alive but has not mounted its anchor answers
    /// `.queued`, and that is a healthy answer: the router hands the request
    /// over the moment the anchor appears. Treating it as a lost host re-runs
    /// selection, raising a window the user did not ask for — and, because
    /// focus is asynchronous, the second pass can read a pre-focus key window
    /// and route the Inbox somewhere else.
    @Test("a host whose anchor has not mounted is waited for, not re-selected")
    func queuedHostIsNotTreatedAsLost() async {
        let fixture = Fixture()
        let host = fixture.addProject(name: "alpha", isKey: true)
        let other = fixture.addProject(
            name: "other",
            isKey: false,
            showsMostRecentlyActiveProject: true
        )
        let otherAnchor = fixture.registerAnchor(for: other)

        #expect(fixture.coordinator.present() == .routedToExistingHost)
        fixture.environment.flushDeliveries()
        // A retry would deliver a second time and focus a second window.
        fixture.environment.flushDeliveries()

        #expect(fixture.environment.deliveryCount == 1)
        #expect(fixture.environment.welcomeCreationCount == 0)
        #expect(otherAnchor.presentationCount == 0)
        #expect(
            fixture.environment.journal.filter { $0 == "focus(alpha)" }.count
                == 1
        )
        #expect(!fixture.environment.journal.contains("focus(other)"))

        // The request was not dropped either: it is still armed on the router
        // and the window serves it as soon as its anchor mounts.
        let anchor = fixture.registerAnchor(for: host)
        #expect(anchor.presentationCount == 1)

        // The bounded wait standing behind it retires quietly once the request
        // has been served. A wait that kept polling would either present a
        // second time into the window the user is already looking at, or spend
        // its budget and open Welcome behind the Inbox it opened.
        await fixture.settle(turns: 200)
        #expect(anchor.presentationCount == 1)
        #expect(fixture.environment.welcomeCreationCount == 0)
        #expect(!fixture.coordinator.isAwaitingCreatedWelcomeHost)
    }

    /// The bound on that wait, and why it has to exist.
    ///
    /// The anchor lives in a `ToolbarItem` and its registration is keyed by
    /// `anchor.window`, so AppKit takes it out of the window whenever the
    /// toolbar is collapsed, whenever it overflows on a narrow window, and when
    /// full screen moves the toolbar container into `NSToolbarFullScreenWindow`
    /// — which carries no `CloseDelegate` and never becomes a candidate. In all
    /// of those the anchor mounts **never**, which
    /// `queuedHostIsNotTreatedAsLost` above cannot distinguish from "mounts a
    /// turn later" and does not try to.
    ///
    /// Unbounded, that costs twice: the command does nothing at all, and the
    /// request stays armed on the shared router until that window next mounts
    /// an anchor — the Inbox opening by itself minutes later, which is the
    /// hazard `cancelQueuedRequest` claims to have removed.
    @Test("a host whose anchor never mounts is retired, not left armed")
    func anchorlessHostRetiresItsRequestAndFallsBack() async {
        let fixture = Fixture()
        let host = fixture.addProject(name: "alpha", isKey: true)
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")
        // Welcome is created but does not arrive yet, which is the state the
        // real `awaitVisibleWelcomeWindow()` spends up to a second in.
        fixture.environment.holdsWelcomeHost = true

        #expect(fixture.coordinator.present() == .routedToExistingHost)
        fixture.environment.flushDeliveries()
        #expect(fixture.router.hasQueuedRequest(for: host))

        await fixture.settle(turns: 200)
        #expect(fixture.environment.anchorWaitCount > 0)
        #expect(fixture.environment.welcomeCreationCount == 1)

        // The request is retired *before* Welcome is asked for, not after it
        // arrives. Anything left armed across that second would be handed to
        // the anchorless window the moment it did mount an anchor — an Inbox
        // there and a Welcome window created beside it, from one keystroke.
        #expect(!fixture.router.hasQueuedRequest(for: host))
        let late = fixture.registerAnchor(for: host)
        #expect(late.presentationCount == 0)

        // And the keystroke was not swallowed: Welcome hosts it instead, which
        // is the same answer an ineligible desktop already gets (#1486).
        fixture.environment.releaseWelcomeHost()
        await fixture.settle(turns: 200)
        let welcomeAnchor = fixture.registerAnchor(for: welcome)
        #expect(welcomeAnchor.presentationCount == 1)
    }

    @Test("an auxiliary key window routes to the most recent project")
    func auxiliaryKeyWindowRoutesToMostRecentProject() {
        let fixture = Fixture()
        // Settings holds key, so no candidate is key at all.
        let other = fixture.addProject(name: "other", isKey: false)
        let recent = fixture.addProject(
            name: "recent",
            isKey: false,
            showsMostRecentlyActiveProject: true
        )
        fixture.addWelcome(name: "welcome", isKey: false)
        let otherAnchor = fixture.registerAnchor(for: other)
        let recentAnchor = fixture.registerAnchor(for: recent)

        fixture.coordinator.present()
        fixture.environment.flushDeliveries()

        #expect(recentAnchor.presentationCount == 1)
        #expect(otherAnchor.presentationCount == 0)
    }

    @Test("a visible Welcome window is the final existing-window host")
    func visibleWelcomeIsFinalFallback() {
        let fixture = Fixture()
        fixture.addProject(name: "unrelated", isKey: false)
        let welcome = fixture.addWelcome(name: "welcome", isKey: false)
        let welcomeAnchor = fixture.registerAnchor(for: welcome)

        #expect(fixture.coordinator.present() == .routedToExistingHost)
        fixture.environment.flushDeliveries()

        #expect(welcomeAnchor.presentationCount == 1)
        #expect(fixture.environment.welcomeCreationCount == 0)
    }

    /// Named for what it proves: every repeat lands in the *same* window and
    /// focuses it again. It says nothing about focus returning to that window
    /// after the popover closes — #1491's last criterion, which has no
    /// production code behind it and is left to `NSPopover`'s own key-window
    /// restoration. **That criterion is not covered.** No test here or in
    /// `AgentInboxToolbarButtonTests` can stand in for it: host selection
    /// prefers the most recently active project as well as the key window, so
    /// a command still reaches a single project window whether or not focus
    /// came back to it.
    @Test("every repeated request focuses and reuses the same host window")
    func repeatedRequestsReuseAndRefocusTheSameHost() {
        let fixture = Fixture()
        let other = fixture.addProject(name: "other", isKey: false)
        let key = fixture.addProject(name: "key", isKey: true)
        let otherAnchor = fixture.registerAnchor(for: other)
        let keyAnchor = fixture.registerAnchor(for: key)

        for _ in 0..<3 {
            fixture.coordinator.present()
            fixture.environment.flushDeliveries()
        }

        #expect(keyAnchor.presentationCount == 3)
        #expect(otherAnchor.presentationCount == 0)
        #expect(
            fixture.environment.journal.filter { $0 == "focus(key)" }.count == 3
        )
    }

    // MARK: - Creating Welcome

    @Test("no eligible window creates Welcome exactly once per request")
    func createsWelcomeWhenNothingIsEligible() async {
        let fixture = Fixture()
        fixture.addProject(name: "closing", isKey: true, isEligible: false)
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")

        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        #expect(fixture.environment.welcomeCreationCount == 1)
        #expect(fixture.coordinator.isAwaitingCreatedWelcomeHost)

        await fixture.settle()

        // The anchor has not mounted yet, so the single request waits.
        let presenter = fixture.registerAnchor(for: welcome)
        #expect(presenter.presentationCount == 1)
        #expect(!fixture.coordinator.isAwaitingCreatedWelcomeHost)
    }

    @Test("the created Welcome host is focused before routing")
    func createdWelcomeHostIsPrepared() async {
        let fixture = Fixture()
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")
        let presenter = fixture.registerAnchor(for: welcome)

        fixture.coordinator.present()
        await fixture.settle()

        #expect(presenter.presentationCount == 1)
        // A created Welcome window is resolved through
        // `awaitVisibleWelcomeWindow()`, which only ever yields a visible,
        // non-miniaturized window, so no restore step appears here.
        #expect(fixture.environment.journal == [
            "activate",
            "createWelcome",
            "awaitWelcome",
            "focus(welcome)",
            "activate",
            "present(welcome)",
        ])
    }

    @Test("repeated requests while Welcome mounts present exactly once")
    func repeatedRequestsWhileWelcomeMountsPresentOnce() async {
        let fixture = Fixture()
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")
        let presenter = fixture.registerAnchor(for: welcome)

        for _ in 0..<4 {
            #expect(
                fixture.coordinator.present() == .awaitingCreatedWelcomeHost
            )
        }
        await fixture.settle()

        // Every superseded request is cancelled, so the user gets one popover
        // rather than four stacked in the same window.
        #expect(presenter.presentationCount == 1)
        #expect(fixture.environment.welcomeCreationCount == 4)
    }

    @Test("a request superseded before its host arrives is abandoned")
    func supersededWelcomeRequestIsAbandoned() async {
        let fixture = Fixture()
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")
        fixture.environment.holdsWelcomeHost = true
        let welcomeAnchor = fixture.registerAnchor(for: welcome)

        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        await fixture.settle()
        #expect(fixture.environment.pendingWelcomeRequestCount == 1)

        // A project window appears and a second request takes it.
        let project = fixture.addProject(name: "alpha", isKey: true)
        let projectAnchor = fixture.registerAnchor(for: project)
        #expect(fixture.coordinator.present() == .routedToExistingHost)
        fixture.environment.flushDeliveries()

        // The stalled Welcome finally arrives; it must not open a second one.
        fixture.environment.releaseWelcomeHost()
        await fixture.settle()

        #expect(projectAnchor.presentationCount == 1)
        #expect(welcomeAnchor.presentationCount == 0)
    }

    @Test("a superseded created-Welcome task cannot clear its successor")
    func supersededWelcomeTaskCannotClearItsSuccessor() async {
        let fixture = Fixture()
        let first = fixture.environment.stageWelcomeHost(name: "welcomeA")
        fixture.environment.holdsWelcomeHost = true

        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        await fixture.settle()
        #expect(fixture.environment.pendingWelcomeRequestCount == 1)

        // A second request supersedes the first while it is still suspended,
        // so two Welcome hand-offs are outstanding at once.
        let second = fixture.environment.stageWelcomeHost(name: "welcomeB")
        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        await fixture.settle()
        #expect(fixture.environment.pendingWelcomeRequestCount == 2)

        // Let only the superseded one finish. Without the generation guard its
        // cleanup clears the in-flight marker that now belongs to its
        // successor, and the live request reports itself as already finished.
        fixture.environment.releaseWelcomeHost(at: 0)
        await fixture.settle()
        #expect(fixture.coordinator.isAwaitingCreatedWelcomeHost)

        let firstAnchor = fixture.registerAnchor(for: first)
        let secondAnchor = fixture.registerAnchor(for: second)
        fixture.environment.releaseWelcomeHost(at: 0)
        await fixture.settle()

        #expect(firstAnchor.presentationCount == 0)
        #expect(secondAnchor.presentationCount == 1)
        #expect(!fixture.coordinator.isAwaitingCreatedWelcomeHost)
    }

    @Test("a new request retires the one still queued on the shared router")
    func newRequestRetiresTheQueuedRequest() async {
        let fixture = Fixture()
        let welcome = fixture.environment.stageWelcomeHost(name: "welcome")

        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        await fixture.settle()

        // Welcome exists but has not mounted its anchor, so the request sits
        // on the router with nothing of its own to expire it.
        let project = fixture.addProject(name: "alpha", isKey: true)
        let projectAnchor = fixture.registerAnchor(for: project)
        #expect(fixture.coordinator.present() == .routedToExistingHost)

        // Welcome mounts its anchor in the turn before the new request is
        // delivered. Unless the superseded request was retired the moment it
        // lost, this single ⇧⌘I opens the Inbox in two windows at once.
        let welcomeAnchor = fixture.registerAnchor(for: welcome)
        fixture.environment.flushDeliveries()
        await fixture.settle()

        #expect(welcomeAnchor.presentationCount == 0)
        #expect(projectAnchor.presentationCount == 1)
    }

    @Test("a Welcome host that never appears leaves nothing pending")
    func missingWelcomeHostLeavesNothingPending() async {
        let fixture = Fixture()
        fixture.environment.welcomeHost = nil

        #expect(fixture.coordinator.present() == .awaitingCreatedWelcomeHost)
        await fixture.settle()

        #expect(!fixture.coordinator.isAwaitingCreatedWelcomeHost)
        #expect(fixture.environment.journal == [
            "activate",
            "createWelcome",
            "awaitWelcome",
        ])

        // The workflow is still usable afterwards.
        let host = fixture.addProject(name: "alpha", isKey: true)
        let presenter = fixture.registerAnchor(for: host)
        fixture.coordinator.present()
        fixture.environment.flushDeliveries()
        #expect(presenter.presentationCount == 1)
    }

    // MARK: - Lifecycle

    @Test("a released environment cannot be presented into")
    func releasedEnvironmentIsUnavailable() {
        let router = AgentInboxPopoverRouter()
        var coordinator: AgentInboxPresentationCoordinator?
        do {
            let environment = Environment()
            coordinator = AgentInboxPresentationCoordinator(
                router: router,
                environment: environment
            )
        }

        #expect(coordinator?.present() == .unavailable)
    }

    @Test("a released host window drops its queued request")
    func releasedHostDropsQueuedRequest() async {
        let fixture = Fixture()
        fixture.environment.stageWelcomeHost(name: "welcome")

        fixture.coordinator.present()
        await fixture.settle()

        // The Welcome window is torn down before its anchor ever mounts.
        fixture.environment.welcomeHost = nil
        let unrelated = fixture.addProject(name: "alpha", isKey: true)
        let unrelatedAnchor = fixture.registerAnchor(for: unrelated)

        // Mounting an unrelated window must not inherit the dead request…
        #expect(unrelatedAnchor.presentationCount == 0)
        // …while that window still answers a request addressed to it, which
        // is what makes the line above evidence rather than a tautology.
        #expect(fixture.router.requestPresentation(in: unrelated) == .presented)
        #expect(unrelatedAnchor.presentationCount == 1)
    }

    @Test("an undelivered request never keeps its host window alive")
    func deliveryDoesNotRetainItsHost() {
        let fixture = Fixture()
        weak var weakHost: Host?

        do {
            let host = fixture.addProject(name: "closing", isKey: true)
            weakHost = host
            #expect(fixture.coordinator.present() == .routedToExistingHost)
        }
        fixture.environment.options.removeAll()

        // Delivery is still outstanding. A strong capture here would hold a
        // closing NSWindow alive for a whole extra runloop turn.
        #expect(weakHost == nil)
    }

    @Test("a host that dies before delivery re-selects instead of vanishing")
    func lostHostReselectsRatherThanDroppingTheRequest() {
        let fixture = Fixture()
        var doomed: Host? = fixture.addProject(name: "doomed", isKey: true)
        let survivor = fixture.addProject(
            name: "survivor",
            isKey: false,
            showsMostRecentlyActiveProject: true
        )
        let survivorAnchor = fixture.registerAnchor(for: survivor)

        #expect(fixture.coordinator.present() == .routedToExistingHost)

        // The chosen window closes in the turn between selection and delivery.
        fixture.environment.removeOption(for: doomed)
        doomed = nil

        fixture.environment.flushDeliveries()
        // The retry re-runs selection and is itself deferred.
        fixture.environment.flushDeliveries()

        #expect(survivorAnchor.presentationCount == 1)
    }

    @Test("re-selection is bounded, so a hostless desktop cannot spin")
    func lostHostRetryIsBounded() async {
        let fixture = Fixture()
        var doomed: Host? = fixture.addProject(name: "doomed", isKey: true)

        #expect(fixture.coordinator.present() == .routedToExistingHost)
        fixture.environment.removeOption(for: doomed)
        doomed = nil

        for _ in 0..<6 {
            fixture.environment.flushDeliveries()
        }

        // One retry; it finds nothing eligible and falls through to creating
        // Welcome rather than re-delivering forever.
        #expect(fixture.environment.deliveryCount == 1)
        #expect(fixture.environment.welcomeCreationCount == 1)

        await fixture.settle()
        #expect(!fixture.coordinator.isAwaitingCreatedWelcomeHost)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        // The router's own deferral is its contract and is covered in
        // `AgentInboxPopoverRouterTests`; here it would only blur the
        // selection ordering these tests exist to pin.
        let router = AgentInboxPopoverRouter { operation in operation() }
        let environment = Environment()
        lazy var coordinator = AgentInboxPresentationCoordinator(
            router: router,
            environment: environment
        )
        private var anchors: [Anchor] = []

        @discardableResult
        func addProject(
            name: String,
            isKey: Bool,
            isEligible: Bool = true,
            isMiniaturized: Bool = false,
            showsMostRecentlyActiveProject: Bool = false
        ) -> Host {
            let host = Host(
                name: name,
                journal: environment,
                isMiniaturized: isMiniaturized
            )
            environment.options.append(AgentInboxHostOption(
                candidate: AgentInboxHostCandidate(
                    kind: .project,
                    isKeyWindow: isKey,
                    isEligibleWindow: isEligible,
                    showsMostRecentlyActiveProject:
                        showsMostRecentlyActiveProject
                ),
                host: host
            ))
            return host
        }

        @discardableResult
        func addWelcome(name: String, isKey: Bool) -> Host {
            let host = Host(name: name, journal: environment)
            environment.options.append(AgentInboxHostOption(
                candidate: AgentInboxHostCandidate(
                    kind: .welcome,
                    isKeyWindow: isKey
                ),
                host: host
            ))
            return host
        }

        @discardableResult
        func registerAnchor(for host: Host) -> Anchor {
            let anchor = Anchor(name: host.name, journal: environment)
            anchors.append(anchor)
            router.register(anchor, for: host)
            return anchor
        }

        /// Lets every superseded and surviving presentation task run to
        /// completion. A created-Welcome request suspends at most twice; a
        /// request waiting on an existing host's anchor suspends once per
        /// attempt, so exhausting that budget needs a much larger `turns`.
        func settle(turns: Int = 12) async {
            for _ in 0..<turns {
                await Task.yield()
            }
        }
    }

    /// Records the exact order of AppKit effects so restore-before-focus and
    /// focus-before-present are asserted, not assumed.
    @MainActor
    private final class Environment: AgentInboxHostEnvironment {
        /// One suspended `awaitAgentInboxWelcomeHost()` call, together with
        /// the host staged when it suspended. Held per request so a
        /// superseded hand-off and its successor can finish in either order —
        /// the only arrangement in which the coordinator's generation guard
        /// has anything to do.
        private struct PendingWelcome {
            let host: Host?
            let continuation: CheckedContinuation<Host?, Never>
        }

        var options: [AgentInboxHostOption] = []
        var welcomeHost: Host?
        /// Suspends `awaitAgentInboxWelcomeHost()` until explicitly released.
        var holdsWelcomeHost = false
        private(set) var journal: [String] = []
        private(set) var welcomeCreationCount = 0
        private(set) var deliveryCount = 0
        private(set) var anchorWaitCount = 0
        private var deliveries: [@MainActor () -> Void] = []
        private var pendingWelcomes: [PendingWelcome] = []

        var pendingWelcomeRequestCount: Int {
            pendingWelcomes.count
        }

        func removeOption(for host: Host?) {
            guard let host else { return }
            options.removeAll { $0.host === host }
        }

        func record(_ entry: String) {
            journal.append(entry)
        }

        @discardableResult
        func stageWelcomeHost(
            name: String,
            isMiniaturized: Bool = false
        ) -> Host {
            let host = Host(
                name: name,
                journal: self,
                isMiniaturized: isMiniaturized
            )
            welcomeHost = host
            return host
        }

        func releaseWelcomeHost() {
            holdsWelcomeHost = false
            let pending = pendingWelcomes
            pendingWelcomes.removeAll()
            for entry in pending {
                entry.continuation.resume(returning: entry.host)
            }
        }

        /// Finishes exactly one outstanding hand-off, leaving the rest
        /// suspended.
        func releaseWelcomeHost(at index: Int) {
            guard pendingWelcomes.indices.contains(index) else { return }
            let entry = pendingWelcomes.remove(at: index)
            entry.continuation.resume(returning: entry.host)
        }

        func flushDeliveries() {
            let pending = deliveries
            deliveries.removeAll()
            for operation in pending {
                operation()
            }
        }

        // MARK: AgentInboxHostEnvironment

        func agentInboxHostOptions() -> [AgentInboxHostOption] {
            options
        }

        func activateApplicationForAgentInbox() {
            record("activate")
        }

        func createAgentInboxWelcomeHost() {
            welcomeCreationCount += 1
            record("createWelcome")
        }

        func awaitAgentInboxWelcomeHost() async -> (any AgentInboxHosting)? {
            record("awaitWelcome")
            guard holdsWelcomeHost else { return welcomeHost }
            // The staged host is captured now, not on release: a later
            // request stages its own window and must not retarget this one.
            let staged = welcomeHost
            let host: Host? = await withCheckedContinuation { continuation in
                pendingWelcomes.append(PendingWelcome(
                    host: staged,
                    continuation: continuation
                ))
            }
            return host
        }

        func deliverAgentInboxRequest(
            _ operation: @escaping @MainActor () -> Void
        ) {
            record("deliver")
            deliveryCount += 1
            deliveries.append(operation)
        }

        /// Counted rather than journalled: the bounded wait runs dozens of
        /// times and would drown the effect orderings the journal exists to
        /// pin.
        func waitForAgentInboxAnchor() async {
            anchorWaitCount += 1
            await Task.yield()
        }
    }

    @MainActor
    private final class Host: AgentInboxHosting {
        let name: String
        private(set) var isHostMiniaturized: Bool
        private unowned let journal: Environment

        init(
            name: String,
            journal: Environment,
            isMiniaturized: Bool = false
        ) {
            self.name = name
            self.journal = journal
            self.isHostMiniaturized = isMiniaturized
        }

        func restoreHostFromMiniaturized() {
            isHostMiniaturized = false
            journal.record("restore(\(name))")
        }

        func focusHost() {
            journal.record("focus(\(name))")
        }
    }

    @MainActor
    private final class Anchor: AgentInboxPopoverPresenting {
        let name: String
        private(set) var presentationCount = 0
        private unowned let journal: Environment

        init(name: String, journal: Environment) {
            self.name = name
            self.journal = journal
        }

        func presentAgentInbox() {
            presentationCount += 1
            journal.record("present(\(name))")
        }
    }
}
