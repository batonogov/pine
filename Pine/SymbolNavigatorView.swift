//
//  SymbolNavigatorView.swift
//  Pine
//
//  Symbol navigation sheet for jumping to functions, classes, etc. (Cmd+Shift+R).
//

import SwiftUI

struct SymbolNavigatorView: View {
    @Environment(ProjectManager.self) var projectManager
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var allSymbols: [PineSymbol] = []
    @State private var filteredSymbols: [PineSymbol] = []

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenSearchField(
                text: $searchText,
                placeholder: String(localized: "symbolNavigator.placeholder"),
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturn: { navigateToSelected() },
                onEscape: { isPresented = false }
            )
            .accessibilityIdentifier(AccessibilityID.symbolSearchField)
            .padding(10)

            Divider()
            resultsList
        }
        .frame(width: 500, height: 360)
        .onAppear {
            loadSymbols()
        }
        .onChange(of: searchText) { _, _ in
            updateFilteredSymbols()
        }
        .accessibilityIdentifier(AccessibilityID.symbolNavigatorOverlay)
    }

    // MARK: - Results List

    private var resultsList: some View {
        Group {
            if filteredSymbols.isEmpty {
                emptyState
                    .transition(PineAnimation.fadeTransition)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredSymbols.enumerated()), id: \.element.id) { index, symbol in
                                symbolRow(symbol, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        navigateToSymbol(symbol)
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
        .animation(PineAnimation.content, value: filteredSymbols.isEmpty)
        .accessibilityIdentifier(AccessibilityID.symbolResultsList)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if searchText.isEmpty {
                Text(Strings.symbolNavigatorEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(Strings.symbolNavigatorNoResults)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func symbolRow(_ symbol: PineSymbol, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol.kind.iconName)
                .font(.system(size: 14))
                .foregroundStyle(colorForKind(symbol.kind))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(symbol.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(symbol.kind.displayName) — line \(symbol.line)")
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
        .accessibilityIdentifier(AccessibilityID.symbolItem(symbol.name))
    }

    // MARK: - Actions

    private func loadSymbols() {
        guard let tab = projectManager.tabManager.activeTab else { return }
        let ext = tab.url.pathExtension
        allSymbols = SymbolParser.parse(content: tab.content, fileExtension: ext)
        filteredSymbols = allSymbols
        selectedIndex = 0
    }

    private func updateFilteredSymbols() {
        if searchText.isEmpty {
            filteredSymbols = allSymbols
        } else {
            filteredSymbols = SymbolParser.filter(allSymbols, query: searchText)
        }
        selectedIndex = 0
    }

    private func moveSelection(by delta: Int) {
        guard !filteredSymbols.isEmpty else { return }
        selectedIndex = max(0, min(filteredSymbols.count - 1, selectedIndex + delta))
    }

    private func navigateToSelected() {
        guard selectedIndex < filteredSymbols.count else { return }
        navigateToSymbol(filteredSymbols[selectedIndex])
    }

    private func navigateToSymbol(_ symbol: PineSymbol) {
        guard let tab = projectManager.tabManager.activeTab else { return }
        let offset = ContentView.cursorOffset(forLine: symbol.line, in: tab.content)
        NotificationCenter.default.post(
            name: .symbolNavigate,
            object: nil,
            userInfo: ["offset": offset]
        )
        isPresented = false
    }

    // MARK: - Helpers

    private func colorForKind(_ kind: PineSymbolKind) -> Color {
        switch kind {
        case .class: .purple
        case .struct: .blue
        case .enum: .orange
        case .protocol, .interface: .green
        case .function: .cyan
        case .property: .secondary
        }
    }
}
