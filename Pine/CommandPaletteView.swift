//
//  CommandPaletteView.swift
//  Pine
//
//  Searchable built-in command + user task palette (issue #1117).
//

import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let items: [CommandPaletteItem]
    let onInvoke: (CommandPaletteItem) -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0

    private var filteredItems: [CommandPaletteItem] {
        CommandPaletteSearch.filter(items, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenSearchField(
                text: $searchText,
                placeholder: String(localized: "commandPalette.placeholder"),
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturn: { invokeSelected() },
                onEscape: { isPresented = false }
            )
            .accessibilityIdentifier(AccessibilityID.commandPaletteSearchField)
            .padding(10)

            Divider()
            resultsList
        }
        .frame(
            minWidth: 320,
            idealWidth: 560,
            maxWidth: 560,
            minHeight: 240,
            idealHeight: 400,
            maxHeight: 400
        )
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: filteredItems.map(\.id)) { _, newIDs in
            if newIDs.isEmpty {
                selectedIndex = 0
            } else {
                selectedIndex = min(selectedIndex, newIDs.count - 1)
            }
        }
        .accessibilityIdentifier(AccessibilityID.commandPaletteOverlay)
    }

    private var resultsList: some View {
        Group {
            if filteredItems.isEmpty {
                VStack {
                    Spacer()
                    Text("commandPalette.noResults")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        guard item.isEnabled else { return }
                                        selectedIndex = index
                                        invoke(item)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction {
                                        guard item.isEnabled else { return }
                                        selectedIndex = index
                                        invoke(item)
                                    }
                                    .disabled(!item.isEnabled)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.commandPaletteResultsList)
    }

    private func row(
        _ item: CommandPaletteItem,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.iconName)
                .font(.system(size: 14))
                .foregroundStyle(item.isTask ? Color.orange : Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            shortcutState(for: item.shortcut.state)

            if let shortcut = item.shortcut.displayText {
                Text(shortcut)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(
                        item.shortcut.state == .shadowed
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.secondary)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .opacity(item.isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.commandPaletteItem(item.id.accessibilityToken))
    }

    @ViewBuilder
    private func shortcutState(
        for state: CommandShortcutState
    ) -> some View {
        switch state {
        case .userOverride:
            Text("commandPalette.shortcutOverride")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        case .shadowed:
            Text("commandPalette.shortcutConflict")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        case .builtIn, .none:
            EmptyView()
        }
    }

    private func moveSelection(by delta: Int) {
        selectedIndex = CommandPaletteNavigation.movedIndex(
            from: selectedIndex,
            by: delta,
            itemCount: filteredItems.count
        )
    }

    private func invokeSelected() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        let item = filteredItems[selectedIndex]
        guard item.isEnabled else { return }
        invoke(item)
    }

    private func invoke(_ item: CommandPaletteItem) {
        onInvoke(item)
        // `onInvoke` may synchronously replace Command Palette with another
        // shared overlay. Re-read the binding before dismissing so this stale
        // view cannot tear down its replacement.
        if isPresented {
            isPresented = false
        }
    }
}

nonisolated private extension CommandPaletteItemID {
    var accessibilityToken: String {
        switch self {
        case .builtIn(let command):
            "command_\(command.rawValue)"
        case .task(let id):
            "task_\(id)"
        }
    }
}
