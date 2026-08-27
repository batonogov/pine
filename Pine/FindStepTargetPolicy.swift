//
//  FindStepTargetPolicy.swift
//  Pine
//
//  Window-wide routing for Find Next / Find Previous (⌘G / ⇧⌘G), issue #1551.
//

/// Which surface a window-wide Find Next / Find Previous step drives.
///
/// Kept as a pure function of the pane layout — no AppKit, no observation —
/// so the rule is unit-testable and mutation-verifiable directly, the same
/// shape as the `TerminalSearchFieldCommand` seam from #1523.
enum FindStepTargetPolicy {
    /// The addressee of one ⌘G / ⇧⌘G press.
    enum Target: Equatable {
        /// The visible terminal search bar owned by this pane.
        case terminal(PaneID)
        /// The editor's native find bar — the pre-#1551 behavior.
        case editor
    }

    /// Resolves the target of a find step for one project window.
    ///
    /// The rule is the Apple-like "visible target" flow (Terminal.app /
    /// Safari / Preview): an open terminal search bar stays addressable while
    /// it is visible, because ⌘G is exactly the binding that must keep
    /// working after focus leaves the query field — the state where Return
    /// no longer steps.
    ///
    /// 1. A visible bar in the **active pane** wins, even when several bars
    ///    are open — the active pane is the user's current context.
    /// 2. Otherwise, when **exactly one** bar is visible in the window, that
    ///    bar wins — including when focus has moved into the editor.
    /// 3. Otherwise (no bar visible, or several bars with none in the active
    ///    pane, which is ambiguous) the command stays with the **editor's**
    ///    native find bar, preserving pre-#1551 behavior.
    ///
    /// This deliberately diverges from ⌘F's active-pane rule (`.findInTerminal`
    /// targets the active pane only): ⌘F opens a search where focus already
    /// is, ⌘G steps the search the user can see.
    ///
    /// - Parameters:
    ///   - activePaneID: the pane currently holding focus in the window.
    ///   - visibleTerminalSearchPaneIDs: every pane whose terminal search bar
    ///     is visible; order is not significant.
    static func target(
        activePaneID: PaneID,
        visibleTerminalSearchPaneIDs: [PaneID]
    ) -> Target {
        if visibleTerminalSearchPaneIDs.contains(activePaneID) {
            return .terminal(activePaneID)
        }
        if visibleTerminalSearchPaneIDs.count == 1,
           let onlyVisiblePaneID = visibleTerminalSearchPaneIDs.first {
            return .terminal(onlyVisiblePaneID)
        }
        return .editor
    }

    /// Whether ⌘G / ⇧⌘G has any addressee in the window and the menu item
    /// may be enabled: a terminal search bar the policy resolves to, or an
    /// active editor tab for the native find bar.
    ///
    /// `hasActiveEditorTab` keeps the exact pre-#1551 editor gate — the
    /// editor branch of ``target(activePaneID:visibleTerminalSearchPaneIDs:)``
    /// is a fallback, not proof that an editor tab exists to receive it.
    static func isCommandEnabled(
        activePaneID: PaneID,
        visibleTerminalSearchPaneIDs: [PaneID],
        hasActiveEditorTab: Bool
    ) -> Bool {
        if case .terminal = target(
            activePaneID: activePaneID,
            visibleTerminalSearchPaneIDs: visibleTerminalSearchPaneIDs
        ) {
            return true
        }
        return hasActiveEditorTab
    }
}
