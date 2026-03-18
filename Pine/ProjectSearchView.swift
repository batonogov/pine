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
                .help("Case Sensitive")
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
        // File header
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

            // Match rows
            ForEach(group.matches) { match in
                matchRow(match, fileURL: group.url)
            }
        }
    }

    private func matchRow(_ match: SearchMatch, fileURL: URL) -> some View {
        Button {
            tabManager.openTabAndGoToLine(url: fileURL, line: match.lineNumber)
        } label: {
            HStack(spacing: 6) {
                Text("\(match.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)

                Text(match.lineContent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            Rectangle().fill(.clear)
        }
    }

    private func triggerSearch() {
        guard let rootURL = projectManager.rootURL else { return }
        projectManager.searchProvider.search(in: rootURL)
    }
}
