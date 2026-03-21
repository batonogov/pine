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
    var tabManager: TabManager
    /// Called when user clicks the close button on a tab.
    /// The caller is responsible for unsaved-changes protection.
    var onCloseTab: (EditorTab) -> Void
    /// Called after tabs are reordered via drag-and-drop.
    var onReorder: (() -> Void)?
    /// Whether the active tab is a Markdown file.
    var isMarkdownFile: Bool = false
    /// Current preview mode of the active tab.
    var previewMode: MarkdownPreviewMode = .source
    /// Called when the user toggles the Markdown preview mode.
    var onTogglePreview: (() -> Void)?
    /// Whether an auto-save is in progress (shows a subtle indicator).
    var isAutoSaving: Bool = false

    @State private var draggingTabID: UUID?

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
                    ForEach(tabManager.tabs) { tab in
                        EditorTabItem(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { onCloseTab(tab) }
                        )
                        .onDrag {
                            draggingTabID = tab.id
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            tabManager: tabManager,
                            targetTabID: tab.id,
                            draggingTabID: $draggingTabID,
                            onReorder: onReorder
                        ))
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            Group {
                if isAutoSaving {
                    Text(Strings.autoSaving)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                        .accessibilityIdentifier(AccessibilityID.autoSaveIndicator)
                        .padding(.trailing, 4)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isAutoSaving)

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
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.editorTabBar)
    }
}

/// Handles drag-to-reorder for editor tabs.
struct TabDropDelegate: DropDelegate {
    let tabManager: TabManager
    let targetTabID: UUID
    @Binding var draggingTabID: UUID?
    var onReorder: (() -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        draggingTabID = nil
        onReorder?()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTabID, dragging != targetTabID else { return }
        guard let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == dragging }),
              let toIndex = tabManager.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabManager.tabs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
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
        .accessibilityRepresentation {
            HStack {
                Button(tab.fileName, action: onSelect)
                    .accessibilityIdentifier(AccessibilityID.editorTab(tab.fileName))
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                Button("Close", action: onClose)
                    .accessibilityIdentifier(AccessibilityID.editorTabCloseButton(tab.fileName))
            }
        }
    }
}
