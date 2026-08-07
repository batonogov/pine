//
//  AgentInboxToolbarButton.swift
//  Pine
//
//  Project-window toolbar entry point for the Agent Inbox (#1337).
//
//  `ContentView` previously had no visible Inbox affordance — the only paths
//  were the Window menu, the ⌘⇧I shortcut, and the Welcome window. This
//  button is additive: it opens the existing `agent-inbox` window and shows
//  an attention badge driven by the same `AgentInboxSnapshot` that the Inbox
//  view renders, scoped to the focused project.
//

import SwiftUI

/// Toolbar button that opens the Agent Inbox window, with an attention badge
/// showing how many of the focused project's durable agent tasks currently
/// need input.
///
/// The badge count is supplied by the caller (computed from
/// `ProjectRegistry.agentInboxAttentionCount(for:)`) so this view stays a
/// pure function of its inputs and can be snapshot-tested in isolation.
struct AgentInboxToolbarButton: View {
    /// Number of the focused project's tasks in the Inbox's
    /// `needsAttention` section. `0` hides the badge.
    let attentionCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            badgeOverlay
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(AccessibilityID.agentInboxToolbarButton)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .help(Strings.agentInboxToolbarTooltip)
    }

    private var badgeOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: MenuIcons.agentInbox)
            if attentionCount > 0 {
                Text(badgeText)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    // Offset onto the icon's corner so the glyph stays readable.
                    .offset(x: 8, y: -6)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Caps on display at 99+ so a wide count never blows out the capsule.
    private var badgeText: String {
        attentionCount > 99 ? "99+" : "\(attentionCount)"
    }

    private var accessibilityLabel: String {
        guard attentionCount > 0 else {
            return String(localized: "menu.agentInbox")
        }
        return "\(String(localized: "menu.agentInbox")), \(Strings.agentInboxToolbarAttentionCount(attentionCount))"
    }
}

#Preview {
    HStack(spacing: 30) {
        AgentInboxToolbarButton(attentionCount: 0) {}
        AgentInboxToolbarButton(attentionCount: 3) {}
        AgentInboxToolbarButton(attentionCount: 150) {}
    }
    .padding()
}
