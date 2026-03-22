//
//  QuickOpenView.swift
//  Pine
//
//  Quick Open overlay for fuzzy file search (Cmd+P).
//

import SwiftUI

struct QuickOpenView: View {
    @Environment(ProjectManager.self) var projectManager
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var results: [QuickOpenProvider.Result] = []
    @State private var searchTask: Task<Void, Never>?

    private var provider: QuickOpenProvider { projectManager.quickOpenProvider }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 500, height: 360)
        .onAppear {
            provider.buildIndex(
                from: projectManager.rootNodes,
                rootURL: projectManager.rootURL ?? URL(fileURLWithPath: "/")
            )
            updateResults()
        }
        .accessibilityIdentifier(AccessibilityID.quickOpenOverlay)
    }

    // MARK: - Search Field

    private var searchField: some View {
        TextField(Strings.quickOpenPlaceholder, text: $searchText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 14))
            .padding(10)
            .accessibilityIdentifier(AccessibilityID.quickOpenSearchField)
            .onChange(of: searchText) { _, _ in
                scheduleSearch()
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.return) {
                openSelected()
                return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
    }

    // MARK: - Results List

    private var resultsList: some View {
        Group {
            if results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                resultRow(result, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        openFile(result.url)
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.quickOpenResultsList)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if searchText.isEmpty {
                Text(Strings.quickOpenRecentEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(Strings.quickOpenNoResults)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ result: QuickOpenProvider.Result, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileIconMapper.iconForFile(result.fileName))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.fileName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(result.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.quickOpenItem(result.fileName))
    }

    // MARK: - Actions

    private func scheduleSearch() {
        searchTask?.cancel()
        if searchText.isEmpty {
            updateResults()
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            updateResults()
        }
    }

    private func updateResults() {
        results = provider.search(query: searchText)
        selectedIndex = 0
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func openSelected() {
        guard selectedIndex < results.count else { return }
        openFile(results[selectedIndex].url)
    }

    private func openFile(_ url: URL) {
        provider.recordOpened(url: url)
        projectManager.tabManager.openTab(url: url)
        isPresented = false
    }
}
