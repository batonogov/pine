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
    /// Called when user chooses "Close Other Tabs" from context menu.
    var onCloseOtherTabs: ((UUID) -> Void)?
    /// Called when user chooses "Close Tabs to the Right" from context menu.
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    /// Called when user chooses "Close All Tabs" from context menu.
    var onCloseAllTabs: (() -> Void)?
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
    /// Project root URL for computing relative paths.
    var projectRootURL: URL?
    /// Optional pane ID override for drag operations. When nil, uses the active pane.
    var overridePaneID: PaneID?

    /// Computes the relative path of a file URL relative to a project root URL.
    /// Normalizes both paths via `standardizedFileURL` to handle trailing slashes
    /// and symlinks consistently.
    static func computeRelativePath(fileURL: URL, projectRootURL: URL?) -> String {
        guard let root = projectRootURL else { return fileURL.path }
        let normalizedFile = fileURL.standardizedFileURL.path
        let normalizedRoot = root.standardizedFileURL.path
        // Ensure root path ends with "/" for clean prefix stripping
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        if normalizedFile.hasPrefix(rootPrefix) {
            return String(normalizedFile.dropFirst(rootPrefix.count))
        }
        return fileURL.path
    }

    @Environment(PaneManager.self) private var paneManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var autoScrollSession = TabStripAutoScrollSession()

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

    private var paneID: PaneID { overridePaneID ?? paneManager.activePaneID }
    private var coordinateSpaceName: String { "editor-tab-strip-\(paneID.id.uuidString)" }

    private var activeAutoScrollOwner: TabStripAutoScrollOwner? {
        TabStripAutoScrollOwner.current(
            activeDrag: paneManager.activeDrag,
            previewIntent: paneManager.tabDragCoordinator.previewIntent
        )
    }

    private var insertionIndicatorX: CGFloat? {
        guard let intent = paneManager.tabDragCoordinator.previewIntent,
              intent.destinationPaneID == paneID,
              intent.drag.contentType == .editor,
              let insertionIndex = intent.insertionIndex else { return nil }
        return TabStripInsertionGeometry.indicatorX(
            for: insertionIndex,
            orderedTabIDs: tabManager.tabs.map(\.id),
            frames: tabFrames
        )
    }

    /// Computes one stable width for every unpinned tab. Pinned tabs always
    /// use `pinnedTabWidth` and are excluded from the dynamic calculation.
    static func unpinnedTabWidth(
        availableWidth: CGFloat,
        tabCount: Int,
        pinnedCount: Int = 0
    ) -> CGFloat {
        let unpinnedCount = tabCount - pinnedCount
        guard unpinnedCount > 0 else { return maxTabWidth }
        let totalPadding: CGFloat = 12 // 4pt leading + 8pt trailing
        let totalSpacing = CGFloat(max(tabCount - 1, 0)) * 2 // 2pt spacing between tabs
        let pinnedSpace = CGFloat(pinnedCount) * pinnedTabWidth
        let usable = availableWidth - totalPadding - totalSpacing - pinnedSpace
        let perTab = usable / CGFloat(unpinnedCount)
        return min(max(perTab, minTabWidth), maxTabWidth)
    }

    private func dropDelegate(
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) -> TabStripDropDelegate {
        TabStripDropDelegate(
            paneID: paneID,
            contentType: .editor,
            orderedTabIDs: orderedTabIDs,
            frames: frames,
            paneManager: paneManager,
            onCommit: onReorder,
            onHover: { dragID, locationX in
                autoScrollSession.updateHover(
                    owner: TabStripAutoScrollOwner(
                        dragID: dragID,
                        destinationPaneID: paneID.id
                    ),
                    locationX: locationX,
                    viewportWidth: viewportWidth,
                    orderedTabIDs: orderedTabIDs,
                    frames: frames
                )
            },
            onExit: {
                autoScrollSession.end()
            }
        )
    }

    private func refreshPreviewAfterGeometryChange(
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) {
        guard let locationX = autoScrollSession.hoverLocationX,
              autoScrollSession.hoveredOwner == activeAutoScrollOwner else {
            autoScrollSession.end()
            return
        }
        _ = dropDelegate(
            orderedTabIDs: orderedTabIDs,
            frames: frames,
            viewportWidth: viewportWidth
        ).preview(atX: locationX)
    }

    private func runAutoScroll(
        request: TabStripAutoScrollRequest,
        proxy: ScrollViewProxy
    ) async {
        while !Task.isCancelled {
            guard autoScrollSession.request == request,
                  activeAutoScrollOwner == request.owner,
                  let targetID = autoScrollSession.targetID else {
                return
            }
            proxy.scrollTo(
                targetID,
                anchor: request.direction == .leading ? .leading : .trailing
            )
            do {
                try await Task.sleep(for: TabStripAutoScrollGeometry.stepDelay)
            } catch {
                return
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            let pinnedCount = tabManager.pinnedTabCount
                            let unpinnedWidth = Self.unpinnedTabWidth(
                                availableWidth: geometry.size.width,
                                tabCount: tabManager.tabs.count,
                                pinnedCount: pinnedCount
                            )
                            ForEach(tabManager.tabs) { tab in
                                let isActive = tab.id == tabManager.activeTabID
                                let isDragged = paneManager.activeDrag.map { drag in
                                    drag.paneID == paneID.id
                                        && drag.tabID == tab.id
                                        && drag.contentType == .editor
                                } ?? false
                                EditorTabItem(
                                    tab: tab,
                                    isActive: isActive,
                                    onSelect: {
                                        paneManager.selectEditorTab(tab.id, in: paneID)
                                    },
                                    onClose: { onCloseTab(tab) },
                                    onTogglePin: { tabManager.togglePin(id: tab.id) },
                                    onCloseOtherTabs: {
                                        onCloseOtherTabs?(tab.id)
                                    },
                                    onCloseTabsToTheRight: {
                                        onCloseTabsToTheRight?(tab.id)
                                    },
                                    onCloseAllTabs: { onCloseAllTabs?() },
                                    onCopyPath: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            tab.url.path, forType: .string
                                        )
                                    },
                                    onCopyRelativePath: {
                                        let relativePath = Self.computeRelativePath(
                                            fileURL: tab.url,
                                            projectRootURL: projectRootURL
                                        )
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            relativePath, forType: .string
                                        )
                                    },
                                    onRevealInSidebar: {
                                        NotificationCenter.default.post(
                                            name: .revealInSidebar,
                                            object: nil,
                                            userInfo: ["url": tab.url]
                                        )
                                    },
                                    onRevealInFinder: {
                                        NSWorkspace.shared.activateFileViewerSelecting(
                                            [tab.url]
                                        )
                                    },
                                    constrainedWidth: tab.isPinned
                                        ? Self.pinnedTabWidth
                                        : unpinnedWidth
                                )
                                .opacity(isDragged ? 0.4 : 1.0)
                                .scaleEffect(isDragged ? 0.95 : 1.0)
                                .transaction { $0.animation = nil }
                                .id(tab.id)
                                .reportTabStripFrame(
                                    tabID: tab.id,
                                    coordinateSpace: coordinateSpaceName
                                )
                                .onDrag {
                                    let info = paneManager.beginTabDrag(
                                        paneID: paneID,
                                        tabID: tab.id,
                                        fileURL: tab.url,
                                        contentType: .editor
                                    )
                                    return info.itemProvider()
                                }
                            }

                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: coordinateSpaceName)
                    .onPreferenceChange(TabStripFramePreferenceKey.self) { frames in
                        let orderedTabIDs = tabManager.tabs.map(\.id)
                        tabFrames = frames
                        autoScrollSession.updateGeometry(
                            viewportWidth: geometry.size.width,
                            orderedTabIDs: orderedTabIDs,
                            frames: frames
                        )
                        refreshPreviewAfterGeometryChange(
                            orderedTabIDs: orderedTabIDs,
                            frames: frames,
                            viewportWidth: geometry.size.width
                        )
                    }
                    .overlay(alignment: .topLeading) {
                        if let insertionIndicatorX {
                            TabInsertionIndicator(x: insertionIndicatorX)
                        }
                    }
                    .onDrop(of: [.paneTabDrag], delegate: dropDelegate(
                        orderedTabIDs: tabManager.tabs.map(\.id),
                        frames: tabFrames,
                        viewportWidth: geometry.size.width
                    ))
                    .task(id: autoScrollSession.request) {
                        guard let request = autoScrollSession.request else { return }
                        await runAutoScroll(request: request, proxy: proxy)
                    }
                    .onAppear {
                        if let activeID = tabManager.activeTabID {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                    .onDisappear {
                        autoScrollSession.end()
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        let orderedTabIDs = tabManager.tabs.map(\.id)
                        autoScrollSession.updateGeometry(
                            viewportWidth: width,
                            orderedTabIDs: orderedTabIDs,
                            frames: tabFrames
                        )
                        refreshPreviewAfterGeometryChange(
                            orderedTabIDs: orderedTabIDs,
                            frames: tabFrames,
                            viewportWidth: width
                        )
                    }
                    .onChange(of: activeAutoScrollOwner) { _, owner in
                        autoScrollSession.activeOwnerDidChange(to: owner)
                    }
                    .onChange(of: tabManager.activeTabID) {
                        guard let activeID = tabManager.activeTabID else { return }
                        if reduceMotion {
                            proxy.scrollTo(activeID, anchor: .center)
                        } else {
                            withAnimation(PineAnimation.quick) {
                                proxy.scrollTo(activeID, anchor: .center)
                            }
                        }
                    }
                }
            }

            // Overflow menu — quick access to all open tabs
            if tabManager.tabs.count > 1 {
                Menu {
                    ForEach(tabManager.tabs) { tab in
                        Button {
                            paneManager.selectEditorTab(tab.id, in: paneID)
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
            .animation(reduceMotion ? nil : PineAnimation.quick, value: isAutoSaving)

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
                .accessibilityLabel(Strings.menuTogglePreview)
                .accessibilityIdentifier(AccessibilityID.markdownPreviewToggle)
                .padding(.trailing, 4)
            }
        }
        .frame(height: LayoutMetrics.tabBarHeight)
        .background(.bar)
        // `.contain` keeps each interactive child as a discrete accessibility
        // element with its own identifier — without this hint, SwiftUI on
        // macOS lets the parent PaneLeafView's `paneLeaf_<id>` identifier
        // propagate to inline buttons (e.g. `markdownPreviewToggle`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.editorTabBar)
    }
}

/// A single editor tab item (capsule style, matching terminal tabs).
struct EditorTabItem: View {
    let tab: EditorTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onTogglePin: (() -> Void)?
    var onCloseOtherTabs: (() -> Void)?
    var onCloseTabsToTheRight: (() -> Void)?
    var onCloseAllTabs: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onCopyRelativePath: (() -> Void)?
    var onRevealInSidebar: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var constrainedWidth: CGFloat?

    @State private var isHovering = false
    @State private var closeGlyphFrame = CGRect.null

    var body: some View {
        Group {
            if tab.isPinned {
                pinnedBody
            } else {
                unpinnedBody
            }
        }
        .frame(width: constrainedWidth)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .frame(height: LayoutMetrics.tabBarHeight)
        .coordinateSpace(name: TabSlotHitTesting.coordinateSpaceName)
        .contentShape(.interaction, Rectangle())
        .contentShape(.dragPreview, Capsule())
        .animation(PineAnimation.quick, value: isActive)
        .animation(PineAnimation.quick, value: isHovering)
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    switch TabSlotHitTesting.target(
                        at: value.location,
                        canClose: !tab.isPinned,
                        closeGlyphFrame: closeGlyphFrame
                    ) {
                    case .close:
                        onClose()
                    case .select:
                        onSelect()
                    }
                }
        )
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

            Button(role: .destructive) {
                onClose()
            } label: {
                Label(Strings.menuCloseTab, systemImage: "xmark")
            }
            .disabled(tab.isPinned)
            .help(tab.isPinned ? Strings.tabCloseTabDisabledPinned : "")

            Divider()

            Button {
                onCloseOtherTabs?()
            } label: {
                Label(Strings.tabCloseOtherTabs, systemImage: MenuIcons.closeOtherTabs)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabCloseOthers(tab.fileName))

            Button {
                onCloseTabsToTheRight?()
            } label: {
                Label(Strings.tabCloseTabsToTheRight, systemImage: MenuIcons.closeTabsToTheRight)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabCloseRight(tab.fileName))

            Button(role: .destructive) {
                onCloseAllTabs?()
            } label: {
                Label(Strings.tabCloseAllTabs, systemImage: MenuIcons.closeAllTabs)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabCloseAll(tab.fileName))

            Divider()

            Button {
                onCopyPath?()
            } label: {
                Label(Strings.tabCopyPath, systemImage: MenuIcons.copyPath)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabCopyPath(tab.fileName))

            Button {
                onCopyRelativePath?()
            } label: {
                Label(Strings.tabCopyRelativePath, systemImage: MenuIcons.copyRelativePath)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabCopyRelativePath(tab.fileName))

            Divider()

            Button {
                onRevealInSidebar?()
            } label: {
                Label(Strings.tabRevealInSidebar, systemImage: MenuIcons.revealInSidebar)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabRevealInSidebar(tab.fileName))

            Button {
                onRevealInFinder?()
            } label: {
                Label(Strings.tabRevealInFinder, systemImage: MenuIcons.revealInFinder)
            }
            .accessibilityIdentifier(AccessibilityID.editorTabRevealInFinder(tab.fileName))
        }
        .onPreferenceChange(TabCloseGlyphFramePreferenceKey.self) { frame in
            closeGlyphFrame = frame
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
                .foregroundStyle(FileIconMapper.colorForFile(tab.fileName))
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
            // Passive close affordance. The full tab slot owns tap-vs-drag
            // routing so dragging can begin directly over this glyph.
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
            .opacity(isHovering || isActive || tab.isDirty ? 1 : 0.35)
            .allowsHitTesting(false)
            .reportsTabCloseGlyphFrame()

            Image(systemName: FileIconMapper.iconForFile(tab.fileName))
                .font(.system(size: LayoutMetrics.iconSmallFontSize))
                .foregroundStyle(FileIconMapper.colorForFile(tab.fileName))

            Text(tab.fileName)
                .font(.system(size: LayoutMetrics.bodySmallFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
