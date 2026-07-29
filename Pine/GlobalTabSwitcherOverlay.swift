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

import AppKit
import SwiftUI

/// Posts the currently highlighted switcher row for VoiceOver. Injectable so
/// hosted tests can verify announcements without relying on the system server.
typealias GlobalTabSwitcherAnnouncer = @MainActor @Sendable (String) -> Void

/// Observes every semantic scroll request. Production uses the no-op default;
/// hosted tests use it to verify that an initially selected off-screen row is
/// brought into view before the user advances the switcher. The Bool reports
/// whether the request actually uses animation after Reduce Motion is applied.
typealias GlobalTabSwitcherScrollObserver =
    @MainActor @Sendable (GlobalTabIdentity, Bool) -> Void

/// Deterministic accessibility configuration consumed directly by the
/// production SwiftUI modifiers. Keeping the semantic projection independent
/// of SwiftUI's private hosted accessibility proxies makes it testable across
/// OS releases without weakening the identifiers, labels, or selection rules.
struct GlobalTabSwitcherAccessibilitySemantics: Equatable {
    struct Announcement: Equatable {
        let selectedID: GlobalTabIdentity?
        let message: String
    }

    struct Row: Equatable {
        let identifier: String
        let label: String
        let isSelected: Bool
    }

    let overlayIdentifier: String
    let listIdentifier: String
    let isModal: Bool
    let announcement: Announcement
    let rows: [Row]

    init(
        entries: [GlobalTabSwitcherEntry],
        selectedIndex: Int,
        locale: Locale
    ) {
        overlayIdentifier = AccessibilityID.globalTabSwitcherOverlay
        listIdentifier = AccessibilityID.globalTabSwitcherList
        isModal = true
        rows = entries.enumerated().map { index, entry in
            var labelParts = [entry.title, entry.paneContext]
            if let detail = entry.detail, !detail.isEmpty {
                labelParts.append(detail)
            }
            return Row(
                identifier: AccessibilityID.globalTabSwitcherItem(entry.id),
                label: labelParts.joined(separator: ", "),
                isSelected: index == selectedIndex
            )
        }

        guard entries.indices.contains(selectedIndex) else {
            announcement = Announcement(
                selectedID: nil,
                message: Strings.globalTabSwitcherTitle(locale: locale)
            )
            return
        }

        let selectedEntry = entries[selectedIndex]
        let spokenTitle = [selectedEntry.title, selectedEntry.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        announcement = Announcement(
            selectedID: selectedEntry.id,
            message: Strings.globalTabSwitcherAnnouncement(
                title: spokenTitle,
                paneContext: selectedEntry.paneContext,
                position: selectedIndex + 1,
                total: entries.count,
                locale: locale
            )
        )
    }
}

/// Lightweight overlay rendering the global MRU tab switcher list.
///
/// Reads its data from the injected `PaneManager` (the session and the live
/// entries) and `WorkspaceManager` (project root for relative paths). The
/// keyboard controller owns the production gesture; the view only performs
/// defensive reconciliation and the accessibility exit-command fallback.
struct GlobalTabSwitcherOverlay: View {
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private let announce: GlobalTabSwitcherAnnouncer
    private let observeScroll: GlobalTabSwitcherScrollObserver
    private let reduceMotionOverride: Bool?

    init(
        announce: @escaping GlobalTabSwitcherAnnouncer = { message in
            NSAccessibility.post(
                element: NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        },
        observeScroll: @escaping GlobalTabSwitcherScrollObserver = { _, _ in },
        reduceMotionOverride: Bool? = nil
    ) {
        self.announce = announce
        self.observeScroll = observeScroll
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        let effectiveReduceMotion = reduceMotionOverride ?? reduceMotion
        let presentation = paneManager.globalTabSwitcherPresentation(
            projectRoot: workspace.rootURL,
            locale: locale
        )
        let entries = presentation.entries
        let selectedIndex = presentation.selectedIndex
        let accessibility = GlobalTabSwitcherAccessibilitySemantics(
            entries: entries,
            selectedIndex: selectedIndex,
            locale: locale
        )

        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.globalTabSwitcherTitle(locale: locale))
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
                                row(
                                    entry,
                                    semantics: accessibility.rows[index]
                                )
                                    .id(index)
                            }
                        }
                        .padding(.top, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(accessibility.listIdentifier)
                    }
                    .onAppear {
                        scrollToSelection(
                            proxy: proxy,
                            entries: entries,
                            selectedIndex: selectedIndex,
                            animated: false,
                            reduceMotion: effectiveReduceMotion
                        )
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        scrollToSelection(
                            proxy: proxy,
                            entries: entries,
                            selectedIndex: newIndex,
                            animated: true,
                            reduceMotion: effectiveReduceMotion
                        )
                    }
                }
            }

            Divider()
                .padding(.top, 4)

            Text(Strings.globalTabSwitcherHint(locale: locale))
                .font(.system(size: LayoutMetrics.captionFontSize))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 380, height: 320)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibility.overlayIdentifier)
        .accessibilityAddTraits(accessibility.isModal ? .isModal : [])
        // VoiceOver: announce the current selection whenever it changes so
        // sighted and non-sighted users get the same feedback while cycling.
        .accessibilityLabel(accessibility.announcement.message)
        .onAppear {
            announce(accessibility.announcement.message)
        }
        .onChange(of: accessibility.announcement) { _, newAnnouncement in
            announce(newAnnouncement.message)
        }
        .onChange(of: entries.map(\.id)) {
            // The pane/tab inventory can change while Control is held. Defer
            // the observable mutation until after SwiftUI finishes this render
            // pass, then keep the stored cursor aligned with the rows above.
            DispatchQueue.main.async {
                paneManager.reconcileGlobalTabSwitcherSession()
            }
        }
        .onExitCommand {
            // Escape: SwiftUI surfaces this as an exit command for modal
            // overlays. The session controller cancels here; ContentView's
            // key path also forwards Escape, but this covers VoiceOver
            // invocation and any focus path that bypasses the key monitor.
            paneManager.cancelGlobalTabSwitcher()
        }
    }

    // MARK: - Rows

    private func row(
        _ entry: GlobalTabSwitcherEntry,
        semantics: GlobalTabSwitcherAccessibilitySemantics.Row
    ) -> some View {
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

                if let detail = entry.detail, !detail.isEmpty {
                    Text(verbatim: detail)
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
        .background(
            semantics.isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(semantics.label)
        .accessibilityAddTraits(semantics.isSelected ? .isSelected : [])
        .accessibilityIdentifier(semantics.identifier)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(verbatim: Strings.paneGenericLabel(locale: locale))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scrolling

    private func scrollToSelection(
        proxy: ScrollViewProxy,
        entries: [GlobalTabSwitcherEntry],
        selectedIndex: Int,
        animated: Bool,
        reduceMotion: Bool
    ) {
        guard entries.indices.contains(selectedIndex) else { return }
        let usesAnimation = animated && !reduceMotion
        observeScroll(entries[selectedIndex].id, usesAnimation)
        if usesAnimation {
            withAnimation(PineAnimation.quick) {
                proxy.scrollTo(selectedIndex, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedIndex, anchor: .center)
        }
    }
}
