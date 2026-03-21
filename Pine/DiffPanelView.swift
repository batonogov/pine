//
//  DiffPanelView.swift
//  Pine
//
//  Git diff panel showing staged/unstaged changes with hunk-level actions.
//

import SwiftUI

struct DiffPanelView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(TabManager.self) var tabManager

    var body: some View {
        let diffPanel = projectManager.diffPanel

        if diffPanel.isLoading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if diffPanel.stagedEntries.isEmpty && diffPanel.unstagedEntries.isEmpty {
            VStack {
                Spacer()
                Text(Strings.diffPanelNoChanges)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            diffList
        }
    }

    private var diffList: some View {
        let diffPanel = projectManager.diffPanel
        let gitProvider = projectManager.gitProvider

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Staged section
                if !diffPanel.stagedEntries.isEmpty {
                    sectionHeader(
                        title: Strings.diffPanelStagedChanges,
                        count: diffPanel.stagedEntries.count,
                        action: {
                            Task { await diffPanel.unstageAll(gitProvider: gitProvider) }
                        },
                        actionIcon: "minus.circle",
                        actionTooltip: Strings.diffPanelUnstageAll
                    )
                    .accessibilityIdentifier(AccessibilityID.diffPanelStagedSection)

                    ForEach(diffPanel.stagedEntries) { entry in
                        DiffFileRowView(
                            entry: entry,
                            isExpanded: diffPanel.expandedFilePath == entry.relativePath,
                            gitProvider: gitProvider,
                            diffPanel: diffPanel,
                            tabManager: tabManager
                        )
                    }
                }

                // Unstaged section
                if !diffPanel.unstagedEntries.isEmpty {
                    sectionHeader(
                        title: Strings.diffPanelUnstagedChanges,
                        count: diffPanel.unstagedEntries.count,
                        action: {
                            Task { await diffPanel.stageAll(gitProvider: gitProvider) }
                        },
                        actionIcon: "plus.circle",
                        actionTooltip: Strings.diffPanelStageAll
                    )
                    .accessibilityIdentifier(AccessibilityID.diffPanelUnstagedSection)

                    ForEach(diffPanel.unstagedEntries) { entry in
                        DiffFileRowView(
                            entry: entry,
                            isExpanded: diffPanel.expandedFilePath == entry.relativePath,
                            gitProvider: gitProvider,
                            diffPanel: diffPanel,
                            tabManager: tabManager
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.diffPanel)
    }

    private func sectionHeader(
        title: LocalizedStringKey,
        count: Int,
        action: @escaping () -> Void,
        actionIcon: String,
        actionTooltip: LocalizedStringKey
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(.quaternary, in: Capsule())

            Button(action: action) {
                Image(systemName: actionIcon)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(actionTooltip)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - File Row

private struct DiffFileRowView: View {
    let entry: DiffFileEntry
    let isExpanded: Bool
    let gitProvider: GitStatusProvider
    let diffPanel: DiffPanelProvider
    let tabManager: TabManager

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader
            if isExpanded {
                ForEach(Array(entry.hunks.enumerated()), id: \.element.id) { index, hunk in
                    DiffHunkView(
                        hunk: hunk,
                        hunkIndex: index,
                        filePath: entry.relativePath,
                        isStaged: entry.isStaged,
                        gitProvider: gitProvider,
                        diffPanel: diffPanel
                    )
                }
            }
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            Image(systemName: FileIconMapper.iconForFile(
                (entry.relativePath as NSString).lastPathComponent
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Text(entry.relativePath)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            statusBadge

            if isHovered {
                fileActions
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onTapGesture {
            if diffPanel.expandedFilePath == entry.relativePath {
                diffPanel.expandedFilePath = nil
            } else {
                diffPanel.expandedFilePath = entry.relativePath
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(AccessibilityID.diffPanelFile(entry.relativePath))
    }

    private var statusBadge: some View {
        Text(statusLetter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(entry.status.color)
    }

    private var statusLetter: String {
        switch entry.status {
        case .modified: "M"
        case .added:    "A"
        case .deleted:  "D"
        case .untracked: "U"
        case .staged:   "S"
        case .conflict: "C"
        case .mixed:    "M"
        }
    }

    @ViewBuilder
    private var fileActions: some View {
        if entry.isStaged {
            Button {
                Task { await diffPanel.unstageFile(entry.relativePath, gitProvider: gitProvider) }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(Strings.diffPanelUnstageFile)
        } else {
            Button {
                Task { await diffPanel.stageFile(entry.relativePath, gitProvider: gitProvider) }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(Strings.diffPanelStageFile)
        }
    }
}

// MARK: - Hunk View

private struct DiffHunkView: View {
    let hunk: DiffHunk
    let hunkIndex: Int
    let filePath: String
    let isStaged: Bool
    let gitProvider: GitStatusProvider
    let diffPanel: DiffPanelProvider

    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeader
            hunkLines
        }
        .accessibilityIdentifier(AccessibilityID.diffPanelHunk(hunkIndex))
        .alert(Strings.diffPanelDiscardConfirmTitle, isPresented: $showDiscardConfirm) {
            Button(Strings.diffPanelDiscardButton, role: .destructive) {
                Task { await diffPanel.discardHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
            }
            Button(Strings.diffPanelCancelButton, role: .cancel) { }
        } message: {
            Text(Strings.diffPanelDiscardConfirmMessage)
        }
    }

    private var hunkHeader: some View {
        HStack(spacing: 4) {
            Text(hunkSummary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if isStaged {
                Button {
                    Task { await diffPanel.unstageHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelUnstageHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelUnstageHunkButton)
            } else {
                Button {
                    Task { await diffPanel.stageHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelStageHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelStageHunkButton)

                Button {
                    showDiscardConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelDiscardHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelDiscardHunkButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03))
    }

    private var hunkSummary: String {
        let added = hunk.lines.filter { $0.kind == .added }.count
        let removed = hunk.lines.filter { $0.kind == .removed }.count
        return "@@ \(hunk.oldStart) +\(added) -\(removed)"
    }

    private var hunkLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                HStack(spacing: 0) {
                    Text(linePrefix(line.kind))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)

                    Text(line.content)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(lineBackground(line.kind))
            }
        }
    }

    private func linePrefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .added:   "+"
        case .removed: "-"
        }
    }

    private func lineBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added:   Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        }
    }
}
