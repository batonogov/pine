//
//  CommandOverlayHostedAnnouncementTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

/// Hosted end-to-end coverage for the VoiceOver selection announcements that
/// `QuickOpenView` and `SymbolNavigatorView` publish (#1497).
///
/// Serialized deliberately, but the trait buys less than it looks like. It
/// serializes only *this* suite's own tests, and the one genuinely blocking
/// call here is the 20 ms reentrant `RunLoop.main.run(until:)` drain in
/// `host(_:size:)` — so what the trait actually guarantees is that two drains
/// *of this suite* never nest inside one another. It says nothing about the
/// other hosted suites that drain the same main runloop without being
/// serialized against this one (`CommandPaletteHostedInteractionTests:303`,
/// `CommandOverlayViewTests:221`, `QuickTerminalContentHostedTests:105`,
/// `GlobalTabSwitcherOverlayHostedTests:400`). `settle` itself sleeps and
/// leaves the main actor free, so the waiting is not what needs serializing.
///
/// Time-limited deliberately: the settle gate below is budgeted in polls, not
/// in wall-clock time, so a genuinely broken view does not fail fast — it
/// spends its whole budget waiting. Without a ceiling that reads as a hung run
/// rather than a red test, which is exactly the unreadable failure mode #1506
/// was filed about. The limit applies per test, not per suite, and it
/// *tightens* the status quo: the bundle runs with `-test-timeouts-enabled
/// YES` and no `-default-test-execution-time-allowance`, so today every test
/// here inherits Xcode's 600-second default.
///
/// Three minutes, not one, and the headroom is sized from a measurement — but
/// a *local* one, so read it as a floor on the required slack rather than as
/// bundle behaviour. On CI (macos-26, `-parallel-testing-enabled NO`) the
/// whole bundle is 6744 tests in 396.658 s with zero retries, and this suite
/// is nowhere near any ceiling. Locally, on the toolchain recorded in
/// `settlePollBudget` below, the same bundle periodically wedges the main
/// thread hard enough that trivial tests doing no I/O at all record 59.7–61.8
/// seconds of elapsed time. A one-minute ceiling therefore has ample headroom
/// on CI and none at all on that local combination — it would stop being a
/// ceiling and start being a second lottery, which is what this change exists
/// to remove. Three minutes still turns a genuinely broken view red instead of
/// leaving it to hang, and stays far below the job's `timeout-minutes: 60`
/// (the current unit-test job finishes in 8 m 36 s). Precedent:
/// `ConcurrencyStressTests.swift:116`.
@Suite(
    "Hosted command overlay announcements",
    .serialized,
    .timeLimit(.minutes(3))
)
@MainActor
struct CommandOverlayHostedAnnouncementTests {
    /// Settle budget expressed in polls, not wall-clock time.
    ///
    /// In a local Xcode run `PineTests` executes its suites in parallel inside
    /// one process (parallelism is the default there), and unrelated suites
    /// block the main thread for seconds at a stretch —
    /// `GitStatusProviderTests` is `@MainActor` and runs `/bin/sh` through
    /// `process.waitUntilExit()`; `AgentHistoryCheckedUndoEngineTests` is
    /// `@MainActor` and blocks on `DispatchSemaphore.wait(timeout:)` for up to
    /// two seconds. A wall-clock deadline therefore measures how busy the rest
    /// of the bundle is, not whether this view settled: starvation burns the
    /// entire budget without the view ever getting a chance to run.
    ///
    /// This does **not** describe CI. Both `xcodebuild test` invocations pass
    /// `-parallel-testing-enabled NO` (`.github/workflows/ci.yml:324` and
    /// `:396`, enforced by `scripts/tests/test-xcodebuild-cli-options.sh`),
    /// so on CI the suites run one after another and the poll budget degrades
    /// to an ordinary 3-second deadline here (200 × 5 ms = 1 second in the
    /// unit suite). The budget is insurance for the local shape, not a
    /// description of the CI shape.
    ///
    /// The starvation numbers quoted in this file were measured locally on:
    /// macOS 27.0 (26A5416b), Xcode 27.0 (27A5237l), macosx SDK 27.0
    /// (26A5406c). They are a property of that combination, not of the test
    /// bundle: the same suites are quick and stable on the macos-26 runner.
    ///
    /// Budgeting in scheduling opportunities is strictly better, but it is
    /// still a budget, not determinism: it buys roughly 300 chances to observe
    /// the view instead of roughly 200, and a real product regression that
    /// needs somewhere between those two numbers now passes here where it used
    /// to fail. Deterministic settling would need a production seam —
    /// `CommandOverlaySelectionAnnouncer.init(delay:)` already accepts an
    /// injected delay, but no view forwards one and `QuickOpenView` hardcodes
    /// a 150 ms `Task.sleep` — and adding that seam is deliberately out of
    /// scope for a test-only change (#1506).
    private static let settlePollBudget = 300

    /// Wait between polls. Sleeping (rather than spinning on `Task.yield()`)
    /// hands the main actor back so the view's debounced search and
    /// announcement tasks can actually run.
    private static let settlePollInterval = Duration.milliseconds(10)

    @Test("Quick Open arrow navigation reaches the announcement sink")
    func quickOpenArrowAnnouncement() async throws {
        let projectManager = ProjectManager()
        // Unique per run, never the shared `/tmp/quick-open-announcement`.
        // That fixed path let machine state leak into the fixture two ways: a
        // stray `First.swift` *directory* there makes `collectFiles` drop the
        // entry, leaving one result and an unsatisfiable gate; and
        // `QuickOpenProvider.loadRecentFiles` reads `UserDefaults.standard`
        // under a key derived from the root path, so a previously recorded
        // recent file would boost `Second.swift` and flip the sort order that
        // `moveDown:` is asserted against (#1506).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        projectManager.workspace.rootURL = root
        projectManager.workspace.rootNodes = [
            FileNode(url: root.appendingPathComponent("First.swift")),
            FileNode(url: root.appendingPathComponent("Second.swift")),
        ]
        let recorder = HostedOverlayAnnouncementRecorder()
        let hosted = host(
            QuickOpenAnnouncementHarness(
                projectManager: projectManager,
                recorder: recorder
            ),
            size: NSSize(width: 500, height: 360)
        )
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        field.stringValue = "swift"
        coordinator.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))
        // Hard precondition, not a soft one: until the summary lands the view
        // still holds zero results, `moveSelection` short-circuits, and every
        // assertion below would be measuring the wrong thing.
        try #require(
            await settle {
                recorder.messages.contains { $0.hasPrefix("2 results.") }
            },
            """
            Hosted Quick Open never published its result summary; \
            recorded \(recorder.messages).
            """
        )

        // Keep the recorder's history intact instead of clearing it: the
        // announcer's duplicate-suppression boundary is private to the view,
        // so a cleared recorder and a live `lastDeliveredMessage` would
        // disagree about what has already been spoken.
        let baseline = recorder.messages.count
        // Note: this only proves the selector was consumed — the coordinator
        // returns `true` for `moveDown:` whether or not anything was announced.
        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        // Soft count first: `announcement(in:after:)` throws, so anything
        // ordered after it is missing from the failure report exactly when
        // the report matters most.
        #expect(recorder.messages.count == baseline + 1)
        let announced = try announcement(in: recorder, after: baseline)
        #expect(announced.contains("Second.swift"))
        withExtendedLifetime(hosted) {}
    }

    @Test("Symbol Navigator arrow navigation reaches the announcement sink")
    func symbolNavigatorArrowAnnouncement() async throws {
        let projectManager = ProjectManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/HostedSymbols.swift"),
            content: "func alpha() {}\nfunc beta() {}\n",
            savedContent: "func alpha() {}\nfunc beta() {}\n"
        )
        projectManager.primaryTabManager.tabs = [tab]
        projectManager.primaryTabManager.activeTabID = tab.id
        let recorder = HostedOverlayAnnouncementRecorder()
        let hosted = host(
            SymbolNavigatorAnnouncementHarness(
                projectManager: projectManager,
                recorder: recorder
            ),
            size: NSSize(width: 500, height: 360)
        )
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        try #require(
            await settle {
                recorder.messages.contains { $0.hasPrefix("2 results.") }
            },
            """
            Hosted Symbol Navigator never published its result summary; \
            recorded \(recorder.messages).
            """
        )

        let baseline = recorder.messages.count
        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(recorder.messages.count == baseline + 1)
        let announced = try announcement(in: recorder, after: baseline)
        #expect(announced.contains("beta"))
        withExtendedLifetime(hosted) {}
    }

    // MARK: - Failure-path regressions (#1506)

    @Test("An empty recorder fails the announcement read instead of trapping")
    func emptyRecorderFailsWithoutTrapping() throws {
        let recorder = HostedOverlayAnnouncementRecorder()
        var continuedPastRead = false

        // `try` only because the `matching:` overload is `rethrows` for the
        // `when:` short-circuit; with the default precondition the body's
        // error is always absorbed here.
        try withKnownIssue(
            "Deliberate empty-recorder read: it must fail, never trap."
        ) {
            _ = try announcement(in: recorder, after: 0)
            continuedPastRead = true
        } matching: { Self.isExpectationFailure($0) }

        #expect(continuedPastRead == false)
        // Reaching this line at all is the regression: a bare `messages[0]`
        // raises `EXC_BREAKPOINT`, which Swift Testing cannot contain, and the
        // whole `PineTests` process dies with every unrelated test in it.
        #expect(recorder.record("process survived the failed read"))
        #expect(recorder.messages.count == 1)
    }

    @Test("A stale baseline fails the announcement read instead of trapping")
    func staleBaselineFailsWithoutTrapping() throws {
        let recorder = HostedOverlayAnnouncementRecorder()
        #expect(recorder.record("2 results. Selected: First.swift"))
        var continuedPastRead = false

        // Nothing was announced after the summary, so the read must fail even
        // though the recorder itself is non-empty.
        try withKnownIssue("Deliberate short-recorder read: it must fail.") {
            _ = try announcement(in: recorder, after: 1)
            continuedPastRead = true
        } matching: { Self.isExpectationFailure($0) }

        #expect(continuedPastRead == false)
        #expect(recorder.messages.count == 1)
    }

    @Test("The settle gate resolves on the first poll when already satisfied")
    func settleResolvesWithoutYielding() async {
        var polls = 0
        var sleeps = 0
        let settled = await settle(
            sleeper: { _ in sleeps += 1 },
            condition: {
                polls += 1
                return true
            }
        )

        #expect(settled)
        #expect(polls == 1)
        // `polls == 1` alone would also hold for a "sleep first, then check"
        // gate, which is the shape this test exists to rule out: it would add
        // a poll interval of latency to every already-satisfied wait. The
        // sleep spy is what rules it out, and it does so structurally — an
        // elapsed-time bound here would be the one assertion in this file
        // whose outcome depends on the host scheduler rather than on observed
        // state, in a suite whose entire premise is that wall-clock readings
        // in this process measure someone else's load.
        #expect(
            sleeps == 0,
            "Settle gate slept \(sleeps) time(s) before its first check."
        )
    }

    @Test("A never-satisfied settle gate terminates and fails softly")
    func unsettledGateFailsWithoutTrapping() async {
        var polls = 0
        var sleeps = 0
        let settled = await settle(
            pollBudget: 3,
            sleeper: { _ in sleeps += 1 },
            condition: {
                polls += 1
                return false
            }
        )

        #expect(settled == false)
        // Three budgeted polls plus one final re-check after the last sleep.
        #expect(polls == 4)
        #expect(sleeps == 3)
    }

    @Test("The settle gate accepts a condition that only becomes true later")
    func settleObservesLateCondition() async {
        var polls = 0
        var sleeps = 0
        let settled = await settle(
            pollBudget: 10,
            sleeper: { _ in sleeps += 1 },
            condition: {
                polls += 1
                return polls >= 3
            }
        )
        #expect(settled)
        #expect(polls == 3)
        // One sleep between each pair of polls, none after the last.
        #expect(sleeps == 2)
    }

    @Test("The settle gate re-checks once and stops when the sleeper throws")
    func settleStopsWhenSleepIsCancelled() async {
        var polls = 0
        // Stands in for `.timeLimit` cancelling `Task.sleep`: the gate must
        // report on what it can observe *now* rather than burning the rest of
        // its budget and adding a second issue on top of the time-limit one.
        let settled = await settle(
            pollBudget: 100,
            sleeper: { _ in throw CancellationError() },
            condition: {
                polls += 1
                return polls >= 3
            }
        )
        #expect(settled == false)
        // One budgeted poll, one throwing sleep, one final re-check.
        #expect(polls == 2)
    }

    // MARK: - Helpers

    /// Reads the announcement recorded after `baseline`.
    ///
    /// Every hosted assertion funnels through here on purpose. A direct
    /// `recorder.messages[0]` after a *soft* count expectation turns one failed
    /// expectation into an `EXC_BREAKPOINT` that takes the entire `PineTests`
    /// process down (#1506); `#require` throws instead, so the test fails and
    /// the process keeps running.
    private func announcement(
        in recorder: HostedOverlayAnnouncementRecorder,
        after baseline: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        try #require(
            recorder.messages.dropFirst(baseline).first,
            """
            Expected an announcement after index \(baseline); \
            recorded \(recorder.messages).
            """,
            sourceLocation: sourceLocation
        )
    }

    /// Whether `issue` is an expectation failure rather than some other kind
    /// of recorded issue.
    ///
    /// Used to narrow `withKnownIssue` so it swallows only the failure the
    /// test deliberately provokes. Both branches are load-bearing across
    /// swift-testing versions: a failed `#require` records
    /// `.expectationFailed` and throws `ExpectationFailedError`, and which of
    /// the two the recorded issue carries is an implementation detail of the
    /// framework, not something this test should depend on.
    nonisolated private static func isExpectationFailure(
        _ issue: Issue
    ) -> Bool {
        if case .expectationFailed = issue.kind { return true }
        return issue.error is ExpectationFailedError
    }

    /// Polls `condition` on the main actor, sleeping between attempts.
    ///
    /// Budgeted in polls rather than elapsed time — see `settlePollBudget`
    /// for what that trades away. The suite-level `.timeLimit` is the ceiling
    /// that keeps an unsatisfiable budget from reading as a hung run.
    ///
    /// `sleeper` is injectable so the gate's own behaviour can be asserted
    /// structurally — "did it sleep before the first check" is a question
    /// about the loop, and answering it by reading a clock inside this
    /// process would reintroduce exactly the wall-clock dependency #1506 is
    /// about. Production call sites take the default.
    ///
    /// A throwing sleeper ends the wait after one more check rather than
    /// being swallowed. That matters when the suite `.timeLimit` fires:
    /// `Task.sleep` throws `CancellationError`, and a `try?` here would let
    /// the loop grind through its remaining budget and then return `false`,
    /// so the caller's `#require` would stack a second issue on top of
    /// `timeLimitExceeded` — two failures for one cause, in a report whose
    /// readability is the whole point of #1506.
    private func settle(
        pollBudget: Int = CommandOverlayHostedAnnouncementTests
            .settlePollBudget,
        sleeper: @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<pollBudget {
            if condition() { return true }
            do {
                try await sleeper(Self.settlePollInterval)
            } catch {
                return condition()
            }
        }
        return condition()
    }

    private func host<Content: View>(
        _ content: Content,
        size: NSSize
    ) -> NSHostingView<Content> {
        let hosted = NSHostingView(rootView: content)
        hosted.frame = NSRect(origin: .zero, size: size)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField {
            return field
        }
        for subview in view.subviews {
            if let field = findTextField(in: subview) {
                return field
            }
        }
        return nil
    }
}

@MainActor
private final class HostedOverlayAnnouncementRecorder {
    var messages: [String] = []

    func record(_ message: String) -> Bool {
        messages.append(message)
        return true
    }
}

private struct QuickOpenAnnouncementHarness: View {
    let projectManager: ProjectManager
    let recorder: HostedOverlayAnnouncementRecorder

    var body: some View {
        QuickOpenView(
            isPresented: .constant(true),
            onAnnounce: recorder.record
        )
        .environment(projectManager)
        .environment(\.locale, Locale(identifier: "en"))
    }
}

private struct SymbolNavigatorAnnouncementHarness: View {
    let projectManager: ProjectManager
    let recorder: HostedOverlayAnnouncementRecorder

    var body: some View {
        SymbolNavigatorView(
            isPresented: .constant(true),
            onAnnounce: recorder.record
        )
        .environment(projectManager)
        .environment(\.locale, Locale(identifier: "en"))
    }
}
