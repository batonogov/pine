//
//  GlobalTabSwitcherOverlay.swift
//  Pine
//
//  Visual MRU tab switcher overlay (issue #1239).
//
//  Presented by `ContentView` while `PaneManager.globalTabSwitcherSession` is
//  non-`nil`. Shows the frozen MRU-ordered list of every eligible editor and
//  terminal tab with its icon, title, pane context, and optional
//  project-relative path. The highlighted row tracks
//  `session.selectedIndex`; Control release commits, Escape cancels.
//
//  The overlay is intentionally non-interactive (no text field, no click
//  handling): selection is driven entirely by Control-Tab / Shift-Control-Tab
//  while the modifier is held, mirroring macOS Cmd-` and most IDE switchers.
//  Arrow-key / click selection is a deliberate follow-up.
//

import SwiftUI

/// Lightweight overlay rendering the global MRU tab switcher list.
///
/// Reads its data from the injected `PaneManager` (the session and the live
/// entries) and `WorkspaceManager` (project root for relative paths). It never
/// mutates the session directly — the keyboard controller in `AppDelegate`
/// owns begin / advance / commit / cancel.
struct GlobalTabSwitcherOverlay: View {
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = paneManager.globalTabSwitcherEntries(projectRoot: workspace.rootURL)
        let selectedIndex = paneManager.globalTabSwitcherSession?.selectedIndex ?? 0

        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.globalTabSwitcherTitle)
                .font(.headline)
                .padding(.bottom, 8)

            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, isSelected: index == selectedIndex)
                                    .id(index)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        // Center the highlighted row so long lists stay scannable.
                        guard entries.indices.contains(newIndex) else { return }
                        withAnimation(reduceMotion ? nil : PineAnimation.quick) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            Divider()
                .padding(.top, 4)

            Text(Strings.globalTabSwitcherHint)
                .font(.system(size: LayoutMetrics.captionFontSize))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 380, height: 320)
        .accessibilityIdentifier(AccessibilityID.globalTabSwitcherOverlay)
        .accessibilityAddTraits(.isModal)
        // VoiceOver: announce the current selection whenever it changes so
        // sighted and non-sighted users get the same feedback while cycling.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            accessibilityLabel(
                entries: entries,
                selectedIndex: selectedIndex
            )
        )
        .onExitCommand {
            // Escape: SwiftUI surfaces this as an exit command for modal
            // overlays. The session controller cancels here; ContentView's
            // key path also forwards Escape, but this covers VoiceOver
            // invocation and any focus path that bypasses the key monitor.
            paneManager.cancelGlobalTabSwitcher()
        }
    }

    // MARK: - Rows

    private func row(_ entry: GlobalTabSwitcherEntry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(entry.symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let relativePath = entry.relativePath, !relativePath.isEmpty {
                    Text(verbatim: relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(verbatim: entry.paneContext)
                .font(.system(size: LayoutMetrics.captionFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(.quaternary.opacity(0.5))
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(entry))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(AccessibilityID.globalTabSwitcherItem(entry.title))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(verbatim: Strings.paneGenericLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Accessibility

    /// Composite VoiceOver label: announces the highlighted row with its
    /// position so cycling is legible without sight.
    private func accessibilityLabel(
        entries: [GlobalTabSwitcherEntry],
        selectedIndex: Int
    ) -> String {
        guard entries.indices.contains(selectedIndex) else {
            return Strings.globalTabSwitcherTitle
        }
        let entry = entries[selectedIndex]
        return Strings.globalTabSwitcherAnnouncement(
            title: entry.title,
            paneContext: entry.paneContext,
            position: selectedIndex + 1,
            total: entries.count
        )
    }

    private func rowAccessibilityLabel(_ entry: GlobalTabSwitcherEntry) -> String {
        var parts: [String] = [entry.title, entry.paneContext]
        if let relativePath = entry.relativePath, !relativePath.isEmpty {
            parts.append(relativePath)
        }
        return parts.joined(separator: ", ")
    }
}
