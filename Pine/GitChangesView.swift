//
//  GitChangesView.swift
//  Pine
//
//  Sidebar panel showing staged/unstaged file changes with inline diff preview.
//  Supports stage/unstage/discard operations on individual files.
//

import AppKit
import SwiftUI

// MARK: - Git Changes Sheet

struct GitChangesSheet: View {
    let diffProvider: GitDiffProvider
    @Binding var isPresented: Bool
    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Strings.sidebarGitChanges)
                    .font(.headline)

                Spacer()

                Button {
                    Task {
                        guard let url = projectManager.workspace.rootURL else { return }
                        await diffProvider.refresh(at: url)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(Strings.gitChangesRefresh)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            GitChangesView(diffProvider: diffProvider)
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
    }
}

// MARK: - Git Changes Panel

struct GitChangesView: View {
    @Environment(ProjectManager.self) private var projectManager
    let diffProvider: GitDiffProvider

    var body: some View {
        VStack(spacing: 0) {
            if diffProvider.isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffProvider.stagedFiles.isEmpty && diffProvider.unstagedFiles.isEmpty {
                GitChangesEmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !diffProvider.stagedFiles.isEmpty {
                            GitChangesSectionView(
                                title: Strings.gitChangesStagedTitle,
                                files: diffProvider.stagedFiles,
                                isStagedSection: true,
                                diffProvider: diffProvider
                            )
                        }

                        if !diffProvider.unstagedFiles.isEmpty {
                            GitChangesSectionView(
                                title: Strings.gitChangesUnstagedTitle,
                                files: diffProvider.unstagedFiles,
                                isStagedSection: false,
                                diffProvider: diffProvider
                            )
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.gitChangesPanel)
    }
}

// MARK: - Empty State

struct GitChangesEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label(Strings.gitChangesNoChanges, systemImage: "checkmark.circle")
        } description: {
            Text(Strings.gitChangesNoChangesDescription)
        }
    }
}

// MARK: - Section

struct GitChangesSectionView: View {
    let title: LocalizedStringKey
    let files: [FileDiff]
    let isStagedSection: Bool
    let diffProvider: GitDiffProvider

    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(files.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if isStagedSection {
                    Button {
                        Task {
                            guard let url = projectManager.workspace.rootURL else { return }
                            _ = await diffProvider.unstageAll(at: url)
                            await refreshAll()
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .help(Strings.gitChangesUnstageAll)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task {
                            guard let url = projectManager.workspace.rootURL else { return }
                            _ = await diffProvider.stageAll(at: url)
                            await refreshAll()
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .help(Strings.gitChangesStageAll)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ForEach(files) { file in
                GitChangesFileRow(
                    file: file,
                    isStagedSection: isStagedSection,
                    diffProvider: diffProvider
                )
            }
        }
    }

    private func refreshAll() async {
        guard let url = projectManager.workspace.rootURL else { return }
        await diffProvider.refresh(at: url)
        await projectManager.workspace.gitProvider.refreshAsync()
    }
}

// MARK: - File Row

struct GitChangesFileRow: View {
    let file: FileDiff
    let isStagedSection: Bool
    let diffProvider: GitDiffProvider

    @Environment(ProjectManager.self) private var projectManager
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                changeCountBadge

                actionButtons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                DiffHunkListView(hunks: file.hunks)
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private var changeCountBadge: some View {
        let added = file.hunks.flatMap(\.lines).filter { $0.kind == .added }.count
        let removed = file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count

        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
            if removed > 0 {
                Text("-\(removed)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isStagedSection {
            Button {
                Task {
                    guard let url = projectManager.workspace.rootURL else { return }
                    _ = await diffProvider.unstageFile(file.filePath, at: url)
                    await refreshAll()
                }
            } label: {
                Image(systemName: "minus.circle")
                    .help(Strings.gitChangesUnstage)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 4) {
                Button {
                    confirmDiscard(file: file)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .help(Strings.gitChangesDiscard)
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        guard let url = projectManager.workspace.rootURL else { return }
                        _ = await diffProvider.stageFile(file.filePath, at: url)
                        await refreshAll()
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .help(Strings.gitChangesStage)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func confirmDiscard(file: FileDiff) {
        let alert = NSAlert()
        alert.messageText = Strings.gitChangesDiscardConfirmTitle
        alert.informativeText = Strings.gitChangesDiscardConfirmMessage(
            URL(fileURLWithPath: file.filePath).lastPathComponent
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.gitChangesDiscardConfirmButton)
        alert.addButton(withTitle: Strings.dialogCancel)
        // Make the Discard button destructive
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                guard let url = projectManager.workspace.rootURL else { return }
                _ = await diffProvider.discardChanges(file.filePath, at: url)
                await refreshAll()
            }
        }
    }

    private func refreshAll() async {
        guard let url = projectManager.workspace.rootURL else { return }
        await diffProvider.refresh(at: url)
        await projectManager.workspace.gitProvider.refreshAsync()
    }
}

// MARK: - Diff Hunk List

struct DiffHunkListView: View {
    let hunks: [DiffHunk]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunks) { hunk in
                VStack(alignment: .leading, spacing: 0) {
                    Text(hunk.header)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)

                    ForEach(hunk.lines) { line in
                        DiffLineView(line: line)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Diff Line

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(prefix)
                .font(.caption.monospaced())
                .foregroundStyle(prefixColor)
                .frame(width: 14, alignment: .center)

            Text(line.text)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        case .hunkHeader: return "@"
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        case .hunkHeader: return .blue
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .added: return .green.opacity(0.1)
        case .removed: return .red.opacity(0.1)
        case .context, .hunkHeader: return .clear
        }
    }
}
