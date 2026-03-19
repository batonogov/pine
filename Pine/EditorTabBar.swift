//
//  EditorTabBar.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Internal tab bar for editor tabs, styled like the terminal tab bar.
struct EditorTabBar: View {
    var tabs: [EditorTab]
    var activeTabID: UUID?
    var onSelectTab: (UUID) -> Void
    var onCloseTab: (EditorTab) -> Void
    /// Called after tabs are reordered via drag-and-drop, with the new tab order.
    var onReorder: (([EditorTab]) -> Void)?
    /// Whether the active tab is a Markdown file.
    var isMarkdownFile: Bool = false
    /// Current preview mode of the active tab.
    var previewMode: MarkdownPreviewMode = .source
    /// Called when the user toggles the Markdown preview mode.
    var onTogglePreview: (() -> Void)?
    /// Called when the user clicks the split editor button.
    var onSplitRight: (() -> Void)?
    /// Called when the user chooses "Open in Split Right" from context menu.
    var onOpenInSplit: ((URL) -> Void)?

    @State private var draggingTabID: UUID?
    @State private var orderedTabs: [EditorTab] = []

    private var previewIcon: String {
        switch previewMode {
        case .source: "doc.plaintext"
        case .preview: "eye"
        case .split: "rectangle.split.2x1"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(orderedTabs) { tab in
                        EditorTabItem(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            onSelect: { onSelectTab(tab.id) },
                            onClose: { onCloseTab(tab) },
                            onOpenInSplit: onOpenInSplit != nil ? { onOpenInSplit?(tab.url) } : nil
                        )
                        .onDrag {
                            draggingTabID = tab.id
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            tabs: $orderedTabs,
                            targetTabID: tab.id,
                            draggingTabID: $draggingTabID,
                            onReorder: onReorder
                        ))
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            if isMarkdownFile {
                Button {
                    onTogglePreview?()
                } label: {
                    Image(systemName: previewIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(Strings.menuTogglePreview)
                .accessibilityIdentifier(AccessibilityID.markdownPreviewToggle)
                .padding(.trailing, 4)
            }

            if let onSplitRight {
                Button {
                    onSplitRight()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(Strings.menuSplitEditorRight)
                .accessibilityIdentifier(AccessibilityID.splitEditorButton)
                .padding(.trailing, 4)
            }
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.editorTabBar)
        .onAppear { orderedTabs = tabs }
        .onChange(of: tabs) { _, newTabs in orderedTabs = newTabs }
    }
}

/// Convenience initializer preserving the old TabManager-based API
/// so existing call sites don't need to change all at once.
extension EditorTabBar {
    init(
        tabManager: TabManager,
        onCloseTab: @escaping (EditorTab) -> Void,
        onReorder: (() -> Void)? = nil,
        isMarkdownFile: Bool = false,
        previewMode: MarkdownPreviewMode = .source,
        onTogglePreview: (() -> Void)? = nil,
        onSplitRight: (() -> Void)? = nil,
        onOpenInSplit: ((URL) -> Void)? = nil
    ) {
        self.tabs = tabManager.tabs
        self.activeTabID = tabManager.activeTabID
        self.onSelectTab = { tabManager.activeTabID = $0 }
        self.onCloseTab = onCloseTab
        self.onReorder = onReorder.map { callback in
            { newTabs in
                tabManager.tabs = newTabs
                callback()
            }
        }
        self.isMarkdownFile = isMarkdownFile
        self.previewMode = previewMode
        self.onTogglePreview = onTogglePreview
        self.onSplitRight = onSplitRight
        self.onOpenInSplit = onOpenInSplit
    }
}

/// Handles drag-to-reorder for editor tabs.
struct TabDropDelegate: DropDelegate {
    @Binding var tabs: [EditorTab]
    let targetTabID: UUID
    @Binding var draggingTabID: UUID?
    var onReorder: (([EditorTab]) -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        draggingTabID = nil
        onReorder?(tabs)
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTabID, dragging != targetTabID else { return }
        guard let fromIndex = tabs.firstIndex(where: { $0.id == dragging }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// A single editor tab item (capsule style, matching terminal tabs).
struct EditorTabItem: View {
    let tab: EditorTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onOpenInSplit: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Close button — visible on hover or when active
            Button(action: onClose) {
                ZStack {
                    if tab.isDirty && !isHovering {
                        // Dirty dot when not hovering
                        Circle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                .background(
                    isHovering ? Color.primary.opacity(0.1) : .clear,
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive || tab.isDirty ? 1 : 0.01)
            .accessibilityIdentifier(AccessibilityID.editorTabCloseButton(tab.fileName))

            Image(systemName: FileIconMapper.iconForFile(tab.fileName))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.fileName)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onOpenInSplit {
                Button {
                    onOpenInSplit()
                } label: {
                    Label(Strings.contextOpenInSplitRight, systemImage: "rectangle.split.2x1")
                }
            }
        }
        .accessibilityRepresentation {
            HStack {
                Button(tab.fileName, action: onSelect)
                    .accessibilityIdentifier(AccessibilityID.editorTab(tab.fileName))
                Button("Close", action: onClose)
                    .accessibilityIdentifier(AccessibilityID.editorTabCloseButton(tab.fileName))
            }
        }
    }
}
