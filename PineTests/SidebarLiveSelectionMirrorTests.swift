//
//  SidebarLiveSelectionMirrorTests.swift
//  PineTests
//
//  Hosted coverage for the live selection mirror of #1544: the keyboard
//  path reads `SidebarTreeNavigation.currentSelection`, which every
//  selection writer updates in the same step as the binding. The three
//  cases here execute the fix through the production view in a real
//  window:
//
//  1. The core #1544 journey: a press opens a folder and writes the
//     selection through the mirroring setter, and the Left command must
//     observe it and collapse the folder.
//  2. A SidebarView that re-mounts after the search branch continues
//     keyboard navigation from the selected row — Down moves past it, not
//     back to the first row.
//  3. A reload after such a re-mount reconciles from the seeded mirror
//     (`onChange(of:, initial: true)`) and keeps the externally-written
//     selection visible — without the initial seed, reconciliation reads
//     `nil` and erases the selection. This is the case that fails
//     deterministically when the seed is removed.
//
//  Keyboard commands are dispatched through the responder's `onCommand`
//  closure, which `updateNSView` keeps current — the same dispatch point
//  the AppKit key path uses.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar live selection mirror", .serialized)
@MainActor
struct SidebarLiveSelectionMirrorTests {

    // MARK: - Cases

    @Test("A press-driven selection reaches the keyboard path and collapses")
    func pressSelectionThenLeftCollapses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tearDown() }

        guard let alphaRow = await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_alpha", in: fixture.hosting)
        }) else {
            Issue.record("alpha accessibility row never appeared")
            return
        }
        guard alphaRow.accessibilityPerformPress() else {
            Issue.record("production press was refused")
            return
        }
        guard await waitFor(seconds: 2, until: {
            alphaRow.accessibilityValue() as? String
                == Strings.a11ySidebarDisclosureExpanded
        }) else {
            Issue.record("row never reported expanded after press")
            return
        }

        // This is the core #1544 journey: the press both expands the folder
        // and writes the selection through `mirroredSelection` — the same
        // setter step that updates the live mirror — and the Left command
        // must observe that selection and collapse the folder. (The
        // safety-net `onChange` for writes made outside the sidebar has no
        // distinct collapse case of its own: any external write equal to
        // the current selection is a no-op, and one that differs moves the
        // collapse target. Its coverage lives in the initial-seed branch
        // exercised by the reload case below.)
        guard await waitFor(seconds: 2, until: {
            Self.responder(in: fixture.hosting) != nil
        }) else {
            Issue.record("sidebar responder never appeared")
            return
        }

        #expect(
            await dispatchCommand(.left, in: fixture.hosting) {
                alphaRow.accessibilityValue() as? String
                    == Strings.a11ySidebarDisclosureCollapsed
            },
            "Left must collapse the folder opened by the press"
        )
    }

    @Test("A re-mounted sidebar seeds the mirror, so Down continues past the selection")
    func mirrorSeededWhenViewReinsertedWithLiveSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tearDown() }

        guard await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_alpha", in: fixture.hosting) != nil
        }) else {
            Issue.record("file tree never appeared")
            return
        }

        // Select alpha externally while the first sidebar is mounted.
        let alpha = try #require(
            fixture.projectManager.workspace.rootNodes
                .first { $0.name == "alpha" }
        )
        fixture.selectExternally(alpha)

        // Leave and return from the search branch: the returning SidebarView
        // owns a *fresh* @State navigation, while the harness-side selection
        // state (the ContentView stand-in) still holds alpha.
        fixture.projectManager.searchProvider.query = "inside"
        guard await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_alpha", in: fixture.hosting) == nil
        }) else {
            Issue.record("search branch did not replace the file tree")
            return
        }
        fixture.projectManager.searchProvider.query = ""
        let alphaRow = await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_alpha", in: fixture.hosting)
        })
        guard let alphaRow else {
            Issue.record("file tree did not return after clearing the query")
            return
        }
        guard await waitFor(seconds: 2, until: {
            alphaRow.isAccessibilitySelected()
        }) else {
            Issue.record("binding selection was not restored to the row")
            return
        }

        // The search-branch transition briefly mounts transitional sidebar
        // epochs; dispatching the command to *every* mounted responder until
        // the effect lands makes the check immune to which epoch survives.
        // This case pins the *behaviour* with a live seed — Down continues
        // from the selected row after a re-mount — not the seed itself:
        // a stale-epoch dispatch can re-select alpha through the mirroring
        // writer, so a missing initial seed alone would not necessarily
        // fail this wait. The seed's deterministic red/green is pinned by
        // reconcileAfterReloadPreservesExternalSelection below.
        let betaRow = await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_beta", in: fixture.hosting)
        })
        guard let betaRow else {
            Issue.record("beta row not found")
            return
        }
        #expect(
            await dispatchCommand(
                .down,
                in: fixture.hosting,
                until: { betaRow.isAccessibilitySelected() }
            ),
            "Down should select the row after the externally selected folder"
        )
        #expect(
            await waitFor(seconds: 1, until: { !alphaRow.isAccessibilitySelected() }),
            "Down must not re-select the previously selected row"
        )
    }

    @Test("Reload reconciliation preserves an external selection across a re-mount")
    func reconcileAfterReloadPreservesExternalSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tearDown() }

        guard await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_root-file.swift", in: fixture.hosting)
                != nil
        }) else {
            Issue.record("file tree never appeared")
            return
        }

        let rootFile = try #require(
            fixture.projectManager.workspace.rootNodes
                .first { $0.name == "root-file.swift" }
        )
        fixture.selectExternally(rootFile)

        // Re-mount the sidebar, then trigger the production refresh path:
        // a file appears on disk and the workspace reloads the tree, which
        // routes through reconcileSelectionAfterReload.
        fixture.projectManager.searchProvider.query = "inside"
        guard await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_root-file.swift", in: fixture.hosting)
                == nil
        }) else {
            Issue.record("search branch did not replace the file tree")
            return
        }
        fixture.projectManager.searchProvider.query = ""
        guard let rootFileRow = await waitFor(seconds: 3, until: {
            Self.row(named: "fileNode_root-file.swift", in: fixture.hosting)
        }) else {
            Issue.record("file tree did not return after clearing the query")
            return
        }
        guard await waitFor(seconds: 2, until: {
            rootFileRow.isAccessibilitySelected()
        }) else {
            Issue.record("binding selection was not restored to the row")
            return
        }

        let revisionBefore = fixture.projectManager.workspace.rootNodesRevision
        try "// fresh".write(
            to: fixture.directory.appendingPathComponent("fresh-file.swift"),
            atomically: true,
            encoding: .utf8
        )
        fixture.projectManager.workspace.refreshFileTree()
        guard await waitFor(seconds: 5, until: {
            fixture.projectManager.workspace.rootNodesRevision
                > revisionBefore
        }) else {
            Issue.record("workspace never reloaded the tree")
            return
        }

        #expect(
            await waitFor(seconds: 3, until: {
                rootFileRow.isAccessibilitySelected()
            }),
            "Reload reconciliation must keep the externally written selection"
        )
    }

    // MARK: - Fixture

    private final class Fixture {
        let projectManager: ProjectManager
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        let directory: URL
        private let external: ExternalSelectionWriter

        init(
            projectManager: ProjectManager,
            hosting: NSHostingView<AnyView>,
            window: NSWindow,
            directory: URL,
            external: ExternalSelectionWriter
        ) {
            self.projectManager = projectManager
            self.hosting = hosting
            self.window = window
            self.directory = directory
            self.external = external
        }

        /// Writes the selection the way sidebar-external writers do: the
        /// harness host applies it to its `@State`, exactly like
        /// `ContentView.syncSidebarSelection` writes `selectedNode`.
        func selectExternally(_ node: FileNode?) {
            external.write(node)
        }

        func tearDown() {
            projectManager.workspace.suspend()
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Stand-in for ContentView's `@State var selectedNode`: the harness
    /// host owns the state, and external writers signal through this
    /// observable channel so the write lands in real SwiftUI state with a
    /// real invalidation pass — not in a plain box the view graph cannot
    /// observe.
    @Observable
    final class ExternalSelectionWriter {
        private(set) var node: FileNode?
        private(set) var generation = 0

        func write(_ node: FileNode?) {
            self.node = node
            generation &+= 1
        }
    }

    /// The hosted ContentView stand-in: owns the selection `@State`, feeds
    /// `SidebarSearchableContent` exactly as the project window does, and
    /// applies external selection writes to that state on their own graph
    /// pass.
    private struct HarnessHost: View {
        @State private var selection: FileNode?
        let projectManager: ProjectManager
        let external: ExternalSelectionWriter

        var body: some View {
            SidebarSearchableContent(
                selectedNode: $selection,
                onFileOpen: { _, _ in }
            )
            .environment(projectManager)
            .environment(projectManager.workspace)
            .environment(projectManager.paneManager)
            .environment(projectManager.primaryTabManager)
            .environment(ProjectRegistry())
            .frame(minWidth: 700, minHeight: 480)
            .onChange(of: external.generation) { _, _ in
                selection = external.node
            }
        }
    }

    private func makeFixture() async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1544-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("alpha"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("beta"),
            withIntermediateDirectories: true
        )
        try "// alpha".write(
            to: dir.appendingPathComponent("alpha/inside-alpha.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "// beta".write(
            to: dir.appendingPathComponent("beta/inside-beta.txt"),
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

        let external = ExternalSelectionWriter()
        let rootView = HarnessHost(
            projectManager: projectManager,
            external: external
        )

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
            directory: dir,
            external: external
        )
    }

    // MARK: - Helpers

    /// Dispatches `command` to every mounted sidebar responder on each
    /// runloop hop until `condition` holds or the deadline passes. A hosted
    /// mount can briefly keep transitional sidebar epochs with stale
    /// bindings; delivering to all of them makes the observable effect
    /// independent of which epoch happens to be reachable first.
    ///
    /// The check runs *before* each dispatch: if the previous dispatch has
    /// already produced the effect but its render has not committed yet,
    /// dispatching again would overshoot the target row and clamp to the
    /// last row, failing a condition that was actually met.
    private func dispatchCommand(
        _ command: SidebarKeyboardCommand,
        in hosting: NSHostingView<AnyView>,
        until condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await hopRunloop()
            if condition() {
                return true
            }
            Self.forEachResponder(in: hosting) {
                $0.onCommand?(command)
            }
        }
        return false
    }

    private static func forEachResponder(
        in view: NSView,
        _ body: (SidebarKeyboardResponderView) -> Void
    ) {
        if let responder = view as? SidebarKeyboardResponderView {
            body(responder)
        }
        for subview in view.subviews {
            forEachResponder(in: subview, body)
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

    private static func responder(in view: NSView) -> SidebarKeyboardResponderView? {
        if let responder = view as? SidebarKeyboardResponderView {
            return responder
        }
        for subview in view.subviews {
            if let responder = responder(in: subview) {
                return responder
            }
        }
        return nil
    }
}

/// Off-screen hosted window that could become key but never does here.
private final class HostedTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
