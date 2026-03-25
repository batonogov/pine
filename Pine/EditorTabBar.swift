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
    @State private var hoverTargetTabID: UUID?

    /// Minimum tab width before scrolling kicks in.
    static let minTabWidth: CGFloat = 80
    /// Maximum tab width when there is plenty of space.
    static let maxTabWidth: CGFloat = 180

    private var previewIcon: String {
        switch previewMode {
        case .source: "doc.plaintext"
        case .preview: "eye"
        case .split: "rectangle.split.2x1"
        }
    }

    /// Width for pinned tabs — compact, icon-focused.
    static let pinnedTabWidth: CGFloat = 40

    /// Computes tab widths: active tab stays at full width, inactive tabs share the rest.
    /// Pinned tabs always use `pinnedTabWidth` and are excluded from the dynamic calculation.
    static func inactiveTabWidth(availableWidth: CGFloat, tabCount: Int, pinnedCount: Int = 0) -> CGFloat {
        let unpinnedCount = tabCount - pinnedCount
        guard unpinnedCount > 1 else { return maxTabWidth }
        let totalPadding: CGFloat = 12 // 4pt leading + 8pt trailing
        let totalSpacing = CGFloat(max(tabCount - 1, 0)) * 2 // 2pt spacing between tabs
        let pinnedSpace = CGFloat(pinnedCount) * pinnedTabWidth
        let usable = availableWidth - totalPadding - totalSpacing - pinnedSpace - maxTabWidth
        let inactiveCount = CGFloat(unpinnedCount - 1)
        let perTab = usable / inactiveCount
        return min(max(perTab, minTabWidth), maxTabWidth)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            let pinnedCount = tabManager.pinnedTabCount
                            let inactiveWidth = Self.inactiveTabWidth(
                                availableWidth: geometry.size.width,
                                tabCount: tabManager.tabs.count,
                                pinnedCount: pinnedCount
                            )
                            ForEach(tabManager.tabs) { tab in
                                let isActive = tab.id == tabManager.activeTabID
                                let isDragged = tab.id == draggingTabID
                                EditorTabItem(
                                    tab: tab,
                                    isActive: isActive,
                                    onSelect: { tabManager.activeTabID = tab.id },
                                    onClose: { onCloseTab(tab) },
                                    onTogglePin: { tabManager.togglePin(id: tab.id) }
                                )
                                .frame(
                                    maxWidth: tab.isPinned
                                        ? Self.pinnedTabWidth
                                        : isActive ? Self.maxTabWidth : inactiveWidth
                                )
                                .opacity(isDragged ? 0.4 : 1.0)
                                .scaleEffect(isDragged ? 0.95 : 1.0)
                                .transaction { $0.animation = nil }
                                .id(tab.id)
                                .onDrag {
                                    draggingTabID = tab.id
                                    return NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    tabManager: tabManager,
                                    targetTabID: tab.id,
                                    draggingTabID: $draggingTabID,
                                    hoverTargetTabID: $hoverTargetTabID,
                                    onReorder: onReorder
                                ))
                            }

                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .onAppear {
                        if let activeID = tabManager.activeTabID {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                    .onChange(of: tabManager.activeTabID) {
                        guard let activeID = tabManager.activeTabID else { return }
                        withAnimation(PineAnimation.quick) {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                }
            }

            // Overflow menu — quick access to all open tabs
            if tabManager.tabs.count > 1 {
                Menu {
                    ForEach(tabManager.tabs) { tab in
                        Button {
                            tabManager.activeTabID = tab.id
                        } label: {
                            Label {
                                Text(tab.fileName)
                                    + Text(tab.isDirty ? " \u{25CF}" : "")
                            } icon: {
                                Image(systemName: tab.isPinned
                                      ? "pin.fill"
                                      : FileIconMapper.iconForFile(tab.fileName))
                            }
                        }
                        .disabled(tab.id == tabManager.activeTabID)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: LayoutMetrics.iconSmallFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 24, height: 30)
                .accessibilityIdentifier(AccessibilityID.editorTabOverflowMenu)
            }

            Group {
                if isAutoSaving {
                    Text(Strings.autoSaving)
                        .font(.system(size: LayoutMetrics.captionFontSize))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                        .accessibilityIdentifier(AccessibilityID.autoSaveIndicator)
                        .padding(.trailing, 4)
                }
            }
            .animation(PineAnimation.quick, value: isAutoSaving)

            if isMarkdownFile {
                Button {
                    onTogglePreview?()
                } label: {
                    Image(systemName: previewIcon)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(Strings.menuTogglePreview)
                .accessibilityIdentifier(AccessibilityID.markdownPreviewToggle)
                .padding(.trailing, 4)
            }
        }
        .frame(height: LayoutMetrics.tabBarHeight)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.editorTabBar)
    }
}

/// Handles drag-to-reorder for editor tabs.
/// Provides visual feedback via `hoverTargetTabID` and smooth spring animations.
struct TabDropDelegate: DropDelegate {
    let tabManager: TabManager
    let targetTabID: UUID
    @Binding var draggingTabID: UUID?
    @Binding var hoverTargetTabID: UUID?
    var onReorder: (() -> Void)?

    /// Spring animation matching Safari's tab reordering feel.
    private static let reorderAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.8)

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(Self.reorderAnimation) {
            hoverTargetTabID = nil
            draggingTabID = nil
        }
        onReorder?()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTabID, dragging != targetTabID else { return }
        hoverTargetTabID = targetTabID
        withAnimation(Self.reorderAnimation) {
            tabManager.reorderTab(draggedID: dragging, targetID: targetTabID)
        }
    }

    func dropExited(info: DropInfo) {
        hoverTargetTabID = nil
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
    var onTogglePin: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Group {
            if tab.isPinned {
                pinnedBody
            } else {
                unpinnedBody
            }
        }
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .contentShape(Capsule())
        .animation(PineAnimation.quick, value: isActive)
        .animation(PineAnimation.quick, value: isHovering)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                onTogglePin?()
            } label: {
                Label(
                    tab.isPinned ? Strings.tabUnpin : Strings.tabPin,
                    systemImage: tab.isPinned ? "pin.slash" : "pin"
                )
            }
            .accessibilityIdentifier(AccessibilityID.editorTabPinToggle(tab.fileName))

            if !tab.isPinned {
                Button(role: .destructive) {
                    onClose()
                } label: {
                    Label(Strings.menuCloseTab, systemImage: "xmark")
                }
            }
        }
        .accessibilityRepresentation {
            HStack {
                Button(tab.fileName, action: onSelect)
                    .accessibilityIdentifier(AccessibilityID.editorTab(tab.fileName))
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                if !tab.isPinned {
                    Button("Close", action: onClose)
                        .accessibilityIdentifier(AccessibilityID.editorTabCloseButton(tab.fileName))
                }
            }
        }
    }

    /// Pinned tab: compact, icon-only with a subtle pin indicator.
    private var pinnedBody: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: FileIconMapper.iconForFile(tab.fileName))
                .font(.system(size: LayoutMetrics.iconSmallFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            if tab.isDirty {
                Circle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .offset(x: -4, y: 4)
            }
        }
    }

    /// Standard unpinned tab with close button and file name.
    private var unpinnedBody: some View {
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
                .font(.system(size: LayoutMetrics.iconSmallFontSize))
                .foregroundStyle(.secondary)

            Text(tab.fileName)
                .font(.system(size: LayoutMetrics.bodySmallFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
