//
//  DiffPanelView.swift
//  Pine
//
//  Sidebar file list for the git diff panel. Selecting a file shows its diff in the editor area.
//

import SwiftUI

struct DiffPanelView: View {
    @Environment(ProjectManager.self) var projectManager

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
                if !diffPanel.stagedEntries.isEmpty {
                    sectionHeader(
                        title: Strings.diffPanelStagedChanges,
                        count: diffPanel.stagedEntries.count,
                        action: { Task { await diffPanel.unstageAll(gitProvider: gitProvider) } },
                        actionIcon: "minus.circle",
                        actionTooltip: Strings.diffPanelUnstageAll
                    )
                    .accessibilityIdentifier(AccessibilityID.diffPanelStagedSection)

                    ForEach(diffPanel.stagedEntries) { entry in
                        DiffFileRowView(
                            entry: entry,
                            isSelected: diffPanel.selectedFilePath == entry.relativePath,
                            gitProvider: gitProvider,
                            diffPanel: diffPanel
                        )
                    }
                }

                if !diffPanel.unstagedEntries.isEmpty {
                    sectionHeader(
                        title: Strings.diffPanelUnstagedChanges,
                        count: diffPanel.unstagedEntries.count,
                        action: { Task { await diffPanel.stageAll(gitProvider: gitProvider) } },
                        actionIcon: "plus.circle",
                        actionTooltip: Strings.diffPanelStageAll
                    )
                    .accessibilityIdentifier(AccessibilityID.diffPanelUnstagedSection)

                    ForEach(diffPanel.unstagedEntries) { entry in
                        DiffFileRowView(
                            entry: entry,
                            isSelected: diffPanel.selectedFilePath == entry.relativePath,
                            gitProvider: gitProvider,
                            diffPanel: diffPanel
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
    let isSelected: Bool
    let gitProvider: GitStatusProvider
    let diffPanel: DiffPanelProvider

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
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

            Text(statusLetter)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.status.color)

            if isHovered {
                fileActions
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : isHovered ? Color.primary.opacity(0.06) : .clear)
        .onTapGesture { diffPanel.selectedFilePath = entry.relativePath }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(AccessibilityID.diffPanelFile(entry.relativePath))
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
                Image(systemName: "minus.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(Strings.diffPanelUnstageFile)
        } else {
            Button {
                Task { await diffPanel.stageFile(entry.relativePath, gitProvider: gitProvider) }
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(Strings.diffPanelStageFile)
        }
    }
}
