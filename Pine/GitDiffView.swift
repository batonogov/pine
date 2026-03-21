//
//  GitDiffView.swift
//  Pine
//
//  A panel for reviewing staged and unstaged changes, with hunk-level stage/unstage/discard.
//

import SwiftUI

// MARK: - GitDiffView

struct GitDiffView: View {
    @Environment(\.dismiss) private var dismiss
    var gitProvider: GitStatusProvider

    @State private var stagedFiles: [GitFileDiff] = []
    @State private var unstagedFiles: [GitFileDiff] = []
    @State private var selectedFile: GitFileDiff?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            HSplitView {
                fileListPanel
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                diffContentPanel
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            .frame(minWidth: 680, minHeight: 480)
            .navigationTitle(Strings.diffPanelTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(Strings.diffPanelRefresh)
                    .disabled(isLoading)
                    .accessibilityIdentifier(AccessibilityID.diffPanelRefreshButton)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.dialogDone) { dismiss() }
                }
            }
        }
        .task { await reload() }
    }

    // MARK: - File List

    @ViewBuilder
    private var fileListPanel: some View {
        List(selection: Binding(
            get: { selectedFile?.id },
            set: { id in
                selectedFile = stagedFiles.first(where: { $0.id == id })
                    ?? unstagedFiles.first(where: { $0.id == id })
            }
        )) {
            if !stagedFiles.isEmpty {
                Section(Strings.diffStagedSection) {
                    ForEach(stagedFiles) { file in
                        DiffFileRow(file: file)
                            .tag(file.id)
                            .accessibilityIdentifier(
                                AccessibilityID.diffFileRow(file.filePath, staged: true)
                            )
                    }
                }
            }

            if !unstagedFiles.isEmpty {
                Section(Strings.diffUnstagedSection) {
                    ForEach(unstagedFiles) { file in
                        DiffFileRow(file: file)
                            .tag(file.id)
                            .accessibilityIdentifier(
                                AccessibilityID.diffFileRow(file.filePath, staged: false)
                            )
                    }
                }
            }

            if stagedFiles.isEmpty && unstagedFiles.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label(Strings.diffNoChanges, systemImage: "checkmark.seal")
                } description: {
                    Text(Strings.diffNoChangesMessage)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier(AccessibilityID.diffFileList)
    }

    // MARK: - Diff Content

    @ViewBuilder
    private var diffContentPanel: some View {
        if let file = selectedFile {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(file.hunks) { hunk in
                        DiffHunkView(
                            hunk: hunk,
                            isStaged: file.isStaged,
                            onStage: { stageHunk(hunk, file: file) },
                            onUnstage: { unstageHunk(hunk, file: file) },
                            onDiscard: { discardHunk(hunk, file: file) }
                        )
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView {
                Label(Strings.diffSelectFile, systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(Strings.diffSelectFileMessage)
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        errorMessage = nil
        let (staged, unstaged) = await gitProvider.allChangedFileDiffs()
        stagedFiles = staged
        unstagedFiles = unstaged
        // Re-select the same file if it still exists
        if let sel = selectedFile {
            selectedFile = staged.first(where: { $0.filePath == sel.filePath && $0.isStaged == sel.isStaged })
                ?? unstaged.first(where: { $0.filePath == sel.filePath && $0.isStaged == sel.isStaged })
        }
        // Auto-select first file if nothing is selected
        if selectedFile == nil {
            selectedFile = staged.first ?? unstaged.first
        }
        isLoading = false
    }

    private func stageHunk(_ hunk: GitDiffHunk, file: GitFileDiff) {
        let result = gitProvider.stageHunk(hunk)
        if !result.success {
            errorMessage = result.error
        }
        Task { await reload() }
    }

    private func unstageHunk(_ hunk: GitDiffHunk, file: GitFileDiff) {
        let result = gitProvider.unstageHunk(hunk)
        if !result.success {
            errorMessage = result.error
        }
        Task { await reload() }
    }

    private func discardHunk(_ hunk: GitDiffHunk, file: GitFileDiff) {
        guard confirmDiscard() else { return }
        let result = gitProvider.discardHunk(hunk)
        if !result.success {
            errorMessage = result.error
        }
        Task { await reload() }
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = Strings.diffDiscardTitle
        alert.informativeText = Strings.diffDiscardMessage
        alert.addButton(withTitle: Strings.diffDiscardConfirm)
        alert.addButton(withTitle: Strings.dialogCancel)
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - DiffFileRow

private struct DiffFileRow: View {
    let file: GitFileDiff

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(file.status.color)
                .frame(width: 8, height: 8)
            Text(file.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - DiffHunkView

private struct DiffHunkView: View {
    let hunk: GitDiffHunk
    let isStaged: Bool
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header bar
            HStack {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isStaged {
                    Button(action: onUnstage) {
                        Label(Strings.diffUnstage, systemImage: "minus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier(AccessibilityID.diffUnstageButton)
                } else {
                    Button(action: onStage) {
                        Label(Strings.diffStage, systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier(AccessibilityID.diffStageButton)

                    Button(action: onDiscard) {
                        Label(Strings.diffDiscard, systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.mini)
                    .accessibilityIdentifier(AccessibilityID.diffDiscardButton)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            // Diff lines
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityIdentifier(AccessibilityID.diffHunk)
    }
}

// MARK: - DiffLineView

private struct DiffLineView: View {
    let line: GitDiffLine

    var body: some View {
        HStack(spacing: 0) {
            // Line numbers
            Group {
                lineNumber(line.oldLineNumber)
                lineNumber(line.newLineNumber)
            }

            // Prefix character (+/-/space)
            Text(prefixChar)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .frame(width: 16)

            // Content
            Text(line.content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .background(backgroundColor)
    }

    private func lineNumber(_ n: Int?) -> some View {
        Text(n.map { "\($0)" } ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var prefixChar: String {
        switch line.kind {
        case .context: return " "
        case .added:   return "+"
        case .deleted: return "-"
        }
    }

    private var foregroundColor: Color {
        switch line.kind {
        case .context: return .primary
        case .added:   return Color(nsColor: .systemGreen)
        case .deleted: return Color(nsColor: .systemRed)
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context: return .clear
        case .added:   return Color(nsColor: .systemGreen).opacity(0.12)
        case .deleted: return Color(nsColor: .systemRed).opacity(0.12)
        }
    }
}
