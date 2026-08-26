//
//  SearchResultsView.swift
//  Pine
//
//  Created by Claude on 18.03.2026.
//

import AppKit
import SwiftUI

struct SearchResultsView: View {
    @Environment(ProjectManager.self) var projectManager

    /// Owns the flattened selection across all groups and the reveal policy.
    @State private var navigation = SearchResultsNavigation()
    /// Hands Down arrow in the toolbar search field over to this list.
    @State private var handoffMonitor = SearchFieldHandoffMonitor()
    @FocusState private var isListFocused: Bool

    var body: some View {
        let search = projectManager.searchProvider

        Group {
            if search.isSearching {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(PineAnimation.fadeTransition)
            } else if search.results.isEmpty && !search.query.isEmpty {
                ContentUnavailableView {
                    Label(Strings.searchNoResults, systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier(AccessibilityID.searchEmptyState)
                .transition(PineAnimation.fadeTransition)
            } else if search.query.isEmpty {
                ContentUnavailableView {
                    Label(Strings.searchInitialPrompt, systemImage: "text.magnifyingglass")
                } description: {
                    Text(Strings.searchInitialDescription)
                }
                .accessibilityIdentifier(AccessibilityID.searchInitialState)
                .transition(PineAnimation.fadeTransition)
            } else {
                searchResultsList
                    .transition(PineAnimation.fadeTransition)
            }
        }
        .animation(PineAnimation.content, value: search.isSearching)
        .animation(PineAnimation.content, value: search.results.isEmpty)
        .onChange(of: search.totalMatchCount) { _, _ in
            // Reset selection when results change. Deliberately issues no
            // reveal: a rebuilt list already renders at the top.
            navigation.resetSelection(total: search.flattenedMatches.count)
        }
        .onAppear { startFieldHandoff() }
        .onDisappear { handoffMonitor.stop() }
    }

    /// Routes the navigation keys while the caret is in the toolbar search
    /// field. The field is an `NSSearchToolbarItem`, so it is outside this
    /// view's SwiftUI hierarchy and `onKeyPress` cannot reach it, and its
    /// first responder cannot be taken away — see `SearchFieldHandoffMonitor`.
    private func startFieldHandoff() {
        handoffMonitor.hasResults = {
            !projectManager.searchProvider.flattenedMatches.isEmpty
        }
        handoffMonitor.currentFocus = { navigation.focus }
        handoffMonitor.onAction = { action in
            let flat = projectManager.searchProvider.flattenedMatches
            switch action {
            case .enterList:
                return navigation.enterList(total: flat.count)
            case .moveSelection(let delta):
                navigation.moveSelection(delta: delta, total: flat.count)
                return true
            case .openSelected:
                guard let index = navigation.selectedIndex,
                      flat.indices.contains(index) else { return false }
                openMatch(flat[index])
                return true
            case .stepOutOfList:
                navigation.handleEscape()
                return true
            case .passThrough:
                return false
            }
        }
        handoffMonitor.start()
    }

    private var searchResultsList: some View {
        let flat = projectManager.searchProvider.flattenedMatches

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(projectManager.searchProvider.results.enumerated()), id: \.element.id) { groupIndex, group in
                            fileGroupView(group, groupIndex: groupIndex, flat: flat)
                        }
                    }
                }
                .onAppear {
                    // Selection changes reveal a row only once it has left the
                    // viewport. Omitting the anchor asks SwiftUI for the
                    // smallest scroll needed, matching the sidebar policy in
                    // AGENTS.md instead of recentering on every move.
                    navigation.scrollToIndex = { request in
                        performScroll(request, using: proxy)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.projectSearchResultsList)
            .onKeyPress(.upArrow) {
                navigation.moveSelection(delta: -1, total: flat.count)
                return .handled
            }
            .onKeyPress(.downArrow) {
                navigation.moveSelection(delta: 1, total: flat.count)
                return .handled
            }
            .onKeyPress(.return) {
                if let index = navigation.selectedIndex, flat.indices.contains(index) {
                    openMatch(flat[index])
                }
                return .handled
            }
            .onKeyPress(.escape) {
                switch navigation.handleEscape() {
                case .returnFocusToField:
                    isListFocused = false
                    SearchFieldHandoffMonitor.focusSearchField(in: NSApp.keyWindow)
                    return .handled
                case .dismissSearch:
                    // Let SidebarSearchableContent clear the query and close.
                    return .ignored
                }
            }
            .focusable()
            .focused($isListFocused)

            truncationFooter
        }
    }

    /// Applies a reveal request to the scroll proxy.
    ///
    /// `.nearestEdge` maps to `scrollTo(id)` with no anchor — SwiftUI then
    /// leaves the viewport alone while the row is visible and moves the
    /// minimum needed once it is not. `.center` is reserved for an intentional
    /// reveal and is the only case allowed to animate.
    private func performScroll(
        _ request: SearchScrollRequest,
        using proxy: ScrollViewProxy
    ) {
        let scroll = {
            // A nil anchor is the minimal-shift reveal; see
            // `SearchScrollAlignment.proxyAnchor`.
            proxy.scrollTo(request.index, anchor: request.alignment.proxyAnchor)
        }

        if request.motion.usesAnimation {
            withAnimation(PineAnimation.quick) {
                scroll()
            }
        } else {
            scroll()
        }
    }

    // MARK: - Truncation footer

    @ViewBuilder
    private var truncationFooter: some View {
        let search = projectManager.searchProvider
        if search.isTotalCapped || search.isPerFileCapped {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: LayoutMetrics.captionFontSize))
                    .foregroundStyle(.orange)
                Text(truncationMessage)
                    .font(.system(size: LayoutMetrics.captionFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, LayoutMetrics.searchResultHorizontalPadding)
            .padding(.vertical, LayoutMetrics.searchResultHeaderVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityIdentifier(AccessibilityID.searchTruncationFooter)
        }
    }

    private var truncationMessage: String {
        let search = projectManager.searchProvider
        if search.isTotalCapped {
            return Strings.searchTruncatedTotal(shown: search.totalMatchCount, max: ProjectSearchProvider.maxResults)
        } else if search.isPerFileCapped {
            return Strings.searchTruncatedPerFile(ProjectSearchProvider.maxResultsPerFile)
        }
        return ""
    }

    // MARK: - Keyboard navigation

    private func openMatch(_ entry: FlatSearchMatch) {
        projectManager.activeTabManager.openTabAndGoToLine(
            url: entry.fileURL,
            line: entry.match.lineNumber
        )
    }

    @ViewBuilder
    private func fileGroupView(_ group: SearchFileGroup, groupIndex: Int, flat: [FlatSearchMatch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: FileIconMapper.iconForFile(group.url.lastPathComponent))
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                Text(group.relativePath)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(group.matches.count)")
                    .font(.system(size: LayoutMetrics.captionFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, LayoutMetrics.searchResultHorizontalPadding)
            .padding(.vertical, LayoutMetrics.searchResultHeaderVerticalPadding)
            .background(.bar)

            ForEach(Array(group.matches.enumerated()), id: \.element.id) { _, match in
                let flatIndex = flat.firstIndex { $0.fileURL == group.url && $0.match.id == match.id } ?? -1
                let isSelected = navigation.selectedIndex == flatIndex

                MatchRowView(
                    match: match,
                    fileURL: group.url,
                    isSelected: isSelected,
                    onTap: {
                        navigation.select(index: flatIndex)
                        openMatch(FlatSearchMatch(fileURL: group.url, match: match))
                    }
                )
                .id(flatIndex)
                .accessibilityAddTraits(
                    CommandOverlayRowAccessibility.selectionTraits(isSelected: isSelected)
                )
            }
        }
    }
}

// MARK: - Match row with hover + selection highlight

private struct MatchRowView: View {
    let match: SearchMatch
    let fileURL: URL
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("\(match.lineNumber)")
                    .font(.system(size: LayoutMetrics.captionFontSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)

                highlightedText
                    .font(.system(size: LayoutMetrics.bodySmallFontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, LayoutMetrics.searchResultHorizontalPadding)
            .padding(.vertical, LayoutMetrics.searchResultRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .animation(PineAnimation.quick, value: isHovered)
        .animation(PineAnimation.quick, value: isSelected)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }

    /// Builds a Text view with the match highlighted in bold using stored range offsets.
    private var highlightedText: Text {
        let content = match.lineContent

        // Convert UTF-16 offsets from SearchMatch back to String.Index
        let utf16 = content.utf16
        let startUTF16 = utf16.index(utf16.startIndex, offsetBy: match.matchRangeStart, limitedBy: utf16.endIndex)
        let endUTF16 = startUTF16.flatMap {
            utf16.index($0, offsetBy: match.matchRangeLength, limitedBy: utf16.endIndex)
        }

        guard let s16 = startUTF16, let e16 = endUTF16,
              let start = s16.samePosition(in: content),
              let end = e16.samePosition(in: content) else {
            return Text(content).foregroundColor(.primary)
        }

        let before = Text(content[content.startIndex..<start])
            .foregroundColor(.primary)
        let matched = Text(content[start..<end])
            .foregroundColor(.accentColor)
            .bold()
        let after = Text(content[end..<content.endIndex])
            .foregroundColor(.primary)

        return Text("\(before)\(matched)\(after)")
    }
}
