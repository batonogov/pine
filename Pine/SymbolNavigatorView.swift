//
//  SymbolNavigatorView.swift
//  Pine
//
//  Hierarchical LSP-first symbol navigation with regex fallback (#1008).
//

import SwiftUI

nonisolated struct SymbolNavigatorEntry:
    Identifiable,
    Equatable,
    Sendable {

    let id: String
    let symbol: DocumentSymbolNode
    let depth: Int
    let line: Int
    let snapshot: DocumentSnapshot

    static func flatten(
        _ symbols: [DocumentSymbolNode],
        snapshot: DocumentSnapshot
    ) -> [SymbolNavigatorEntry] {
        var entries: [SymbolNavigatorEntry] = []
        let lineStarts = lineStarts(in: snapshot.text as NSString)

        func append(
            _ nodes: [DocumentSymbolNode],
            depth: Int,
            path: [Int]
        ) {
            for (index, node) in nodes.enumerated() {
                let nodePath = path + [index]
                entries.append(
                    SymbolNavigatorEntry(
                        id: nodePath.map(String.init)
                            .joined(separator: "."),
                        symbol: node,
                        depth: depth,
                        line: lineNumber(
                            at: node.selectionRange.location,
                            lineStarts: lineStarts
                        ),
                        snapshot: snapshot
                    )
                )
                append(
                    node.children,
                    depth: depth + 1,
                    path: nodePath
                )
            }
        }

        append(symbols, depth: 0, path: [])
        return entries
    }

    func matches(url: URL, text: String) -> Bool {
        snapshot.uri == url.absoluteString
            && snapshot.text == text
    }

    private static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            if character == 0x0D {
                if index + 1 < text.length,
                   text.character(at: index + 1) == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            } else if character == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    private static func lineNumber(
        at offset: Int,
        lineStarts: [Int]
    ) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[midpoint] <= offset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(1, lowerBound)
    }
}

struct SymbolNavigatorView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(\.locale) private var locale
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var allSymbols: [SymbolNavigatorEntry] = []
    @State private var filteredSymbols: [SymbolNavigatorEntry] = []
    @State private var symbolTask: Task<Void, Never>?
    @State private var symbolCoordinator = SymbolCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenSearchField(
                text: $searchText,
                placeholder: String(
                    localized: "symbolNavigator.placeholder",
                    locale: locale
                ),
                accessibility: CommandOverlayTextFieldAccessibility(
                    identifier: AccessibilityID.symbolSearchField,
                    label: String(
                        localized: "symbolNavigator.placeholder",
                        locale: locale
                    )
                ),
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturn: { navigateToSelected() },
                onEscape: { isPresented = false }
            )
            .padding(10)

            Divider()
            resultsList
        }
        .frame(
            minWidth: 300,
            idealWidth: 500,
            maxWidth: 500,
            minHeight: 220,
            idealHeight: 360,
            maxHeight: 360
        )
        .onAppear {
            loadSymbols()
        }
        .onDisappear {
            symbolTask?.cancel()
            symbolCoordinator.invalidate()
        }
        .onChange(of: searchText) { _, _ in
            updateFilteredSymbols()
        }
        .onChange(
            of: projectManager.activeTabManager.activeTab?.contentVersion
        ) { _, _ in
            loadSymbols()
        }
        .onChange(
            of: projectManager.activeTabManager.activeTabID
        ) { _, _ in
            loadSymbols()
        }
        .onChange(
            of: projectManager.lspManager.foldingRefreshGeneration
        ) { _, _ in
            // The navigator may open while didOpen is still initializing the
            // server. Retry when that shared structural lifecycle token says
            // the exact editor buffer is queryable.
            loadSymbols()
        }
        .accessibilityIdentifier(
            AccessibilityID.symbolNavigatorOverlay
        )
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
                        LazyVStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            ForEach(
                                Array(filteredSymbols.enumerated()),
                                id: \.element.id
                            ) { index, entry in
                                symbolRow(
                                    entry,
                                    isSelected:
                                        index == selectedIndex
                                )
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    navigateToSymbol(entry)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction {
                                    selectedIndex = index
                                    navigateToSymbol(entry)
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
        .animation(
            PineAnimation.content,
            value: filteredSymbols.isEmpty
        )
        .accessibilityIdentifier(
            AccessibilityID.symbolResultsList
        )
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

    private func symbolRow(
        _ entry: SymbolNavigatorEntry,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if entry.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                    .frame(width: 10)
            }

            Image(systemName: entry.symbol.kind.iconName)
                .font(.system(size: 14))
                .foregroundStyle(colorForKind(entry.symbol.kind))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.symbol.name)
                    .font(
                        .system(
                            size: 13,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(symbolSecondaryLabel(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier(
            AccessibilityID.symbolItem(entry.symbol.name)
        )
    }

    private func symbolSecondaryLabel(
        for entry: SymbolNavigatorEntry
    ) -> String {
        let kind = Strings.symbolKindName(
            entry.symbol.kind,
            locale: locale
        )
        return "\(kind) — line \(entry.line)"
    }

    // MARK: - Loading

    private func loadSymbols() {
        symbolTask?.cancel()
        guard let tab =
            projectManager.activeTabManager.activeTab else {
            applyEntries([])
            return
        }

        let url = tab.url
        let text = tab.content
        let revision = symbolCoordinator.beginRevision()
        let snapshot = DocumentSnapshot(
            uri: url.absoluteString,
            text: text,
            revision: revision
        )
        let regexProvider = RegexSymbolProvider(
            fileExtension: url.pathExtension
        )
        let coordinator = symbolCoordinator
        let lspManager = projectManager.lspManager
        let capabilities =
            StructuralLanguageRegistry.capabilities(for: url)
        let lspProvider: (any SymbolProviding)? =
            capabilities.hasConfiguredLSPServer
            ? LSPDocumentSymbolProvider { requestSnapshot in
                await lspManager.documentSymbols(
                    url: url,
                    text: requestSnapshot.text
                )
            }
            : nil

        symbolTask = Task {
            let regexSymbols =
                await regexProvider.symbols(for: snapshot) ?? []
            let regexEntries = await Task.detached {
                SymbolNavigatorEntry.flatten(
                    regexSymbols,
                    snapshot: snapshot
                )
            }.value
            guard !Task.isCancelled,
                  coordinator.isCurrent(revision),
                  isSnapshotCurrent(
                    url: url,
                    text: text,
                    revision: revision
                  ) else {
                return
            }

            // Keep the local result visible throughout the LSP request.
            applyEntries(regexEntries)
            let resolution = await coordinator.refine(
                snapshot: snapshot,
                regexSymbols: regexSymbols,
                lspProvider: lspProvider
            )

            if case .resolved(let symbols, source: .lsp) = resolution {
                let lspEntries = await Task.detached {
                    SymbolNavigatorEntry.flatten(
                        symbols,
                        snapshot: snapshot
                    )
                }.value
                guard !Task.isCancelled,
                      isSnapshotCurrent(
                        url: url,
                        text: text,
                        revision: revision
                      ) else {
                    return
                }
                applyEntries(lspEntries)
            }
        }
    }

    private func isSnapshotCurrent(
        url: URL,
        text: String,
        revision: DocumentRevision
    ) -> Bool {
        guard symbolCoordinator.isCurrent(revision),
              let tab =
                projectManager.activeTabManager.activeTab else {
            return false
        }
        return tab.url == url && tab.content == text
    }

    private func applyEntries(
        _ entries: [SymbolNavigatorEntry]
    ) {
        allSymbols = entries
        updateFilteredSymbols()
    }

    private func updateFilteredSymbols() {
        if searchText.isEmpty {
            filteredSymbols = allSymbols
        } else {
            let query = searchText.lowercased()
            filteredSymbols = allSymbols.filter {
                QuickOpenProvider.isSubsequence(
                    query,
                    of: $0.symbol.name.lowercased()
                )
            }
        }
        selectedIndex = 0
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) {
        guard !filteredSymbols.isEmpty else { return }
        selectedIndex = max(
            0,
            min(
                filteredSymbols.count - 1,
                selectedIndex + delta
            )
        )
    }

    private func navigateToSelected() {
        guard selectedIndex < filteredSymbols.count else { return }
        navigateToSymbol(filteredSymbols[selectedIndex])
    }

    private func navigateToSymbol(_ entry: SymbolNavigatorEntry) {
        guard let tab =
            projectManager.activeTabManager.activeTab else {
            return
        }
        guard symbolCoordinator.isCurrent(entry.snapshot.revision),
              entry.matches(url: tab.url, text: tab.content) else {
            return
        }
        let length = (tab.content as NSString).length
        let offset = min(
            max(0, entry.symbol.selectionRange.location),
            length
        )
        NotificationCenter.default.post(
            name: .symbolNavigate,
            object: projectManager,
            userInfo: ["offset": offset]
        )
        isPresented = false
    }

    // MARK: - Helpers

    private func colorForKind(_ kind: SymbolKind) -> Color {
        switch kind {
        case .class, .namespace:
            .purple
        case .struct:
            .blue
        case .enum:
            .orange
        case .interface:
            .green
        case .function:
            .cyan
        case .property, .variable, .other:
            .secondary
        }
    }
}

nonisolated private extension SymbolKind {
    var iconName: String {
        switch self {
        case .class:
            "c.square"
        case .struct:
            "s.square"
        case .enum:
            "e.square"
        case .interface:
            "i.square"
        case .namespace:
            "shippingbox"
        case .function:
            "f.square"
        case .property, .variable:
            "v.square"
        case .other:
            "circle"
        }
    }
}
