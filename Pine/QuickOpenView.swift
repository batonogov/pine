//
//  QuickOpenView.swift
//  Pine
//

import SwiftUI

struct QuickOpenView: View {
    let rootURL: URL
    var tabManager: TabManager
    var quickOpenProvider: QuickOpenProvider
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 580)
        .onAppear {
            query = ""
            selectedIndex = 0
            quickOpenProvider.search(query: "")
            quickOpenProvider.startIndexing(rootURL: rootURL)
            isTextFieldFocused = true
        }
        .onChange(of: query) { _, newQuery in
            selectedIndex = 0
            quickOpenProvider.search(query: newQuery)
        }
        .onDisappear {
            quickOpenProvider.reset()
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            TextField(Strings.quickOpenPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isTextFieldFocused)
                .accessibilityIdentifier(AccessibilityID.quickOpenField)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
        if quickOpenProvider.results.isEmpty {
            Text(query.isEmpty ? Strings.quickOpenRecentEmpty : Strings.quickOpenNoResults)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(quickOpenProvider.results.enumerated()),
                            id: \.element.id
                        ) { index, result in
                            QuickOpenResultRow(result: result, isSelected: index == selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    openSelected()
                                }
                                .accessibilityIdentifier(AccessibilityID.quickOpenResult(result.fileName))
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.none) {
                        proxy.scrollTo(newIndex, anchor: .nearest)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.quickOpenResultsList)
            }
        }
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) {
        let count = quickOpenProvider.results.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func openSelected() {
        guard selectedIndex < quickOpenProvider.results.count else { return }
        let result = quickOpenProvider.results[selectedIndex]
        tabManager.openTab(url: result.url)
        quickOpenProvider.recordOpened(result.url)
        isPresented = false
    }
}

// MARK: - Result Row

private struct QuickOpenResultRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIconMapper.iconForFile(result.fileName))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.fileName)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(result.relativePath)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
