//
//  SidebarRowChrome.swift
//  Pine
//
//  Shared visual state for sidebar rows. Keeping the state in one small view
//  makes selection, keyboard focus, hover, editor activity, preview, and
//  missing-item treatments independently testable and snapshot-stable.
//

import SwiftUI

struct SidebarRowVisualState: Equatable {
    var isSelected = false
    var isKeyboardFocused = false
    var isHovered = false
    var isActiveFile = false
    var isTransientPreview = false
    var isExpanded = false
    var isMissing = false
}

struct SidebarDisclosureIndicator: View {
    let isDirectory: Bool
    let isExpanded: Bool

    var body: some View {
        Group {
            if isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(width: 8)
        .accessibilityHidden(true)
    }
}

struct SidebarRowLabel: View {
    let name: String
    let iconName: String
    let iconColor: Color
    let textColor: Color
    let isDirectory: Bool
    let state: SidebarRowVisualState
    /// Git status of the row's file or folder, when the workspace has one.
    /// Drives the trailing status badge (#1532). `nil` renders nothing, so
    /// rows without git state keep today's layout untouched.
    var gitStatus: GitFileStatus?
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 4) {
            SidebarDisclosureIndicator(
                isDirectory: isDirectory,
                isExpanded: state.isExpanded
            )

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(
                    width: SidebarIconMetrics.iconSlotWidth,
                    alignment: .center
                )
                .accessibilityHidden(true)

            Text(name)
                .foregroundStyle(effectiveTextColor)
                .fontWeight(state.isActiveFile ? .semibold : .regular)
                .italic(state.isTransientPreview)
                .strikethrough(state.isMissing)

            Spacer(minLength: 4)
            statusIndicator
        }
    }

    /// When the user asks the system not to use colour alone, the status
    /// tint on the filename is the row's only colour-only signal (#1532):
    /// drop it and let the letter badge carry the status. A pure function
    /// so the policy is unit-testable without hosting the view.
    static func effectiveNameColor(
        base: Color,
        gitStatus: GitFileStatus?,
        differentiateWithoutColor: Bool
    ) -> Color {
        guard let gitStatus, differentiateWithoutColor else { return base }
        return .primary
    }

    private var effectiveTextColor: Color {
        Self.effectiveNameColor(
            base: textColor,
            gitStatus: gitStatus,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if state.isMissing {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if state.isTransientPreview {
            Image(systemName: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if let gitStatus {
            gitStatusBadge(gitStatus)
        }
    }

    /// The letter badge is the colour-independent status cue and is always
    /// shown; the hue only reinforces it. Hidden from accessibility because
    /// the enclosing row announces the status as its value (#1532).
    private func gitStatusBadge(_ status: GitFileStatus) -> some View {
        Text(status.statusLetter)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(status.color)
            .accessibilityHidden(true)
    }
}

struct SidebarRowChrome<Content: View>: View {
    let state: SidebarRowVisualState
    let rowHeight: CGFloat
    private let content: Content

    init(
        state: SidebarRowVisualState,
        rowHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.rowHeight = rowHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .padding(.horizontal, SidebarRowMetrics.rowHorizontalPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: SidebarRowMetrics.selectionCornerRadius,
                    style: .continuous
                )
                .fill(backgroundColor)
                .padding(.horizontal, SidebarRowMetrics.selectionHorizontalInset)
            }
            .overlay {
                if state.isSelected && state.isKeyboardFocused {
                    RoundedRectangle(
                        cornerRadius: SidebarRowMetrics.selectionCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.accentColor, lineWidth: 1)
                    .padding(.horizontal, SidebarRowMetrics.selectionHorizontalInset)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                if state.isActiveFile {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: max(8, rowHeight - 8))
                        .padding(.leading, SidebarRowMetrics.selectionHorizontalInset + 1)
                        .allowsHitTesting(false)
                }
            }
            .opacity(state.isMissing ? 0.55 : 1)
            .contentShape(Rectangle())
    }

    private var backgroundColor: Color {
        if state.isSelected {
            return Color.accentColor.opacity(
                SidebarRowMetrics.selectionOpacity
            )
        }
        if state.isActiveFile {
            return Color.accentColor.opacity(0.10)
        }
        if state.isHovered {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}
