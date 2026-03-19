//
//  ProjectSearchView.swift
//  Pine
//
//  Created by Claude on 18.03.2026.
//

import SwiftUI

struct ProjectSearchView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(TabManager.self) var tabManager

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        @Bindable var search = projectManager.searchProvider

        VStack(spacing: 0) {
            // Search field + case toggle
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                TextField(Strings.searchPlaceholder, text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFieldFocused)
                    .accessibilityIdentifier(AccessibilityID.projectSearchField)
                    .onSubmit { triggerSearch() }
                    .onChange(of: search.query) { _, _ in
                        triggerSearch()
                    }

                // Case sensitivity toggle
                Button {
                    search.isCaseSensitive.toggle()
                    triggerSearch()
                } label: {
                    Text("Aa")
                        .font(.system(size: 11, weight: search.isCaseSensitive ? .bold : .regular))
                        .foregroundStyle(search.isCaseSensitive ? .primary : .secondary)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(search.isCaseSensitive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        )
                }
                .buttonStyle(.plain)
                .help(Strings.searchCaseSensitive)
                .accessibilityIdentifier(AccessibilityID.projectSearchCaseSensitiveToggle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Results
            if search.isSearching {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if search.results.isEmpty && !search.query.isEmpty {
                VStack {
                    Spacer()
                    Text(Strings.searchNoResults)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                searchResultsList
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(group.relativePath)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(group.matches.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            ForEach(group.matches) { match in
                MatchRowView(
                    match: match,
                    query: projectManager.searchProvider.query,
                    isCaseSensitive: projectManager.searchProvider.isCaseSensitive,
                    fileURL: group.url,
                    tabManager: tabManager
                )
            }
        }
    }

    private func triggerSearch() {
        guard let rootURL = projectManager.rootURL else { return }
        projectManager.searchProvider.search(in: rootURL)
    }
}

// MARK: - Match row with hover highlight

private struct MatchRowView: View {
    let match: SearchMatch
    let query: String
    let isCaseSensitive: Bool
    let fileURL: URL
    let tabManager: TabManager

    @State private var isHovered = false

    var body: some View {
        Button {
            tabManager.openTabAndGoToLine(url: fileURL, line: match.lineNumber)
        } label: {
            HStack(spacing: 6) {
                Text("\(match.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)

                highlightedText
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// Builds a Text view with the match highlighted in bold.
    private var highlightedText: Text {
        let content = match.lineContent
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]

        guard let range = content.range(of: query, options: options) else {
            return Text(content).foregroundColor(.primary)
        }

        let before = Text(content[content.startIndex..<range.lowerBound])
            .foregroundColor(.primary)
        let matched = Text(content[range])
            .foregroundColor(.accentColor)
            .bold()
        let after = Text(content[range.upperBound..<content.endIndex])
            .foregroundColor(.primary)

        return Text("\(before)\(matched)\(after)")
    }
}
