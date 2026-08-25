//
//  AgentInboxFocusReturnTests.swift
//  PineTests
//
//  Where keyboard focus goes when the Agent Inbox popover closes — the last
//  of #1491's acceptance criteria, and the one with no production code before
//  this suite.
//
//  `AgentInboxFocusRestorationRuleTests` pins the rule as a value. This suite
//  pins the wiring around it: what the anchor records, when it records it, and
//  which dismissal it acts on. Both halves are needed — a coordinator that
//  captures the wrong responder, or captures it after the popover has taken
//  focus, satisfies the rule perfectly and still returns the user nowhere.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox focus return", .serialized)
@MainActor
struct AgentInboxFocusReturnTests {
    // MARK: - The dismissals that return focus

    /// Escape and a click outside are handled by AppKit itself: the popover is
    /// `.transient`, so the anchor only ever learns about them through the
    /// close notification. Focus has to come back to the window the user was
    /// working in, on the responder they were working in.
    @Test("an outside click or Escape returns focus to the host responder")
    func appKitCloseReturnsFocusToTheHost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()
        let editor = fixture.focusHost.focusedResponder

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.dismissFromAppKit(popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.count == 1)
        #expect((fixture.focusHost.returnedResponders.first ?? nil) === editor)
    }

    /// The toolbar button and ⇧⌘I both close the Inbox by lowering the
    /// SwiftUI binding, which reaches AppKit as an anchor-started close rather
    /// than an AppKit-started one. The user has not gone anywhere, so this is
    /// the same in-place dismissal.
    @Test("closing from the toolbar returns focus to the host responder")
    func bindingCloseReturnsFocusToTheHost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()
        let editor = fixture.focusHost.focusedResponder

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.isPresented = false
        fixture.update()
        popover.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.count == 1)
        #expect((fixture.focusHost.returnedResponders.first ?? nil) === editor)
    }

    /// The window is asked to take focus back exactly once per dismissal.
    /// SwiftUI re-renders constantly while a close animates, and every one of
    /// those passes reaches the same close path; a restore per pass would
    /// yank the window forward repeatedly.
    ///
    /// - Note: this pins the *once*, but not the record retirement inside
    ///   `returnFocusToHost()`. Deleting those three lines leaves this suite
    ///   green, because nothing calls `returnFocusToHost()` twice for one
    ///   presentation: `retireClosedPopover()` is its only caller, it clears
    ///   the popover reference synchronously, and only `presentIfReady()` —
    ///   which re-records — can set that reference again. The retirement is
    ///   therefore defence in depth against a future second caller, and it is
    ///   not covered. Written here rather than implied away.
    @Test("a dismissal returns focus once, not once per SwiftUI pass")
    func focusIsReturnedOncePerDismissal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.isPresented = false
        fixture.update()
        popover.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: popover)
        for _ in 0..<8 { fixture.update() }
        await fixture.settle()
        for _ in 0..<8 { fixture.update() }
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.count == 1)
    }

    /// Two full cycles: the second dismissal must restore too. The cause and
    /// the captured responder are per-presentation state, and a version that
    /// forgets to reset them leaves the second Escape doing nothing.
    @Test("every open and dismiss cycle returns focus again")
    func everyCycleReturnsFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        for cycle in 0..<3 {
            let expected = fixture.moveFocus(to: "responder-\(cycle)")
            fixture.coordinator.presentAgentInbox()
            let popover = try #require(fixture.popovers.last)

            fixture.dismissFromAppKit(popover)
            await fixture.settle()
            fixture.update()

            #expect(
                fixture.focusHost.returnedResponders.count == cycle + 1,
                "Cycle \(cycle) did not return focus"
            )
            #expect(
                (fixture.focusHost.returnedResponders.last ?? nil) === expected,
                "Cycle \(cycle) returned focus to the wrong responder"
            )
        }
    }

    // MARK: - The dismissals that must not

    /// The dismissal that would be actively harmful to restore.
    ///
    /// The Inbox closes on a *successful* navigation or recovery, which has
    /// just made another project window key. Returning focus to the window
    /// that hosted the popover would undo the very action the user took —
    /// they would land back where they started with the Inbox gone.
    @Test("a successful navigation keeps focus on the window it moved to")
    func navigatingDismissalLeavesFocusAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)
        let context = try #require(fixture.contexts.last)

        // What `AgentInboxActionOutcome.dismiss` reaches the anchor through.
        context.onDismiss()
        popover.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.isEmpty)
    }

    /// An anchor demounted with the Inbox open — the window is closing, or
    /// SwiftUI rebuilt the toolbar out from under it. There is no host left to
    /// return to, and raising one would fight the teardown.
    @Test("a detached anchor never returns focus to the window it left")
    func detachedAnchorLeavesFocusAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.coordinator.detach()
        popover.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.isEmpty)
    }

    /// The host went off screen while the Inbox was open — closed, hidden, or
    /// minimized to the Dock. Restoring would order a window the user just put
    /// away back to the front.
    @Test("a host that left the screen is never raised to take focus back")
    func offScreenHostIsNeverRaised() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.focusHost.canTakeFocus = false
        fixture.dismissFromAppKit(popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.isEmpty)
    }

    /// A `.transient` popover also closes when the user clicks into another
    /// application. Pine is no longer active, and a window told to become key
    /// there takes focus the moment the user comes back to Pine — after they
    /// chose to leave it.
    @Test("a dismissal that left the application never reclaims focus")
    func inactiveApplicationLeavesFocusAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.isApplicationActive = false
        fixture.dismissFromAppKit(popover)
        await fixture.settle()

        #expect(fixture.focusHost.returnedResponders.isEmpty)
    }

    /// A close settles a whole runloop turn after AppKit reports it, and a new
    /// request can open the Inbox again inside that turn. The popover on
    /// screen owns focus; the finished close no longer speaks for the window.
    @Test("a close that settles under a newer popover leaves focus alone")
    func settledCloseUnderANewerPopoverLeavesFocusAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)

        fixture.dismissFromAppKit(first)
        // ⇧⌘I again, inside the turn the close still owes its write.
        fixture.coordinator.presentAgentInbox()
        await fixture.settle()

        #expect(fixture.popovers.count == 2)
        #expect(fixture.focusHost.returnedResponders.isEmpty)
    }

    // MARK: - What gets recorded, and when

    /// The ordering the whole feature rests on.
    ///
    /// An `NSPopover` takes key away from its host window as it appears, so a
    /// capture made after the show reads the popover's own state rather than
    /// the user's. The record has to be taken before the popover is on screen.
    @Test("focus is recorded before the popover is shown")
    func focusIsRecordedBeforeTheShow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()

        #expect(fixture.journal == ["capture", "show"])
    }

    /// Nothing is recorded for a request that does not produce a popover, so
    /// an anchor that never showed anything cannot later hand focus to a
    /// responder captured for a presentation that did not happen.
    @Test("a request that shows nothing records no focus to return to")
    func aRequestThatShowsNothingRecordsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // Attached but never mounted in a window: `presentIfReady` refuses.
        fixture.coordinator.attach(to: fixture.anchor)

        fixture.coordinator.presentAgentInbox()

        #expect(fixture.popovers.isEmpty)
        #expect(fixture.journal.isEmpty)
    }

    /// The window whose focus is restored is the one the popover was anchored
    /// in, resolved from the anchor rather than from whatever is key at close
    /// time — by then the popover itself has been key.
    @Test("focus returns to the window the popover was anchored in")
    func focusReturnsToTheAnchorsOwnWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)

        fixture.dismissFromAppKit(popover)
        await fixture.settle()

        #expect(fixture.resolvedWindows.allSatisfy { $0 === fixture.window })
        #expect(!fixture.resolvedWindows.isEmpty)
    }

    // MARK: - Fixture

    @MainActor
    final class Fixture {
        let router = AgentInboxPopoverRouter { operation in operation() }
        let registry: ProjectRegistry
        let focusHost = FakeFocusHost()
        var isApplicationActive = true
        private(set) var popovers: [FakePopover] = []
        private(set) var contexts: [AgentInboxPopoverCoordinator.Context] = []
        /// The order AppKit-visible work happened in, which is the only way to
        /// see that the capture precedes the show.
        private(set) var journal: [String] = []
        /// Every window handed to the focus-host resolver.
        private(set) var resolvedWindows: [NSWindow] = []
        var isPresented = false
        private var snapshot = false
        let anchor = AgentInboxPopoverAnchorView(frame: .zero)
        let window: NSWindow
        private let suiteName: String
        private let defaults: UserDefaults
        private var openedProjectWindows: [URL] = []

        lazy var coordinator = AgentInboxPopoverCoordinator(
            router: router,
            makePopover: { [weak self] _, context in
                guard let self else { return nil }
                let popover = FakePopover { [weak self] event in
                    self?.journal.append(event)
                }
                self.popovers.append(popover)
                self.contexts.append(context)
                return popover
            },
            resolveFocusHost: { [weak self] window in
                guard let self else { return window }
                self.resolvedWindows.append(window)
                return self.focusHost
            },
            isApplicationActive: { [weak self] in
                self?.isApplicationActive ?? true
            }
        )

        init() throws {
            suiteName = "AgentInboxFocusReturnTests.\(UUID())"
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
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: window.contentRect(forFrameRect: window.frame)
            )
            focusHost.journal = { [weak self] event in
                self?.journal.append(event)
            }
        }

        func mount() {
            window.contentView?.addSubview(anchor)
            coordinator.attach(to: anchor)
            update()
        }

        func update() {
            snapshot = isPresented
            coordinator.update(
                anchor: anchor,
                isPresented: Binding(
                    get: { [weak self] in self?.snapshot ?? false },
                    set: { [weak self] value in self?.isPresented = value }
                ),
                registry: registry,
                openProjectWindow: { [weak self] url in
                    self?.openedProjectWindows.append(url)
                },
                reduceMotion: true
            )
        }

        /// Moves the host window's keyboard focus, as the user would by
        /// clicking into the editor or the sidebar.
        @discardableResult
        func moveFocus(to name: String) -> NSResponder {
            let responder = NamedResponder(name: name)
            focusHost.focusedResponder = responder
            return responder
        }

        /// Escape or a click outside: AppKit closes the popover on its own and
        /// tells the anchor afterwards.
        func dismissFromAppKit(_ popover: FakePopover) {
            coordinator.popoverWillClose(sender: popover)
            popover.isPopoverVisible = false
            coordinator.popoverDidClose(sender: popover)
        }

        /// Lets the deferred SwiftUI-and-focus half of a close run.
        ///
        /// Every hop in the coordinator is a `DispatchQueue.main.async`, and
        /// the main queue is FIFO: a continuation enqueued now resumes after
        /// all of them. That is a real wait for the work rather than a guess
        /// at its timing — no sleep, and no `Task.yield()` standing in for
        /// one.
        func settle() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        func cleanup() {
            coordinator.detach()
            anchor.removeFromSuperview()
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Stands in for the host `NSWindow`'s focus behaviour, which cannot be
    /// established from a live window here: the unit test host is a background
    /// application, so it has no key window and `makeKeyAndOrderFront` is
    /// unobservable.
    @MainActor
    final class FakeFocusHost: AgentInboxFocusHost {
        var canTakeFocus = true
        var focusedResponder: NSResponder? = NamedResponder(name: "editor")
        private(set) var returnedResponders: [NSResponder?] = []
        var journal: ((String) -> Void)?

        func captureFocusedResponder() -> NSResponder? {
            journal?("capture")
            return focusedResponder
        }

        func returnFocus(to responder: NSResponder?) {
            journal?("return")
            returnedResponders.append(responder)
        }
    }

    @MainActor
    final class FakePopover: AgentInboxPopoverHandle {
        var isPopoverVisible = false
        private let journal: (String) -> Void

        init(journal: @escaping (String) -> Void) {
            self.journal = journal
        }

        func showPopover(from anchor: NSView) {
            journal("show")
            isPopoverVisible = true
        }

        func closePopover() {
            journal("close")
            isPopoverVisible = false
        }
    }

    /// An identifiable stand-in for the editor, sidebar, or terminal view that
    /// owned keyboard focus before the Inbox opened.
    private final class NamedResponder: NSResponder {
        let name: String

        init(name: String) {
            self.name = name
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
