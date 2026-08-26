//
//  QuickTerminalContentView.swift
//  Pine
//
//  Shared terminal content plus truthful agent status for Quick Terminal.
//

import SwiftUI

struct QuickTerminalContentView: View {
    let paneState: TerminalPaneState

    var body: some View {
        VStack(spacing: 0) {
            if let tab = paneState.activeTab {
                HStack(spacing: 0) {
                    TerminalTabIdentityLabel(tab: tab)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            Self.agentIdentityAccessibilityLabel(for: tab)
                        )
                        .accessibilityIdentifier(
                            AccessibilityID.quickTerminalAgentIdentity
                        )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: LayoutMetrics.tabBarHeight)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            TerminalContentView(
                terminalPaneState: paneState,
                canAttemptFocusRequest: { _ in true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.quickTerminalContent)
    }

    /// Kept as Quick Terminal's own entry point, delegating to the shared
    /// identity so the two terminal surfaces cannot drift apart again.
    static func agentIdentityAccessibilityLabel(
        for tab: TerminalTab
    ) -> String {
        TerminalTabIdentityLabel.accessibilityLabel(for: tab)
    }
}
