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

    /// Leaving the screen is what costs a window its eligibility, and the same
    /// `isVisible` conjunct decides it. A window ordered out is the one form
    /// of "not on screen" this suite can produce: the unit test host is a
    /// background application, where `miniaturize(nil)` never reaches the
    /// Dock, so *minimized* is asserted nowhere here.
    ///
    /// On a real desktop AppKit reports `isVisible == false` for a window in
    /// the Dock too, which is why a minimized project window silently loses
    /// the Inbox to Welcome instead of being restored (#1507). That behavior
    /// is documented in `agentInboxHostOptions`, not claimed as covered.
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
        #expect(options.map(\.host) == [alpha, beta, welcome])
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

        func makeWindow(onScreen: Bool = true) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: window.contentRect(forFrameRect: window.frame)
            )
            if onScreen {
                window.orderFront(nil)
            }
            windows.append(window)
            return window
        }

        /// A visible window backed by a project the registry really holds —
        /// the only shape that satisfies every eligibility conjunct.
        func makeProjectWindow(
            named name: String,
            onScreen: Bool = true
        ) throws -> NSWindow {
            let url = try makeProjectDirectory(named: name)
            let manager = try #require(registry.projectManager(for: url))
            let window = makeWindow(onScreen: onScreen)
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
        func makeWelcomeWindow() -> NSWindow {
            let window = makeWindow()
            window.identifier = NSUserInterfaceItemIdentifier("welcome")
            return window
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
                window.orderOut(nil)
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
}
