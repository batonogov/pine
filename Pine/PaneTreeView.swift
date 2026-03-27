//
//  PaneTreeView.swift
//  Pine
//
//  Created by Pine Team on 27.03.2026.
//

import AppKit
import SwiftUI

// MARK: - PaneTreeView

/// Recursively renders a `PaneNode` tree as nested split views.
///
/// Leaf nodes become `PaneLeafView` (wrapping `EditorAreaView` with
/// the correct `TabManager` injected). Split nodes become `PaneSplitView`
/// with a draggable divider.
struct PaneTreeView: View {
    let node: PaneNode
    @Environment(PaneManager.self) private var paneManager

    var body: some View {
        switch node {
        case .leaf(let id, let content):
            PaneLeafView(paneID: id, content: content)
        case .split(let axis, let first, let second, let ratio):
            PaneSplitView(axis: axis, first: first, second: second, ratio: ratio)
        }
    }
}

// MARK: - PaneLeafView

/// Wraps `EditorAreaView` for a single leaf pane.
///
/// Injects the pane's own `TabManager` into the environment so that
/// `EditorAreaView` (which reads `@Environment(TabManager.self)`)
/// picks up the correct instance without any changes.
struct PaneLeafView: View {
    let paneID: PaneID
    let content: PaneContent
    @Environment(PaneManager.self) private var paneManager

    private var isActive: Bool {
        paneManager.activePaneID == paneID
    }

    private var showBorder: Bool {
        isActive && paneManager.paneCount > 1
    }

    var body: some View {
        Group {
            if let tabManager = paneManager.tabManager(for: paneID) {
                Group {
                    switch content {
                    case .editor:
                        PaneEditorContent(paneID: paneID)
                    case .terminal:
                        PaneTerminalPlaceholder()
                    }
                }
                .environment(tabManager)
            } else {
                ContentUnavailableView {
                    Label(Strings.paneUnavailable, systemImage: "rectangle.slash")
                }
            }
        }
        .overlay {
            if showBorder {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            paneManager.focusPane(paneID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.pane(paneID))
    }
}

// MARK: - PaneEditorContent

/// Renders the real `EditorAreaView` for a leaf pane, owning all per-pane editor state.
///
/// Each pane independently tracks its own line diffs, blame lines, drag target state,
/// and go-to-line offset. Shared settings (minimap, blame visibility, word wrap) are
/// read from `@AppStorage` so all panes stay in sync.
struct PaneEditorContent: View {
    let paneID: PaneID

    @Environment(TabManager.self) private var tabManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager

    // Per-pane state — each pane owns its own instances
    @State private var lineDiffs: [GitLineDiff] = []
    @State private var blameLines: [GitBlameLine] = []
    @State private var blameTask: Task<Void, Never>?
    @State private var isDragTargeted = false
    @State private var goToLineOffset: GoToRequest?

    // Shared settings from AppStorage (identical across all panes)
    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true
    @AppStorage("wordWrapEnabled") private var isWordWrapEnabled = true

    var body: some View {
        EditorAreaView(
            lineDiffs: $lineDiffs,
            isDragTargeted: $isDragTargeted,
            goToLineOffset: $goToLineOffset,
            isBlameVisible: isBlameVisible,
            blameLines: blameLines,
            isMinimapVisible: isMinimapVisible,
            isWordWrapEnabled: isWordWrapEnabled,
            onCloseTab: { closeTabWithConfirmation($0) },
            onSaveSession: { projectManager.saveSession() }
        )
        .onChange(of: tabManager.activeTabID) { _, _ in
            refreshLineDiffs()
            refreshBlame()
        }
        .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
            if isRepo {
                refreshLineDiffs()
            } else {
                lineDiffs = []
            }
        }
        .onChange(of: workspace.gitProvider.currentBranch) { _, _ in
            refreshLineDiffs()
            refreshBlame()
        }
        .onChange(of: workspace.gitProvider.fileStatuses) { _, _ in
            refreshLineDiffs()
        }
        .onChange(of: isBlameVisible) { _, _ in
            refreshBlame()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLineDiffs)) { _ in
            refreshLineDiffs()
            refreshBlame()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateChange)) { notification in
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            navigateToChange(direction: direction == "next" ? .next : .previous)
        }
        .onReceive(NotificationCenter.default.publisher(for: .symbolNavigate)) { notification in
            guard let offset = notification.userInfo?["offset"] as? Int else { return }
            goToLineOffset = GoToRequest(offset: offset)
        }
        .task {
            refreshLineDiffs()
            refreshBlame()
        }
        .onChange(of: tabManager.pendingGoToLine) { _, newLine in
            guard let line = newLine, let tab = tabManager.activeTab else { return }
            tabManager.pendingGoToLine = nil
            goToLineOffset = GoToRequest(
                offset: ContentView.cursorOffset(forLine: line, in: tab.content)
            )
        }
    }

    // MARK: - Git diff refresh

    private func refreshLineDiffs() {
        guard let tab = tabManager.activeTab else {
            lineDiffs = []
            return
        }
        let fileURL = tab.url
        let provider = workspace.gitProvider
        guard provider.isGitRepository else {
            lineDiffs = []
            return
        }
        Task {
            let diffs = await provider.diffForFileAsync(at: fileURL)
            if tabManager.activeTab?.url == fileURL {
                lineDiffs = diffs
            }
        }
    }

    // MARK: - Git blame refresh

    private func refreshBlame() {
        blameTask?.cancel()
        guard isBlameVisible else {
            blameLines = []
            return
        }
        guard let tab = tabManager.activeTab else {
            blameLines = []
            return
        }
        let fileURL = tab.url
        let provider = workspace.gitProvider
        guard provider.isGitRepository, let repoURL = provider.repositoryURL else {
            blameLines = []
            return
        }
        let filePath = fileURL.path
        blameTask = Task.detached {
            let result = GitStatusProvider.runGit(
                ["blame", "--porcelain", "--", filePath], at: repoURL
            )
            guard !Task.isCancelled else { return }
            let lines: [GitBlameLine]
            if result.exitCode == 0, !result.output.isEmpty {
                lines = GitStatusProvider.parseBlame(result.output)
            } else {
                lines = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if tabManager.activeTab?.url == fileURL {
                    blameLines = lines
                }
            }
        }
    }

    // MARK: - Tab close with confirmation

    private func closeTabWithConfirmation(_ tab: EditorTab) {
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesMessage
            alert.addButton(withTitle: Strings.dialogSave)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                guard tabManager.saveTab(at: index) else { return }
                Task { await workspace.gitProvider.refreshAsync() }
                tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                tabManager.closeTab(id: tab.id)
            default:
                return
            }
        } else {
            tabManager.closeTab(id: tab.id)
        }
    }

    // MARK: - Change navigation

    private enum ChangeDirection { case next, previous }

    private func navigateToChange(direction: ChangeDirection) {
        guard let tab = tabManager.activeTab, !lineDiffs.isEmpty else { return }
        let currentLine = ContentView.lineNumber(forOffset: tab.cursorPosition, in: tab.content)
        let starts = GitLineDiff.changeRegionStarts(lineDiffs)
        let targetLine: Int?
        switch direction {
        case .next:
            targetLine = GitLineDiff.nextChangeLine(from: currentLine, regionStarts: starts, diffs: lineDiffs)
        case .previous:
            targetLine = GitLineDiff.previousChangeLine(from: currentLine, regionStarts: starts, diffs: lineDiffs)
        }
        if let line = targetLine {
            goToLineOffset = GoToRequest(offset: ContentView.cursorOffset(forLine: line, in: tab.content))
        }
    }
}

// MARK: - PaneTerminalPlaceholder

/// Placeholder for terminal panes (Phase 3).
struct PaneTerminalPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label(Strings.paneTerminalTitle, systemImage: "terminal")
        } description: {
            Text(Strings.paneTerminalDescription)
        }
    }
}

// MARK: - PaneSplitView

/// Splits space between two child `PaneNode`s with a draggable divider.
///
/// Uses `GeometryReader` instead of `HSplitView`/`VSplitView` for precise
/// control over the split ratio and divider appearance.
struct PaneSplitView: View {
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode
    let ratio: CGFloat

    /// Visible divider thickness in points.
    static let dividerThickness: CGFloat = 1

    /// Hit-test area for the divider drag gesture.
    static let dividerHitArea: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let totalSize = axis == .horizontal ? geo.size.width : geo.size.height
            let divider = Self.dividerThickness
            let firstSize = max(0, totalSize * ratio - divider / 2)
            let secondSize = max(0, totalSize * (1 - ratio) - divider / 2)
            let firstLeafID = first.firstLeafID ?? PaneID()
            let secondLeafID = second.firstLeafID ?? PaneID()

            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(width: firstSize)
                    PaneDividerView(
                        axis: axis, totalSize: totalSize, ratio: ratio,
                        firstChildLeafID: firstLeafID, secondChildLeafID: secondLeafID
                    )
                    PaneTreeView(node: second)
                        .frame(width: secondSize)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(height: firstSize)
                    PaneDividerView(
                        axis: axis, totalSize: totalSize, ratio: ratio,
                        firstChildLeafID: firstLeafID, secondChildLeafID: secondLeafID
                    )
                    PaneTreeView(node: second)
                        .frame(height: secondSize)
                }
            }
        }
    }
}

// MARK: - PaneDividerView

/// A draggable resize divider between two panes.
///
/// The divider has a 4pt hit area for easy grabbing but renders as a
/// subtle 1pt line matching Xcode's split divider style.
struct PaneDividerView: View {
    let axis: SplitAxis
    let totalSize: CGFloat
    let ratio: CGFloat
    /// Unique identity for this split node, derived from child leaf IDs.
    /// Used instead of float comparison to find the correct split in the tree.
    let firstChildLeafID: PaneID
    let secondChildLeafID: PaneID

    @Environment(PaneManager.self) private var paneManager
    @State private var isHovered = false
    @State private var isDragging = false
    /// Captures the ratio at drag start so that incremental translation
    /// is computed relative to the initial position, not the last frame.
    @State private var dragStartRatio: CGFloat?

    var body: some View {
        let isVerticalDivider = axis == .horizontal

        Rectangle()
            .fill(dividerColor)
            .frame(
                width: isVerticalDivider ? PaneSplitView.dividerThickness : nil,
                height: isVerticalDivider ? nil : PaneSplitView.dividerThickness
            )
            .contentShape(
                Rectangle()
                    .size(
                        width: isVerticalDivider ? PaneSplitView.dividerHitArea : .infinity,
                        height: isVerticalDivider ? .infinity : PaneSplitView.dividerHitArea
                    )
                    .offset(
                        x: isVerticalDivider ? -PaneSplitView.dividerHitArea / 2 : 0,
                        y: isVerticalDivider ? 0 : -PaneSplitView.dividerHitArea / 2
                    )
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        if dragStartRatio == nil {
                            dragStartRatio = ratio
                        }
                        let delta = isVerticalDivider ? value.translation.width : value.translation.height
                        let newRatio = (dragStartRatio ?? ratio) + delta / totalSize
                        let clamped = min(max(newRatio, 0.1), 0.9)
                        updateRatio(clamped)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartRatio = nil
                    }
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    if isVerticalDivider {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityIdentifier(AccessibilityID.paneDivider)
    }

    private var dividerColor: Color {
        if isDragging {
            return Color.accentColor.opacity(0.5)
        }
        return Color.primary.opacity(isHovered ? 0.3 : 0.15)
    }

    /// Finds the split node by its child leaf IDs and updates its ratio.
    ///
    /// Uses the first leaf ID of each child subtree as a unique key,
    /// avoiding fragile float comparison that breaks with duplicate ratios.
    private func updateRatio(_ newRatio: CGFloat) {
        if let updated = updateSplitRatio(
            in: paneManager.rootNode,
            firstChildLeafID: firstChildLeafID,
            secondChildLeafID: secondChildLeafID,
            newRatio: newRatio
        ) {
            paneManager.rootNode = updated
        }
    }

    /// Recursively finds the split whose children contain the given leaf IDs and updates its ratio.
    private func updateSplitRatio(
        in node: PaneNode,
        firstChildLeafID: PaneID,
        secondChildLeafID: PaneID,
        newRatio: CGFloat
    ) -> PaneNode? {
        switch node {
        case .leaf:
            return nil
        case .split(let ax, let first, let second, let currentRatio):
            // Check if this split's children match by their first leaf IDs
            if first.firstLeafID == firstChildLeafID && second.firstLeafID == secondChildLeafID {
                return .split(ax, first: first, second: second, ratio: newRatio)
            }
            if let newFirst = updateSplitRatio(
                in: first, firstChildLeafID: firstChildLeafID,
                secondChildLeafID: secondChildLeafID, newRatio: newRatio
            ) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = updateSplitRatio(
                in: second, firstChildLeafID: firstChildLeafID,
                secondChildLeafID: secondChildLeafID, newRatio: newRatio
            ) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }
}
