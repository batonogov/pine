//
//  AgentInboxHostOptionsTests.swift
//  PineTests
//
//  The AppKit projection that feeds Agent Inbox host selection (#1491).
//
//  `AgentInboxHostRouting` decides among candidates a test hands it directly,
//  so it cannot catch a mistake made while *building* those candidates. Every
//  AppKit-shaped risk lives here instead: the `CloseDelegate` cast that
//  decides what is a candidate at all, key-window identity, the four-part
//  eligibility conjunction, and Welcome's fixed last position.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Agent Inbox host options", .serialized)
@MainActor
struct AgentInboxHostOptionsTests {
    // MARK: - What becomes a candidate

    @Test("a window without Pine's close delegate is never a candidate")
    func foreignWindowsAreNotCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let undelegated = fixture.makeWindow()
        let foreign = fixture.makeWindow()
        foreign.delegate = fixture.makeForeignDelegate()

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [undelegated, foreign],
            keyWindow: foreign,
            welcomeWindow: nil
        )

        // Settings, About, panels, and the popover's own window all sit in
        // `NSApp.windows`. Routing into one would put the Inbox somewhere it
        // cannot be reopened from.
        #expect(options.isEmpty)
    }

    @Test("a project window is projected as a candidate for its own window")
    func projectWindowBecomesItsOwnCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let window = try fixture.makeProjectWindow(named: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: window,
            welcomeWindow: nil
        )

        #expect(options.count == 1)
        #expect(options.first?.candidate.kind == .project)
        #expect(options.first?.host === window)
        #expect(options.first?.candidate.isKeyWindow == true)
        #expect(options.first?.candidate.isEligibleWindow == true)
    }

    // MARK: - Welcome's position

    @Test("the Welcome candidate is always last, whatever AppKit's order")
    func welcomeIsAlwaysTheFinalCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        let beta = try fixture.makeProjectWindow(named: "beta")
        let welcome = fixture.makeWindow()

        // Welcome carries no `CloseDelegate`, so its place in `NSApp.windows`
        // cannot move it: it is appended after every project candidate. The
        // ordering rule depends on that — Welcome is the final fallback.
        for windows in [[welcome, alpha, beta], [alpha, welcome, beta]] {
            let options = fixture.appDelegate.agentInboxHostOptions(
                windows: windows,
                keyWindow: welcome,
                welcomeWindow: welcome
            )

            #expect(options.map(\.candidate.kind) == [
                .project, .project, .welcome,
            ])
            #expect(options.last?.host === welcome)
            #expect(options.last?.candidate.isKeyWindow == true)
        }
    }

    @Test("no visible Welcome window contributes no Welcome candidate")
    func absentWelcomeContributesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [alpha],
            keyWindow: nil,
            welcomeWindow: nil
        )

        #expect(options.count == 1)
        #expect(options.allSatisfy { $0.candidate.kind == .project })
    }

    // MARK: - Key identity

    @Test("key is decided by window identity, not by list position")
    func keyIsDecidedByIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        let beta = try fixture.makeProjectWindow(named: "beta")
        let welcome = fixture.makeWindow()

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [alpha, beta],
            keyWindow: beta,
            welcomeWindow: welcome
        )

        #expect(options.map(\.candidate.isKeyWindow) == [false, true, false])
    }

    @Test("an auxiliary key window leaves no candidate marked key")
    func auxiliaryKeyWindowMarksNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        let welcome = fixture.makeWindow()
        let settings = fixture.makeWindow()

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [alpha, settings],
            keyWindow: settings,
            welcomeWindow: welcome
        )

        #expect(options.allSatisfy { !$0.candidate.isKeyWindow })
    }

    // MARK: - Eligibility

    /// Leaving the screen is what costs a window its eligibility. A window
    /// ordered out is the one form of "not on screen" that survives the
    /// widened reach of #1507: the Inbox now admits a window in the Dock,
    /// because it restores that host before presenting, but a window that was
    /// ordered out shows nothing and can host nothing.
    ///
    /// See `dockedProjectWindowIsACandidate` for the other side of that line.
    @Test("leaving the screen costs a window its eligibility")
    func orderedOutWindowLosesEligibility() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let window = try fixture.makeProjectWindow(named: "alpha")
        #expect(window.isVisible)
        #expect(
            fixture.appDelegate.agentInboxHostOptions(
                windows: [window],
                keyWindow: window,
                welcomeWindow: nil
            ).first?.candidate.isEligibleWindow == true
        )

        window.orderOut(nil)

        #expect(!window.isVisible)
        #expect(
            fixture.appDelegate.agentInboxHostOptions(
                windows: [window],
                keyWindow: window,
                welcomeWindow: nil
            ).first?.candidate.isEligibleWindow == false
        )
    }

    /// Isolates the registered-manager conjunct. The project's *URL* is open
    /// — the registry admitted it and would answer `isWindowOpen` for it — but
    /// this window's delegate points at a different `ProjectManager`, so the
    /// conjunction has exactly one false term. Routing here would open an
    /// Inbox over a project model nothing else can reach.
    @Test("a window holding a manager the registry never admitted is skipped")
    func windowWithAForeignManagerIsNotEligible() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.makeProjectDirectory(named: "alpha")
        let admitted = try #require(fixture.registry.projectManager(for: url))
        #expect(fixture.registry.isWindowOpen(url))

        let window = fixture.makeWindow()
        let foreign = ProjectManager()
        #expect(foreign !== admitted)
        fixture.attachCloseDelegate(
            to: window,
            projectURL: url,
            projectManager: foreign
        )

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: window,
            welcomeWindow: nil
        )

        #expect(options.first?.candidate.isEligibleWindow == false)
    }

    /// Isolates the open-window conjunct. The manager is still registered, so
    /// `isRegisteredProject` holds; only the URL has moved into the registry's
    /// background set, which is where a project lives while it has a live
    /// model but no window on screen.
    @Test("a backgrounded project keeps its manager but loses eligibility")
    func backgroundedProjectIsNotEligible() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let survivor = try fixture.makeProjectWindow(named: "survivor")
        let url = try fixture.makeProjectDirectory(named: "alpha")
        let manager = try #require(fixture.registry.projectManager(for: url))
        let window = fixture.makeWindow()
        fixture.attachCloseDelegate(
            to: window,
            projectURL: url,
            projectManager: manager
        )

        fixture.registry.closeProjectWindow(
            url,
            expectedManager: manager,
            expectedWindowGeneration: nil
        )

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [survivor, window],
            keyWindow: window,
            welcomeWindow: nil
        )

        // The manager survives the close, which is what makes this the one
        // conjunct under test.
        #expect(
            fixture.registry.openProjects.values.contains { $0 === manager }
        )
        #expect(!fixture.registry.isWindowOpen(url))
        #expect(options[1].candidate.isEligibleWindow == false)
    }

    /// Isolates the lifecycle conjunct — the dangerous one, because it is the
    /// only state where every other term still reads true.
    /// `handleProjectWindowDisappear` returns early when the closing window's
    /// generation no longer matches its manager's, so the registry keeps the
    /// project open while the delegate has already reported its close. Without
    /// `!didCompleteWindowLifecycle` this window is a fully eligible host, and
    /// the Inbox opens in a window that is on its way out.
    @Test("a completed lifecycle disqualifies a window the registry still holds")
    func completedLifecycleIsNotEligibleEvenWhileRegistryHoldsIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.makeProjectDirectory(named: "alpha")
        let manager = try #require(fixture.registry.projectManager(for: url))
        let window = fixture.makeWindow()
        fixture.attachCloseDelegate(
            to: window,
            projectURL: url,
            projectManager: manager
        )
        let delegate = try #require(window.delegate as? CloseDelegate)

        // Bind the delegate to this window's generation, then rotate the
        // manager's: the close that follows carries a generation the manager
        // no longer recognises.
        delegate.observeWindowClose(window)
        manager.prepareForWindowPresentation()

        delegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: window
        ))

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: window,
            welcomeWindow: nil
        )

        // Every other conjunct is true here, which is the whole point.
        #expect(delegate.didCompleteWindowLifecycle)
        #expect(window.isVisible)
        #expect(fixture.registry.isWindowOpen(url))
        #expect(
            fixture.registry.openProjects.values.contains { $0 === manager }
        )
        #expect(options.first?.candidate.isEligibleWindow == false)
    }

    @Test("a window whose close already completed is never eligible")
    func closedWindowIsNotEligible() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // A second project keeps the app populated, so closing the first does
        // not drag the Welcome-restoration path into this test.
        let survivor = try fixture.makeProjectWindow(named: "survivor")
        let closing = try fixture.makeProjectWindow(named: "closing")
        let delegate = try #require(closing.delegate as? CloseDelegate)

        delegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: closing
        ))

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [survivor, closing],
            keyWindow: closing,
            welcomeWindow: nil
        )

        #expect(options.count == 2)
        #expect(options[0].candidate.isEligibleWindow == true)
        // The key window is the one that is closing; eligibility, not key
        // status, is what keeps the request away from it.
        #expect(options[1].candidate.isKeyWindow == true)
        #expect(options[1].candidate.isEligibleWindow == false)
    }

    // MARK: - Most recently active project

    @Test("only the most recently active project's window is marked")
    func mostRecentProjectIsMarkedOnItsOwnWindow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        let beta = try fixture.makeProjectWindow(named: "beta")
        fixture.noteKeyWindowSession(showing: "beta")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [alpha, beta],
            keyWindow: nil,
            welcomeWindow: nil
        )

        #expect(
            options.map(\.candidate.showsMostRecentlyActiveProject)
                == [false, true]
        )
    }

    @Test("no active session marks no window as most recent")
    func withoutASessionNothingIsMostRecent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [alpha],
            keyWindow: nil,
            welcomeWindow: nil
        )

        // A `nil` most-recent project must not accidentally match a window
        // whose own project is also absent.
        #expect(
            options.first?.candidate.showsMostRecentlyActiveProject == false
        )
    }

    // MARK: - Rule and projection together

    @Test("the winning index names the window the user expects")
    func decisionIndexNamesTheExpectedWindow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let background = try fixture.makeProjectWindow(named: "background")
        let key = try fixture.makeProjectWindow(named: "key")
        let welcome = fixture.makeWindow()

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [background, key],
            keyWindow: key,
            welcomeWindow: welcome
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        // The index is only meaningful against the list it was derived from;
        // this is the one assertion that ties the two halves together.
        guard case .existingHost(let index) = decision else {
            Issue.record("Expected an existing host, got \(decision)")
            return
        }
        #expect(options[index].host === key)
    }

    @Test("an all-ineligible desktop routes to creating Welcome")
    func ineligibleDesktopCreatesWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hidden = try fixture.makeProjectWindow(
            named: "hidden",
            onScreen: false
        )
        let settings = fixture.makeWindow()

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [hidden, settings],
            keyWindow: settings,
            welcomeWindow: nil
        )

        #expect(
            AgentInboxHostRouting.decision(among: options.map(\.candidate))
                == .createWelcomeHost
        )
    }

    // MARK: - The production wrapper's own reads

    /// `agentInboxHostOptions()` is what ⇧⌘I actually calls; every test above
    /// hands the projection its facts directly and so cannot see which fact
    /// production passes where. These pin the wrapper itself.
    ///
    /// The unit test host is a background application — `NSApp.isActive` is
    /// `false`, `NSApp.keyWindow` is always `nil`, `orderedWindows` does not
    /// follow the screen, and no window reaches the Dock — so the wrapper's
    /// three reads are exercised through their injection points rather than
    /// through live window state, which cannot reproduce any of them.

    @Test("the wrapper hands each source to the fact it names")
    func wrapperRoutesEachSourceToItsOwnFact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        let beta = try fixture.makeProjectWindow(named: "beta")
        let welcome = fixture.makeWindow()
        fixture.appDelegate.agentInboxWindowSources = AgentInboxWindowSources(
            windows: { [alpha, beta] },
            keyWindow: { beta },
            welcomeWindow: { welcome }
        )

        let options = fixture.appDelegate.agentInboxHostOptions()

        // Three distinct facts, three distinct destinations: the window list
        // becomes the project candidates in order, the key window marks
        // exactly one of them, and Welcome is appended last.
        #expect(options.map(\.candidate.kind) == [
            .project, .project, .welcome,
        ])
        #expect(options.map(\.candidate.isKeyWindow) == [false, true, false])
        // By identity: `host` is `any AgentInboxHosting` so the workflow can
        // substitute a double for the restore-then-focus ordering, and an
        // existential is not `Equatable`. `ObjectIdentifier` still pins order,
        // count and the exact object, which is the whole claim here.
        #expect(
            options.map { ObjectIdentifier($0.host) }
                == [alpha, beta, welcome].map(ObjectIdentifier.init)
        )
    }

    @Test("a wrapper with no Welcome source builds no Welcome candidate")
    func wrapperWithoutAWelcomeSourceOffersNoWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.makeProjectWindow(named: "alpha")
        fixture.appDelegate.agentInboxWindowSources = AgentInboxWindowSources(
            windows: { [alpha] },
            keyWindow: { nil },
            welcomeWindow: { nil }
        )

        let options = fixture.appDelegate.agentInboxHostOptions()

        // Welcome is the last existing-window fallback. Losing it does not
        // fail loudly — the request quietly creates a second Welcome window.
        #expect(options.allSatisfy { $0.candidate.kind == .project })
        #expect(options.allSatisfy { !$0.candidate.isKeyWindow })
    }

    /// The window source's default really is the live application list, not an
    /// empty stub: a window this test just created is in it.
    @Test("the default window source reads the live application list")
    func defaultWindowSourceReadsTheApplication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let window = fixture.makeWindow()

        #expect(
            fixture.appDelegate.agentInboxWindowSources.windows()
                .contains(window)
        )
    }

    /// The Welcome source's default really is `visibleWelcomeWindow()`: it
    /// answers with a window carrying Welcome's identifier, and only while
    /// that window is on screen. This one default is verifiable in a
    /// background host because it reads window properties rather than
    /// application-wide focus state.
    ///
    /// Identity is deliberately not asserted: the test host is the real Pine
    /// application and may already own a Welcome window, and `Welcome` is a
    /// singleton — whichever one the source answers with must satisfy the same
    /// predicate.
    @Test("the default Welcome source finds a visible Welcome window")
    func defaultWelcomeSourceFindsWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.makeWelcomeWindow()
        let sources = fixture.appDelegate.agentInboxWindowSources

        let found = try #require(
            sources.welcomeWindow(),
            "a visible Welcome window exists, so the source must find one"
        )

        #expect(found.identifier?.rawValue == "welcome")
        #expect(found.isVisible)
        #expect(!found.isMiniaturized)
    }

    // MARK: - Windows in the Dock (#1507)

    /// The regression: `NSWindow.isVisible` reads `false` for a window in the
    /// Dock, so an eligibility test written as `isVisible` alone bypassed the
    /// user's minimized project and opened the Inbox in a freshly created
    /// Welcome window instead. The Inbox reach admits it; the presentation
    /// workflow deminiaturizes it before presenting.
    @Test("a project window in the Dock is still a candidate")
    func dockedProjectWindowIsACandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let window = try fixture.makeProjectWindow(named: "alpha", inDock: true)

        // The precondition the fix rests on, asserted rather than assumed.
        #expect(window.isMiniaturized)
        #expect(!window.isVisible)

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: nil,
            welcomeWindow: nil
        )

        #expect(options.count == 1)
        #expect(options.first?.candidate.isEligibleWindow == true)
        #expect(options.first?.host === window)
    }

    /// Widening the reach must not widen anything else. This window is in the
    /// Dock *and* its project has been closed into the registry's background
    /// set, so exactly one of the other conjuncts is false — and that alone
    /// is enough to refuse it.
    @Test("a Dock window whose project closed is still refused")
    func dockedWindowStillObeysTheOtherConjuncts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.makeProjectDirectory(named: "alpha")
        let manager = try #require(fixture.registry.projectManager(for: url))
        let window = fixture.makeWindow(inDock: true)
        fixture.attachCloseDelegate(
            to: window,
            projectURL: url,
            projectManager: manager
        )

        fixture.registry.closeProjectWindow(
            url,
            expectedManager: manager,
            expectedWindowGeneration: nil
        )

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: nil,
            welcomeWindow: nil
        )

        #expect(window.isMiniaturized)
        #expect(options.first?.candidate.isEligibleWindow == false)
    }

    /// #1507's headline shape: one project, minimized, no Welcome window in
    /// sight. Before the fix this produced `.createWelcomeHost` and left the
    /// project sitting in the Dock.
    @Test("a lone minimized project hosts the Inbox instead of a new Welcome")
    func loneMinimizedProjectWinsOverCreatingWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let window = try fixture.makeProjectWindow(named: "alpha", inDock: true)
        fixture.noteKeyWindowSession(showing: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [window],
            keyWindow: nil,
            welcomeWindow: nil
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        guard case .existingHost(let index) = decision else {
            Issue.record("Expected the minimized project, got \(decision)")
            return
        }
        #expect(options[index].host === window)
    }

    /// A minimized project the user was last working in outranks a Welcome
    /// window that happens to be on screen: Welcome is the fallback for when
    /// no project can host the Inbox, not a reason to abandon one.
    @Test("a minimized most-recent project outranks a visible Welcome")
    func minimizedMostRecentProjectOutranksVisibleWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectWindow(
            named: "alpha",
            inDock: true
        )
        let welcome = fixture.makeWelcomeWindow()
        fixture.noteKeyWindowSession(showing: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [project],
            keyWindow: nil,
            welcomeWindow: welcome
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        guard case .existingHost(let index) = decision else {
            Issue.record("Expected the minimized project, got \(decision)")
            return
        }
        #expect(options[index].host === project)
    }

    /// Two projects, one in the Dock: the window the user can already see and
    /// is typing in keeps the Inbox. Restoring a window from the Dock is only
    /// right when there is nothing better on screen.
    @Test("a key on-screen project still beats a minimized one")
    func keyOnScreenProjectBeatsMinimizedProject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let minimized = try fixture.makeProjectWindow(
            named: "alpha",
            inDock: true
        )
        let onScreen = try fixture.makeProjectWindow(named: "beta")
        // The minimized one is also the most recently active project, so the
        // key window has to win on its own merits.
        fixture.noteKeyWindowSession(showing: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [minimized, onScreen],
            keyWindow: onScreen,
            welcomeWindow: nil
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        #expect(options.allSatisfy { $0.candidate.isEligibleWindow })
        guard case .existingHost(let index) = decision else {
            Issue.record("Expected the key window, got \(decision)")
            return
        }
        #expect(options[index].host === onScreen)
    }

    /// The Welcome half of the same fix. The Inbox source accepts a Welcome
    /// window in the Dock, so the workflow restores the one that exists
    /// instead of reaching `.createWelcomeHost` for a window the user already
    /// has.
    @Test("the Inbox Welcome source finds a Welcome window in the Dock")
    func inboxWelcomeSourceFindsDockedWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let welcome = fixture.makeWelcomeWindow(inDock: true)

        let found = try #require(
            fixture.withOnlyOwnWelcomeWindow(welcome) {
                fixture.appDelegate.agentInboxWindowSources.welcomeWindow()
            },
            "a minimized Welcome window is a host the Inbox can restore"
        )

        #expect(found === welcome)
        #expect(found.isMiniaturized)
    }

    /// Every other caller wants a window that can show UI right now, and a
    /// window in the Dock cannot. The narrower lookup is what `showWelcome()`
    /// and the application dialog owner still read.
    @Test("the on-screen Welcome lookup refuses a Welcome window in the Dock")
    func onScreenWelcomeLookupRefusesDockedWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let welcome = fixture.makeWelcomeWindow(inDock: true)

        // Prime the `welcomeWindow` cache through the wider reach first: a
        // cached window must be re-checked against the caller's reach, not
        // handed back because it was once found.
        #expect(
            fixture.appDelegate.welcomeHostWindow(
                reach: .onScreenOrDock,
                windows: [welcome]
            ) === welcome
        )

        #expect(
            fixture.appDelegate.welcomeHostWindow(
                reach: .onScreenOnly,
                windows: [welcome]
            ) == nil
        )
    }

    /// Both windows in the Dock: the project the user was last in still wins,
    /// and the Inbox restores it rather than a Welcome window they minimized
    /// and stopped caring about.
    @Test("a minimized project outranks a minimized Welcome")
    func minimizedProjectOutranksMinimizedWelcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectWindow(
            named: "alpha",
            inDock: true
        )
        let welcome = fixture.makeWelcomeWindow(inDock: true)
        fixture.noteKeyWindowSession(showing: "alpha")

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [project],
            keyWindow: nil,
            welcomeWindow: welcome
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        guard case .existingHost(let index) = decision else {
            Issue.record("Expected the minimized project, got \(decision)")
            return
        }
        #expect(options[index].host === project)
    }

    /// No project at all and the only Welcome window is in the Dock. The
    /// decision must reuse it — creating a second Welcome window behind a
    /// minimized one is the duplicate-window shape #1507 reported.
    @Test("a minimized Welcome is reused instead of creating a second one")
    func minimizedWelcomeIsReusedNotDuplicated() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let welcome = fixture.makeWelcomeWindow(inDock: true)

        let options = fixture.appDelegate.agentInboxHostOptions(
            windows: [],
            keyWindow: nil,
            welcomeWindow: welcome
        )
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )

        guard case .existingHost(let index) = decision else {
            Issue.record("Expected the minimized Welcome, got \(decision)")
            return
        }
        #expect(options[index].host === welcome)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let appDelegate = AppDelegate()
        let registry: ProjectRegistry
        private let root: URL
        private let suiteName: String
        private let defaults: UserDefaults
        private var windows: [NSWindow] = []
        private var delegates: [AnyObject] = []
        private var sessions: [ProjectWindowSession] = []
        private var projectURLs: [String: URL] = [:]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "PineInboxHostOptions-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            suiteName = "AgentInboxHostOptionsTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(),
                // No `ps` polling: this suite is about window projection.
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
            appDelegate.registry = registry
        }

        func makeProjectDirectory(named name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            projectURLs[name] = url
            return url
        }

        func makeWindow(
            onScreen: Bool = true,
            inDock: Bool = false
        ) -> NSWindow {
            let window = DockableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: window.contentRect(forFrameRect: window.frame)
            )
            if onScreen {
                window.orderFront(nil)
            }
            window.isInDock = inDock
            windows.append(window)
            return window
        }

        /// A visible window backed by a project the registry really holds —
        /// the only shape that satisfies every eligibility conjunct.
        func makeProjectWindow(
            named name: String,
            onScreen: Bool = true,
            inDock: Bool = false
        ) throws -> NSWindow {
            let url = try makeProjectDirectory(named: name)
            let manager = try #require(registry.projectManager(for: url))
            let window = makeWindow(onScreen: onScreen, inDock: inDock)
            attachCloseDelegate(
                to: window,
                projectURL: url,
                projectManager: manager
            )
            return window
        }

        func attachCloseDelegate(
            to window: NSWindow,
            projectURL: URL,
            projectManager: ProjectManager
        ) {
            let delegate = CloseDelegate(
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate,
                original: nil
            )
            // `NSWindow.delegate` is weak; the test owns the lifetime.
            delegates.append(delegate)
            window.delegate = delegate
        }

        /// A window shaped like Welcome for `visibleWelcomeWindow()`: the
        /// identifier it scans for, a mounted content view, and on screen.
        @discardableResult
        func makeWelcomeWindow(inDock: Bool = false) -> NSWindow {
            let window = makeWindow(inDock: inDock)
            window.identifier = NSUserInterfaceItemIdentifier("welcome")
            return window
        }

        /// Runs `body` with every *other* Welcome-identified window in
        /// `NSApp.windows` temporarily anonymised, so a source that scans the
        /// live list answers about this fixture's window.
        ///
        /// The unit test host is one long-lived application: windows other
        /// suites ordered out still sit in `NSApp.windows` with their
        /// identifiers attached, and `first(where:)` finds the oldest one.
        /// The identifiers are restored before `body` returns, and the whole
        /// helper is synchronous, so no other main-actor test can observe the
        /// windows while they are anonymous.
        func withOnlyOwnWelcomeWindow<T>(
            _ window: NSWindow,
            _ body: () -> T
        ) -> T {
            let foreign = NSApp.windows.filter {
                $0 !== window && $0.identifier?.rawValue == "welcome"
            }
            for other in foreign {
                other.identifier = nil
            }
            defer {
                for other in foreign {
                    other.identifier = NSUserInterfaceItemIdentifier("welcome")
                }
            }
            return body()
        }

        func makeForeignDelegate() -> any NSWindowDelegate {
            let delegate = ForeignWindowDelegate()
            delegates.append(delegate)
            return delegate
        }

        func noteKeyWindowSession(showing name: String) {
            guard let url = projectURLs[name] else { return }
            let session = ProjectWindowSession(
                initialProjectURL: url,
                defaults: defaults
            )
            sessions.append(session)
            registry.noteKeyWindowSession(session)
        }

        func cleanup() {
            for window in windows {
                window.delegate = nil
                (window as? DockableWindow)?.isInDock = false
                window.orderOut(nil)
                window.identifier = nil
            }
            windows.removeAll()
            delegates.removeAll()
            for session in sessions {
                registry.unregisterWindowSession(session)
            }
            sessions.removeAll()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class ForeignWindowDelegate: NSObject, NSWindowDelegate {}

    /// A window that can report the AppKit facts of a window sitting in the
    /// Dock without a window server.
    ///
    /// The unit test host is a background application: `miniaturize(nil)`
    /// never reaches the Dock there, and it is animated and asynchronous even
    /// when it does, so a real minimize cannot be asserted deterministically.
    /// The staged facts are the ones measured on macOS 27.0 (26A5416b) — a
    /// miniaturized window reports `isMiniaturized == true` and `isVisible ==
    /// false` while staying in `NSApp.windows`.
    private final class DockableWindow: NSWindow {
        var isInDock = false

        override var isMiniaturized: Bool { isInDock }

        override var isVisible: Bool { isInDock ? false : super.isVisible }
    }
}
