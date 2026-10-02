//
//  SidebarProjectHeaderView.swift
//  Pine
//
//  Full-width project switcher that heads the sidebar column. The toolbar
//  capsule (`ProjectSwitcherView`) only stands in while the sidebar is
//  collapsed.
//

import SwiftUI

/// The sidebar's header row: the active project name with a menu offering
/// every project and agent worktree this window holds.
///
/// Styled after `SidebarRowChrome` rather than the toolbar: outside a toolbar
/// no chrome comes for free, so the row draws its own hover wash at the same
/// padding, radius, and opacity the file rows use. That keeps the switcher
/// reading as the sidebar's first row instead of a button floating above it.
struct SidebarProjectHeaderView: View {
    let session: ProjectWindowSession
    let registry: ProjectRegistry
    let onOpenProject: () -> Void
    let onCloseProject: () -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ProjectSwitcherMenuContent(
                session: session,
                registry: registry,
                onOpenProject: onOpenProject,
                onCloseProject: onCloseProject
            )
        } label: {
            HStack(spacing: 6) {
                if session.isLaunchingAgent {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: MenuIcons.projectSwitcher)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(session.activeDisplayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // The system indicator is hidden below; a borderless menu
                // otherwise draws its own pull-down arrow on top of ours.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarRowMetrics.rowHorizontalPadding)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(
                    cornerRadius: SidebarRowMetrics.selectionCornerRadius,
                    style: .continuous
                )
                .fill(
                    isHovered
                        ? Color.primary.opacity(0.06)
                        : .clear
                )
                .padding(
                    .horizontal,
                    SidebarRowMetrics.selectionHorizontalInset
                )
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(Strings.projectSwitcherTooltip)
        // Same identifier and spoken name as the toolbar capsule: only one of
        // the two exists at a time, and every test and VoiceOver lookup that
        // knows the switcher must keep finding it after the move.
        .accessibilityLabel(Text(session.activeDisplayName))
        .accessibilityIdentifier(AccessibilityID.projectSwitcher)
    }
}
