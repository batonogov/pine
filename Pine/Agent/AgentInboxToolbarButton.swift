//
//  AgentInboxToolbarButton.swift
//  Pine
//
//  Project-window toolbar entry point for the Agent Inbox (#1337).
//
//  `ContentView` previously had no visible Inbox affordance — the only paths
//  were the View menu, the ⌘⇧I shortcut, and the Welcome window. This
//  button is additive: it anchors the Agent Inbox popover and shows an
//  attention dot driven by the same `AgentInboxSnapshot` that the Inbox view
//  renders, scoped to the focused project.
//

import SwiftUI

/// Toolbar button that opens the Agent Inbox popover, with an attention dot
/// shown while any of the focused project's durable agent tasks need input.
///
/// The dot is deliberately numberless. The toolbar draws a circular chrome
/// around the button's label, and a capsule wide enough to hold a legible
/// count either overlaps the glyph or reaches past that chrome and reads as
/// clipped. The exact count is carried by the tooltip and the VoiceOver
/// label instead, where it has room to be read properly.
///
/// The count is supplied by the caller (read from
/// `ProjectRegistry.agentInboxAttentionCount(for:)`) so this view stays a
/// pure function of its inputs and can be snapshot-tested in isolation.
struct AgentInboxToolbarButton: View {
    /// Number of the focused project's tasks in the Inbox's
    /// `needsAttention` section. `0` hides the dot.
    let attentionCount: Int
    let action: () -> Void

    /// Attention dot diameter. Small and fixed: the dot must clear the glyph
    /// without reaching the edge of the toolbar's circular item chrome.
    private static let dotSize: CGFloat = 8
    /// Nudge out of the glyph's corner. The chrome extends past the glyph on
    /// every side, so this keeps the dot and its ring comfortably inside it.
    private static let dotOffset: CGFloat = 1

    var body: some View {
        Button(action: action) {
            label
        }
        // No explicit `buttonStyle`: the toolbar's own style is what gives the
        // item its circular chrome and standard glyph metric. `.borderless`
        // opts out of both and leaves a squashed vertical pill.
        .accessibilityIdentifier(AccessibilityID.agentInboxToolbarButton)
        .accessibilityLabel(Text(verbatim: Self.accessibilityLabel(
            attentionCount: attentionCount
        )))
        .help(Text(verbatim: Self.tooltip(attentionCount: attentionCount)))
    }

    private var label: some View {
        // The glyph carries no explicit font or frame: the toolbar sizes its
        // circular item chrome to the label, and pinning the label smaller
        // than the standard metric squashes that circle into a vertical pill.
        // The dot is an overlay rather than a stack sibling for the same
        // reason — taking part in layout would drag the chrome off the glyph.
        Image(systemName: MenuIcons.agentInbox)
            .overlay(alignment: .topTrailing) {
                if attentionCount > 0 {
                    dot
                        .offset(x: Self.dotOffset, y: -Self.dotOffset)
                }
            }
    }

    private var dot: some View {
        Circle()
            .fill(Color.red)
            // Ring in the window backdrop so the dot reads as a separate
            // layer where it meets the glyph.
            .overlay(
                Circle().strokeBorder(
                    Color(nsColor: .windowBackgroundColor),
                    lineWidth: 1
                )
            )
            .frame(width: Self.dotSize, height: Self.dotSize)
            .accessibilityHidden(true)
    }

    /// VoiceOver label for the button. The dot carries no number, so this is
    /// one of only two places the exact count is available. Exposed for unit
    /// tests: the name and the pluralized count are joined through a localized
    /// format so languages that order them differently can reorder arguments.
    static func accessibilityLabel(
        attentionCount: Int,
        locale: Locale = .current
    ) -> String {
        joined(
            lead: Strings.agentInboxTitleText(locale: locale),
            attentionCount: attentionCount,
            locale: locale
        )
    }

    /// Tooltip for the button — the other place the exact count is available.
    static func tooltip(
        attentionCount: Int,
        locale: Locale = .current
    ) -> String {
        joined(
            lead: Strings.agentInboxToolbarTooltipText(locale: locale),
            attentionCount: attentionCount,
            locale: locale
        )
    }

    private static func joined(
        lead: String,
        attentionCount: Int,
        locale: Locale
    ) -> String {
        guard attentionCount > 0 else { return lead }
        return Strings.agentInboxToolbarJoined(
            lead: lead,
            attention: Strings.agentInboxToolbarAttentionCount(
                attentionCount,
                locale: locale
            ),
            locale: locale
        )
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
