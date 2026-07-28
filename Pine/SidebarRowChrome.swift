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
                .foregroundStyle(textColor)
                .fontWeight(state.isActiveFile ? .semibold : .regular)
                .italic(state.isTransientPreview)
                .strikethrough(state.isMissing)

            Spacer(minLength: 4)
            statusIndicator
        }
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
        }
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
