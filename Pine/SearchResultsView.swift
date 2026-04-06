//
//  SearchResultsView.swift
//  Pine
//
//  Created by Claude on 18.03.2026.
//

import SwiftUI

struct SearchResultsView: View {
    @Environment(ProjectManager.self) var projectManager

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
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(projectManager.searchProvider.results) { group in
                    fileGroupView(group)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.projectSearchResultsList)
    }

    @ViewBuilder
    private func fileGroupView(_ group: SearchFileGroup) -> some View {
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

            ForEach(group.matches) { match in
                MatchRowView(
                    match: match,
                    fileURL: group.url,
                    projectManager: projectManager
                )
            }
        }
    }
}

// MARK: - Match row with hover highlight

private struct MatchRowView: View {
    let match: SearchMatch
    let fileURL: URL
    let projectManager: ProjectManager

    @State private var isHovered = false

    var body: some View {
        Button {
            projectManager.openFileInActivePane(url: fileURL, line: match.lineNumber)
        } label: {
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
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .animation(PineAnimation.quick, value: isHovered)
        .onHover { isHovered = $0 }
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
