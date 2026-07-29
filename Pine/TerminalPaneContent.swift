//
//  TerminalPaneContent.swift
//  Pine
//
//  Renders terminal tab bar + terminal view for a single terminal pane leaf.
//

import SwiftUI

/// Content view for a terminal pane leaf. Shows a tab bar with
/// terminal tabs and the active terminal's content.
struct TerminalPaneContent: View {
    let paneID: PaneID
    let terminalState: TerminalPaneState
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        VStack(spacing: 0) {
            TerminalPaneTabBar(
                paneID: paneID,
                terminalState: terminalState,
                workingDirectory: workspace.rootURL,
                projectManager: projectManager
            )
            TerminalSearchBarContainer(terminalState: terminalState)
            TerminalContentView(
                terminalPaneState: terminalState,
                canAttemptFocusRequest: { _ in
                    paneManager.activePaneID == paneID
                }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            terminalState.startTabs(workingDirectory: workspace.rootURL)
        }
        .modifier(TerminalSearchObserver(terminalState: terminalState))
    }
}
