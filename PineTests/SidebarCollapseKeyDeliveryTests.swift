//
//  SidebarCollapseKeyDeliveryTests.swift
//  PineTests
//
//  Delivery smoke and escape coverage for the #1544 sidebar collapse flake.
//
//  The #1544 evidence chain: the collapse command path (responder keyDown
//  -> handleSidebarCommand -> setExpanded -> render) is a single indivisible
//  state, so a lost collapse means the key never reached the responder.
//  A hosted experiment (see the issue discussion) isolated the ancestor
//  `onKeyPress(.escape)` that used to sit over both branches of
//  `SidebarSearchableContent` as the delivery interceptor: without it the
//  window delivered Left-arrow 8/8 across the post-press timing window;
//  with it, 0/8 in four harness configurations, while first responder and
//  the direct command path stayed healthy. The exact platform mechanism
//  (which focus state arms the hosting-layer claim) is not established,
//  and this harness does not reproduce the production window
//  (NavigationSplitView + .searchable), so the final regression gate for
//  the flake is the CI `SidebarFolderClickTests` run; an A/B run on the
//  probe branch supplies the numbers.
//
//  What this suite does lock down:
//  1. Delivery smoke — a real Left-arrow posted straight into the hosted
//     production sidebar window collapses an expanded folder through the
//     AppKit responder, with no reliance on process-wide key-window state.
//  2. Escape coverage — the relocated `.onKeyPress(.escape)` handler
//     clears an active search query and returns the file tree, the
//     behaviour SearchResultsView deliberately forwards to it
//     (`.dismissSearch` -> `.ignored` bubbles up).
//
//  Window scheme follows the hosted-suite convention (see
//  AgentHistoryUndoReviewHostedTests / AccessibilityTreeProbe): an
//  off-screen, never-key window so parallel hosted suites keep their own
//  key-window assumptions, `isReleasedWhenClosed = false` plus an explicit
//  close so the window does not linger in `NSApp.windows`, and the
//  workspace watcher suspended before the fixture directory is removed.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar collapse key delivery", .serialized)
@MainActor
struct SidebarCollapseKeyDeliveryTests {

    @Test(
        "Collapse keystroke posted to the sidebar window collapses an expanded folder",
        arguments: [0.05, 0.3, 1.1]
    )
    func collapseKeystrokeCollapsesExpandedFolder(pressDelay: Double) async throws {
        let outcome = await collapseOutcome(afterPressDelay: pressDelay)

        switch outcome {
        case .delivered:
            break
        case .lostButCommandPathAlive:
            Issue.record(CollapseDeliveryLoss())
        case .harnessUnhealthy(let stage):
            Issue.record("delivery harness failed at stage: \(stage)")
        }
    }

    @Test("Clearing an active search query returns the file tree branch")
    func clearingActiveSearchReturnsFileTree() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tearDown() }

        // Open the search branch: a non-empty query renders SearchResultsView.
        fixture.projectManager.searchProvider.query = "alpha"

        let searchBranchShown = await waitFor(seconds: 3) {
            // The file-tree branch's accessibility row disappears once the
            // search branch replaces it in the same hosted hierarchy.
            Self.row(named: "fileNode_alpha", in: fixture.hosting) == nil
        }
        guard searchBranchShown else {
            Issue.record("search branch did not replace the file tree")
            return
        }

        // The relocated `.onKeyPress(.escape)` handler performs exactly
        // these two calls. SwiftUI key handlers need SwiftUI focus, which a
        // hosted window cannot grant to this branch (the list focus state is
        // private to SearchResultsView), so the key stroke itself cannot be
        // replayed here — the handler's effect on the branch selection is
        // what this case locks down instead.
        fixture.projectManager.searchProvider.query = ""
        fixture.projectManager.searchProvider.cancel()

        let treeRestored = await waitFor(seconds: 3) {
            Self.row(named: "fileNode_alpha", in: fixture.hosting) != nil
        }
        #expect(
            treeRestored,
            "File tree should return after the search query clears"
        )
    }

    // MARK: - Outcomes

    private enum CollapseOutcome {
        case delivered
        case lostButCommandPathAlive
        case harnessUnhealthy(String)
    }

    // MARK: - Fixture

    private final class Fixture {
        let projectManager: ProjectManager
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        let directory: URL

        init(
            projectManager: ProjectManager,
            hosting: NSHostingView<AnyView>,
            window: NSWindow,
            directory: URL
        ) {
            self.projectManager = projectManager
            self.hosting = hosting
            self.window = window
            self.directory = directory
        }

        /// Suspends the workspace watcher, closes the window (removing it
        /// from `NSApp.windows`), then removes the fixture directory —
        /// in that order, so no live watcher observes the directory vanish.
        func tearDown() {
            projectManager.workspace.suspend()
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1544-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("alpha"),
            withIntermediateDirectories: true
        )
        try "// alpha".write(
            to: dir.appendingPathComponent("alpha/inside-alpha.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "// root".write(
            to: dir.appendingPathComponent("root-file.swift"),
            atomically: true,
            encoding: .utf8
        )

        let projectManager = ProjectManager()
        projectManager.workspace.loadDirectory(url: dir)
        let published = await waitFor(seconds: 5) {
            projectManager.workspace.rootNodes.contains { $0.name == "alpha" }
        }
        guard published else {
            projectManager.workspace.suspend()
            try? FileManager.default.removeItem(at: dir)
            throw CocoaError(.fileNoSuchFile)
        }

        let selection = SelectionBox()
        let rootView = SidebarSearchableContent(
            selectedNode: Binding(
                get: { selection.node },
                set: { selection.node = $0 }
            ),
            onFileOpen: { _, _ in }
        )
        .environment(projectManager)
        .environment(projectManager.workspace)
        .environment(projectManager.paneManager)
        .environment(projectManager.primaryTabManager)
        .environment(ProjectRegistry())
        .frame(minWidth: 700, minHeight: 480)

        let hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
        let window = HostedTestWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Ordered in off-screen, never made key: `NSApp.keyWindow` is
        // process-wide state other hosted suites assert against.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        return Fixture(
            projectManager: projectManager,
            hosting: hosting,
            window: window,
            directory: dir
        )
    }

    // MARK: - Delivery harness

    /// Presses the production folder row (accessibility press) and posts one
    /// real Left-arrow into the hosted window at `pressDelay` seconds after
    /// the press, sampled across the focus-claim window the press opens.
    private func collapseOutcome(afterPressDelay pressDelay: Double) async -> CollapseOutcome {
        let fixture: Fixture
        do {
            fixture = try await makeFixture()
        } catch {
            return .harnessUnhealthy("fixture setup failed")
        }
        defer { fixture.tearDown() }

        guard let alphaRow = await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_alpha", in: fixture.hosting)
        }) else {
            return .harnessUnhealthy("alpha accessibility row never appeared")
        }
        guard alphaRow.accessibilityPerformPress() else {
            return .harnessUnhealthy("production press was refused")
        }

        guard await waitFor(seconds: 2, until: {
            alphaRow.accessibilityValue() as? String
                == Strings.a11ySidebarDisclosureExpanded
        }) else {
            return .harnessUnhealthy("row never reported expanded after press")
        }

        try? await Task.sleep(for: .milliseconds(UInt64(pressDelay * 1000)))

        guard let responder = fixture.window.firstResponder
            as? SidebarKeyboardResponderView else {
            return .harnessUnhealthy(
                "sidebar responder does not hold first responder"
            )
        }

        sendKey(
            to: fixture.window,
            characters: "\u{F702}",
            keyCode: 123
        )

        if await waitFor(seconds: 3, until: {
            alphaRow.accessibilityValue() as? String
                == Strings.a11ySidebarDisclosureCollapsed
        }) {
            return .delivered
        }

        // Control arm: the command the responder would have dispatched. If
        // this collapses the row, the model, state, and rendering are all
        // healthy — the miss above was an event-delivery loss, which is the
        // #1544 failure mode.
        responder.onCommand?(.left)
        if await waitFor(seconds: 3, until: {
            alphaRow.accessibilityValue() as? String
                == Strings.a11ySidebarDisclosureCollapsed
        }) {
            return .lostButCommandPathAlive
        }
        return .harnessUnhealthy("even the direct command path did not collapse")
    }

    /// Synchronous, window-addressed key delivery: the hosting layer's
    /// key-equivalent claim first, then the window's own event routing.
    /// Nothing enters the process-wide application event queue.
    private func sendKey(
        to window: NSWindow,
        characters: String,
        keyCode: UInt16
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            Issue.record("Could not construct a hosted key event")
            return
        }
        if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
    }

    /// Wall-clock bounded wait: hops the runloop until `condition` holds or
    /// the deadline passes. Hop counts are not a budget — a loaded runner
    /// can need many hops before SwiftUI commits one update.
    private func waitFor<T>(
        seconds: TimeInterval,
        until condition: @escaping () -> T?
    ) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            await hopRunloop()
            if let value = condition() {
                return value
            }
        }
        return nil
    }

    private func waitFor(
        seconds: TimeInterval,
        until condition: @escaping () -> Bool
    ) async -> Bool {
        await waitFor(seconds: seconds) { condition() ? true : nil } != nil
    }

    private func hopRunloop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private static func row(
        named identifier: String,
        in view: NSView
    ) -> SidebarAccessibilityRowView? {
        if let row = view as? SidebarAccessibilityRowView,
           row.accessibilityIdentifier() == identifier {
            return row
        }
        for subview in view.subviews {
            if let row = row(named: identifier, in: subview) {
                return row
            }
        }
        return nil
    }
}

/// Off-screen hosted window that could become key but never does here.
private final class HostedTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Shared mutable selection backing the sidebar binding.
private final class SelectionBox: @unchecked Sendable {
    var node: FileNode?
}

/// Describes the #1544 failure mode: a navigation key was lost in event
/// delivery while the collapse command path stayed alive.
private struct CollapseDeliveryLoss: Error, CustomStringConvertible {
    var description: String {
        "Left-arrow was lost between the window and the responder's "
            + "keyDown while the direct command path still collapses the "
            + "row — a delivery interception, the failure mode behind #1544"
    }
}
