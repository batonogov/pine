//
//  CommitView.swift
//  Pine
//
//  Git commit UI — stage files and create commits without terminal.
//

import SwiftUI

// MARK: - Data Model

/// Represents a file entry in the commit view.
struct CommitFileEntry: Identifiable, Equatable {
    let id: String // relative path
    let path: String
    let status: GitFileStatus
    let isStaged: Bool

    var statusLabel: String {
        switch status {
        case .added: return "A"
        case .modified, .staged: return "M"
        case .deleted: return "D"
        case .untracked: return "?"
        case .conflict: return "C"
        case .mixed: return "M"
        }
    }
}

// MARK: - CommitView

struct CommitView: View {
    var gitProvider: GitStatusProvider
    @Binding var isPresented: Bool

    @State private var commitMessage = ""
    @State private var stagedFiles: [String: GitFileStatus] = [:]
    @State private var unstagedFiles: [String: GitFileStatus] = [:]
    @State private var selectedFilePath: String?
    @State private var diffText = ""
    @State private var errorMessage = ""
    @State private var isCommitting = false
    @State private var showEmptyMessageAlert = false

    private var stagedEntries: [CommitFileEntry] {
        stagedFiles.map { CommitFileEntry(id: "staged-\($0.key)", path: $0.key, status: $0.value, isStaged: true) }
            .sorted { $0.path < $1.path }
    }

    private var unstagedEntries: [CommitFileEntry] {
        unstagedFiles.map { CommitFileEntry(id: "unstaged-\($0.key)", path: $0.key, status: $0.value, isStaged: false) }
            .sorted { $0.path < $1.path }
    }

    private var hasChanges: Bool {
        !stagedFiles.isEmpty || !unstagedFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(Strings.commitTitle)
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.commitCloseButton)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if !hasChanges {
                emptyStateView
            } else {
                HSplitView {
                    fileListView
                        .frame(minWidth: 200, idealWidth: 280)

                    diffPreviewView
                        .frame(minWidth: 200, idealWidth: 320)
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            commitBarView
                .padding(8)

            if !errorMessage.isEmpty {
                Divider()
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(PineAnimation.fadeTransition)
            }
        }
        .frame(width: 640, height: 480)
        .animation(PineAnimation.quick, value: errorMessage.isEmpty)
        .accessibilityIdentifier(AccessibilityID.commitSheet)
        .task {
            await refreshFileList()
        }
        .alert(Strings.commitEmptyMessageTitle, isPresented: $showEmptyMessageAlert) {
            Button(Strings.commitEmptyMessageCancel, role: .cancel) { }
            Button(Strings.commitEmptyMessageConfirm) {
                performCommit()
            }
        } message: {
            Text(Strings.commitEmptyMessageBody)
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(Strings.commitNoChanges)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !stagedEntries.isEmpty {
                    sectionHeader(Strings.commitStagedSection, count: stagedEntries.count) {
                        unstageAll()
                    }

                    ForEach(stagedEntries) { entry in
                        fileRow(entry: entry)
                    }
                }

                if !unstagedEntries.isEmpty {
                    sectionHeader(Strings.commitUnstagedSection, count: unstagedEntries.count) {
                        stageAll()
                    }

                    ForEach(unstagedEntries) { entry in
                        fileRow(entry: entry)
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.commitFileList)
    }

    private func sectionHeader(
        _ title: LocalizedStringKey,
        count: Int,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("(\(count))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                action()
            } label: {
                Image(systemName: title == Strings.commitStagedSection
                      ? "minus.circle" : "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(title == Strings.commitStagedSection
                  ? String(localized: "commit.unstageAll")
                  : String(localized: "commit.stageAll"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5))
    }

    private func fileRow(entry: CommitFileEntry) -> some View {
        Button {
            selectFile(entry)
        } label: {
            HStack(spacing: 6) {
                // Stage/unstage checkbox
                Button {
                    toggleStaging(entry)
                } label: {
                    Image(systemName: entry.isStaged
                          ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.isStaged ? .green : .secondary)
                }
                .buttonStyle(.plain)

                // Status indicator
                Text(entry.statusLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.status.color)
                    .frame(width: 14)

                // File name
                Text(entry.path)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selectedFilePath == entry.path ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(selectedFilePath == entry.path
                        ? Color.accentColor.opacity(0.3)
                        : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.commitFileEntry(entry.path))
    }

    private var diffPreviewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = selectedFilePath {
                HStack {
                    Text(path)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))

                ScrollView([.horizontal, .vertical]) {
                    Text(diffText.isEmpty ? String(localized: "commit.noDiff") : diffText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(diffText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier(AccessibilityID.commitDiffPreview)
            } else {
                VStack {
                    Spacer()
                    Text(Strings.commitSelectFile)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var commitBarView: some View {
        HStack(spacing: 8) {
            TextField(Strings.commitMessagePlaceholder, text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .accessibilityIdentifier(AccessibilityID.commitMessageField)

            Button {
                if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    showEmptyMessageAlert = true
                } else {
                    performCommit()
                }
            } label: {
                Label(Strings.commitButton, systemImage: MenuIcons.commit)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(stagedFiles.isEmpty || isCommitting)
            .accessibilityIdentifier(AccessibilityID.commitButton)
        }
    }

    // MARK: - Actions

    private func refreshFileList() async {
        guard let url = gitProvider.repositoryURL else { return }
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let files = GitStatusProvider.fetchStagedAndUnstaged(at: url)
                continuation.resume(returning: files)
            }
        }
        stagedFiles = result.staged
        unstagedFiles = result.unstaged
    }

    private func selectFile(_ entry: CommitFileEntry) {
        selectedFilePath = entry.path
        loadDiff(for: entry)
    }

    private func loadDiff(for entry: CommitFileEntry) {
        guard let url = gitProvider.repositoryURL else { return }
        let path = entry.path
        let isStaged = entry.isStaged
        Task {
            let diff = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = isStaged
                        ? GitStatusProvider.diffForStagedFile(path, at: url)
                        : GitStatusProvider.diffForCommitFile(path, at: url)
                    continuation.resume(returning: result)
                }
            }
            diffText = diff
        }
    }

    private func toggleStaging(_ entry: CommitFileEntry) {
        guard let url = gitProvider.repositoryURL else { return }
        Task {
            let result: (success: Bool, error: String)
            if entry.isStaged {
                result = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: GitStatusProvider.unstageFile(entry.path, at: url))
                    }
                }
            } else {
                result = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: GitStatusProvider.stageFile(entry.path, at: url))
                    }
                }
            }
            if result.success {
                await refreshFileList()
            } else {
                errorMessage = result.error
            }
        }
    }

    private func stageAll() {
        guard let url = gitProvider.repositoryURL else { return }
        let paths = Array(unstagedFiles.keys)
        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: GitStatusProvider.stageFiles(paths, at: url))
                }
            }
            if result.success {
                await refreshFileList()
            } else {
                errorMessage = result.error
            }
        }
    }

    private func unstageAll() {
        guard let url = gitProvider.repositoryURL else { return }
        let paths = Array(stagedFiles.keys)
        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: GitStatusProvider.unstageFiles(paths, at: url))
                }
            }
            if result.success {
                await refreshFileList()
            } else {
                errorMessage = result.error
            }
        }
    }

    private func performCommit() {
        guard let url = gitProvider.repositoryURL else { return }
        guard !stagedFiles.isEmpty else { return }

        isCommitting = true
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveMessage = message.isEmpty ? "No message" : message

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: GitStatusProvider.commit(message: effectiveMessage, at: url))
                }
            }

            isCommitting = false

            if result.success {
                errorMessage = ""
                commitMessage = ""
                await gitProvider.refreshAsync()
                NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                isPresented = false
            } else {
                errorMessage = result.error
            }
        }
    }
}
