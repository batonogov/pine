//
//  FindStepTargetPolicyTests.swift
//  PineTests
//
//  Issue #1551 — ⌘G / ⇧⌘G must reach a visible terminal search bar.
//  Locks the window-wide routing policy branch by branch: active pane's bar
//  wins, a lone visible bar wins even when focus is in the editor, ambiguity
//  and "nothing visible" stay with the editor, and the menu gate keeps its
//  pre-#1551 editor behavior.
//

import Testing
@testable import Pine

@Suite("Find Step Target Policy (⌘G / ⇧⌘G routing)")
struct FindStepTargetPolicyTests {

    // MARK: - Active pane's visible bar wins

    @Test("The active pane's own visible bar wins when it is the only one")
    func activePaneBarWinsWhenSingle() {
        let bar = PaneID()
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: bar,
                visibleTerminalSearchPaneIDs: [bar]
            ) == .terminal(bar)
        )
    }

    @Test("The active pane's bar wins even when several bars are visible")
    func activePaneBarWinsAmongSeveral() {
        let first = PaneID()
        let second = PaneID()
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: first,
                visibleTerminalSearchPaneIDs: [first, second]
            ) == .terminal(first)
        )
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: second,
                visibleTerminalSearchPaneIDs: [first, second]
            ) == .terminal(second)
        )
    }

    // MARK: - A lone visible bar wins without focus

    @Test("A bar open in a non-active pane wins when it is the only one")
    func loneBackgroundBarWins() {
        let terminalPane = PaneID()
        let editorPane = PaneID()
        // The exact reported gap: focus moved into the editor, bar stays open.
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: editorPane,
                visibleTerminalSearchPaneIDs: [terminalPane]
            ) == .terminal(terminalPane)
        )
    }

    @Test("A bar wins when the active terminal pane itself has none open")
    func loneBarWinsOverUnsearchedActiveTerminal() {
        let searched = PaneID()
        let focusedTerminal = PaneID()
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: focusedTerminal,
                visibleTerminalSearchPaneIDs: [searched]
            ) == .terminal(searched)
        )
    }

    // MARK: - The editor keeps the command

    @Test("No visible bar leaves the command with the editor")
    func noBarsFallsBackToEditor() {
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: PaneID(),
                visibleTerminalSearchPaneIDs: []
            ) == .editor
        )
    }

    @Test("Several background bars with none in the active pane are ambiguous")
    func severalBackgroundBarsFallBackToEditor() {
        let first = PaneID()
        let second = PaneID()
        let editorPane = PaneID()
        #expect(
            FindStepTargetPolicy.target(
                activePaneID: editorPane,
                visibleTerminalSearchPaneIDs: [first, second]
            ) == .editor
        )
    }

    // MARK: - Menu enablement

    @Test("A terminal-only window with a visible bar enables ⌘G (issue #1551)")
    func commandEnabledForVisibleBarWithoutEditorTab() {
        let terminalPane = PaneID()
        #expect(
            FindStepTargetPolicy.isCommandEnabled(
                activePaneID: terminalPane,
                visibleTerminalSearchPaneIDs: [terminalPane],
                hasActiveEditorTab: false
            )
        )
    }

    @Test("A lone background bar enables ⌘G even with no editor tab")
    func commandEnabledForLoneBackgroundBarWithoutEditorTab() {
        let terminalPane = PaneID()
        let editorPane = PaneID()
        #expect(
            FindStepTargetPolicy.isCommandEnabled(
                activePaneID: editorPane,
                visibleTerminalSearchPaneIDs: [terminalPane],
                hasActiveEditorTab: false
            )
        )
    }

    @Test("No bar and no editor tab leaves ⌘G disabled")
    func commandDisabledWithNothingAddressable() {
        #expect(
            !FindStepTargetPolicy.isCommandEnabled(
                activePaneID: PaneID(),
                visibleTerminalSearchPaneIDs: [],
                hasActiveEditorTab: false
            )
        )
    }

    @Test("An active editor tab keeps ⌘G enabled (pre-#1551 gate)")
    func commandEnabledForEditorTabWithoutBars() {
        #expect(
            FindStepTargetPolicy.isCommandEnabled(
                activePaneID: PaneID(),
                visibleTerminalSearchPaneIDs: [],
                hasActiveEditorTab: true
            )
        )
    }

    @Test("Ambiguous bars fall back to the editor gate")
    func commandEnabledForAmbiguousBarsFollowsEditorTab() {
        let first = PaneID()
        let second = PaneID()
        let editorPane = PaneID()
        #expect(
            FindStepTargetPolicy.isCommandEnabled(
                activePaneID: editorPane,
                visibleTerminalSearchPaneIDs: [first, second],
                hasActiveEditorTab: true
            )
        )
        #expect(
            !FindStepTargetPolicy.isCommandEnabled(
                activePaneID: editorPane,
                visibleTerminalSearchPaneIDs: [first, second],
                hasActiveEditorTab: false
            )
        )
    }

    @Test("A closed bar no longer enables ⌘G on its own")
    func commandDisabledOnceTheBarCloses() {
        let terminalPane = PaneID()
        let enabled = FindStepTargetPolicy.isCommandEnabled(
            activePaneID: terminalPane,
            visibleTerminalSearchPaneIDs: [terminalPane],
            hasActiveEditorTab: false
        )
        let disabled = FindStepTargetPolicy.isCommandEnabled(
            activePaneID: terminalPane,
            visibleTerminalSearchPaneIDs: [],
            hasActiveEditorTab: false
        )
        #expect(enabled && !disabled)
    }
}

/// The policy fed from real pane state: `visibleTerminalSearchPaneIDs` and
/// the terminal observer's gate over an actual `PaneManager`.
@Suite("Find Step Pane Integration")
@MainActor
struct FindStepPaneIntegrationTests {

    /// Editor + one terminal pane at the bottom, search bar opened in the
    /// terminal, focus moved back into the editor.
    private func makeEditorAndSearchedTerminal()
        -> (project: ProjectManager, editorPane: PaneID, terminalPane: PaneID) {
        let project = ProjectManager()
        let paneManager = project.paneManager
        let editorPane = paneManager.root.leafIDs.first {
            paneManager.root.content(for: $0) == .editor
        } ?? paneManager.activePaneID
        let terminalPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        paneManager.terminalState(for: terminalPane)?.presentSearch()
        // Simulate focus moving into the editor after the search was opened.
        paneManager.activePaneID = editorPane
        return (project, editorPane, terminalPane)
    }

    @Test("visibleTerminalSearchPaneIDs tracks open and closed bars")
    func visibleSearchPaneIDsTrackBarVisibility() {
        let paneManager = PaneManager()
        #expect(paneManager.visibleTerminalSearchPaneIDs.isEmpty)

        let terminalPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        #expect(paneManager.visibleTerminalSearchPaneIDs.isEmpty)

        paneManager.terminalState(for: terminalPane)?.presentSearch()
        #expect(paneManager.visibleTerminalSearchPaneIDs == [terminalPane])

        paneManager.terminalState(for: terminalPane)?.dismissSearch()
        #expect(paneManager.visibleTerminalSearchPaneIDs.isEmpty)
    }

    @Test("The pane owning the lone open bar steps on an untargeted ⌘G")
    func loneSearchedPaneStepsFromEditorFocus() {
        let (project, _, terminalPane) = makeEditorAndSearchedTerminal()

        #expect(TerminalSearchObserver.shouldStepSearch(
            in: terminalPane,
            paneManager: project.paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("A pane without an open bar never swallows the step")
    func paneWithoutBarDoesNotStep() throws {
        let project = ProjectManager()
        let paneManager = project.paneManager
        let terminalPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        paneManager.terminalState(for: terminalPane)?.presentSearch()

        // A second terminal pane without a bar must not react.
        let otherPane = try #require(
            paneManager.createTerminalPane(
                relativeTo: terminalPane,
                axis: .horizontal,
                workingDirectory: nil
            )
        )
        paneManager.activePaneID = terminalPane

        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: otherPane,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
        // The active pane's bar still wins for itself.
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: terminalPane,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("With two open bars only the active pane's bar steps")
    func activePaneBarWinsAmongTwoOpenBars() throws {
        let project = ProjectManager()
        let paneManager = project.paneManager
        let first = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        paneManager.terminalState(for: first)?.presentSearch()
        let second = try #require(
            paneManager.createTerminalPane(
                relativeTo: first,
                axis: .horizontal,
                workingDirectory: nil
            )
        )
        paneManager.terminalState(for: second)?.presentSearch()

        // createTerminalPane made the second pane active: its bar wins.
        paneManager.activePaneID = second
        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: first,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: second,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))

        // Activating the first pane flips the winner.
        paneManager.activePaneID = first
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: first,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: second,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("A bar hidden by maximizing another pane is not addressable")
    func maximizedPaneDismantlesGhostBar() throws {
        let project = ProjectManager()
        let paneManager = project.paneManager
        let ghostPane = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        paneManager.terminalState(for: ghostPane)?.presentSearch()
        let maximizedPane = try #require(
            paneManager.createTerminalPane(
                relativeTo: ghostPane,
                axis: .horizontal,
                workingDirectory: nil
            )
        )

        paneManager.activePaneID = maximizedPane
        paneManager.toggleMaximizeOnActiveTerminalPane()

        // The ghost premise: maximize dismantles the other pane's views (its
        // TerminalSearchObserver dies) but keeps its state, bar included.
        #expect(paneManager.terminalState(for: ghostPane)?.isSearchVisible == true)
        // The pane tree, not the state dictionary, decides addressability.
        #expect(!paneManager.visibleTerminalSearchPaneIDs.contains(ghostPane))
        #expect(paneManager.visibleTerminalSearchPaneIDs.isEmpty)
        #expect(FindStepTargetPolicy.target(
            activePaneID: paneManager.activePaneID,
            visibleTerminalSearchPaneIDs: paneManager.visibleTerminalSearchPaneIDs
        ) == .editor)
        // Menu stays off rather than offering an enabled-but-dead ⌘G.
        #expect(!FindStepTargetPolicy.isCommandEnabled(
            activePaneID: paneManager.activePaneID,
            visibleTerminalSearchPaneIDs: paneManager.visibleTerminalSearchPaneIDs,
            hasActiveEditorTab: false
        ))
        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: ghostPane,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))

        // Restore re-mounts the pane; its bar becomes addressable again.
        paneManager.toggleMaximizeOnActiveTerminalPane()
        #expect(paneManager.visibleTerminalSearchPaneIDs == [ghostPane])
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: ghostPane,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("A bar in the maximized pane itself stays addressable")
    func barInMaximizedPaneStaysAddressable() {
        let project = ProjectManager()
        let paneManager = project.paneManager
        let pane = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        paneManager.terminalState(for: pane)?.presentSearch()

        paneManager.activePaneID = pane
        paneManager.toggleMaximizeOnActiveTerminalPane()

        #expect(paneManager.visibleTerminalSearchPaneIDs == [pane])
        #expect(FindStepTargetPolicy.target(
            activePaneID: paneManager.activePaneID,
            visibleTerminalSearchPaneIDs: paneManager.visibleTerminalSearchPaneIDs
        ) == .terminal(pane))
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: pane,
            paneManager: paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("Targeted commands from the palette reach only their project's pane")
    func targetedNotificationScopesToItsProject() {
        let (project, _, terminalPane) = makeEditorAndSearchedTerminal()
        let otherProject = ProjectManager()

        // Palette / user-keybinding route: object identifies the project.
        #expect(TerminalSearchObserver.shouldStepSearch(
            in: terminalPane,
            paneManager: project.paneManager,
            notificationObject: project,
            currentProject: project,
            isKeyWindow: false
        ))
        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: terminalPane,
            paneManager: project.paneManager,
            notificationObject: otherProject,
            currentProject: project,
            isKeyWindow: true
        ))
    }

    @Test("Untargeted commands require the key window")
    func untargetedCommandRequiresKeyWindow() {
        let (project, _, terminalPane) = makeEditorAndSearchedTerminal()

        #expect(!TerminalSearchObserver.shouldStepSearch(
            in: terminalPane,
            paneManager: project.paneManager,
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: false
        ))
    }
}

/// The editor's side of the same policy: its native find bar must yield the
/// step while a visible terminal search bar owns it (#1551).
@Suite("Editor Find Step Yield")
@MainActor
struct EditorFindStepYieldTests {

    @Test("Without a seam the editor stays eligible (pre-#1551 behavior)")
    func nilSeamKeepsEditorEligible() {
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        #expect(coordinator.canStepFind())
    }

    @Test("The editor yields while a terminal search bar owns the step")
    func seamSuppressesEditorStepping() {
        let yielding = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            canHandleFindStepping: { false },
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: yielding)
        #expect(!coordinator.canStepFind())
    }

    @Test("The seam tracks the policy live: bar closed, editor steps again")
    func seamFollowsPolicyLive() {
        let paneManager = PaneManager()
        let terminalPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let terminalState = paneManager.terminalState(for: terminalPane)

        terminalState?.presentSearch()
        #expect(paneManager.visibleTerminalSearchPaneIDs.contains(terminalPane))
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            canHandleFindStepping: {
                FindStepTargetPolicy.target(
                    activePaneID: paneManager.activePaneID,
                    visibleTerminalSearchPaneIDs:
                        paneManager.visibleTerminalSearchPaneIDs
                ) == .editor
            },
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)

        #expect(!coordinator.canStepFind())

        terminalState?.dismissSearch()
        #expect(coordinator.canStepFind())
    }
}
