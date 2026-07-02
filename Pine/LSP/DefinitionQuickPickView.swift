//
//  DefinitionQuickPickView.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  A SwiftUI overlay that shows a quick-pick list when go-to-definition
//  returns multiple locations. The user selects one to navigate to.
//
//  Follows the same overlay pattern as QuickOpenView and the completion
//  popup.
//

import SwiftUI
import AppKit

/// `@MainActor @Observable` controller for the definition quick-pick popup.
@MainActor
@Observable
final class DefinitionQuickPickController {

    /// Whether the popup is currently visible.
    private(set) var isVisible: Bool = false

    /// The locations to choose from.
    private(set) var items: [DefinitionQuickPickItem] = []

    /// The index of the highlighted row.
    private(set) var selectedIndex: Int = 0

    /// Called when the user selects an item.
    var onSelect: ((DefinitionQuickPickItem) -> Void)?

    /// Called when the user dismisses without selecting.
    var onDismiss: (() -> Void)?

    init() {}

    // MARK: - Presentation

    /// Presents the quick-pick with the given locations.
    func present(items: [DefinitionQuickPickItem]) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        self.items = items
        selectedIndex = 0
        isVisible = true
    }

    /// Hides the popup.
    func dismiss() {
        isVisible = false
        items = []
        selectedIndex = 0
    }

    // MARK: - Navigation

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        var newIndex = selectedIndex + delta
        if newIndex < 0 { newIndex = count - 1 }
        if newIndex >= count { newIndex = 0 }
        selectedIndex = newIndex
    }

    func selectCurrent() {
        guard selectedIndex >= 0, selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        dismiss()
        onSelect?(item)
    }

    func cancel() {
        dismiss()
        onDismiss?()
    }
}

/// A single item in the definition quick-pick list.
///
/// `nonisolated` + `Sendable` because it is pure data created on the main
/// actor from LSP response types.
nonisolated struct DefinitionQuickPickItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String
    let url: URL
    let line: Int
    let character: Int

    init(label: String, detail: String, url: URL, line: Int, character: Int) {
        self.label = label
        self.detail = detail
        self.url = url
        self.line = line
        self.character = character
        self.id = "\(url.path):\(line):\(character)"
    }
}

/// SwiftUI overlay content for the definition quick-pick.
struct DefinitionQuickPickContent: View {
    let controller: DefinitionQuickPickController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                            DefinitionRow(item: item, isSelected: index == controller.selectedIndex)
                                .id(index)
                                .onTapGesture(count: 2) {
                                    controller.selectedIndex = index
                                    controller.selectCurrent()
                                }
                                .onTapGesture {
                                    controller.selectedIndex = index
                                }
                        }
                    }
                }
                .onChange(of: controller.selectedIndex) { _, newIndex in
                    withAnimation(nil) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 400, height: min(CGFloat(controller.items.count) * 22 + 8, 220))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(NSColor.separatorColor.colorWithAlphaComponent(0.5), lineWidth: 1)
        )
    }
}

/// Overlay wrapper that positions the quick-pick centered in the editor
/// area and handles keyboard navigation (Esc, Up/Down, Enter).
struct DefinitionQuickPickOverlay: View {
    let controller: DefinitionQuickPickController

    var body: some View {
        ZStack {
            // Semi-transparent backdrop — click to dismiss.
            Color.black.opacity(0.01)
                .onTapGesture { controller.cancel() }
                .onKeyPress(.escape) { controller.cancel(); return .handled }
                .onKeyPress(.upArrow) { controller.move(by: -1); return .handled }
                .onKeyPress(.downArrow) { controller.move(by: 1); return .handled }
                .onKeyPress(.return) { controller.selectCurrent(); return .handled }

            VStack {
                DefinitionQuickPickContent(controller: controller)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .padding(.top, 40)
                Spacer()
            }
        }
    }
}

/// Extracted row view for definition quick-pick items.
private struct DefinitionRow: View {
    let item: DefinitionQuickPickItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(item.label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
