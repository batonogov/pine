//
//  DiffPanelProvider.swift
//  Pine
//
//  Manages the state of the git diff panel: file lists, staging operations.
//

import Foundation

@Observable
final class DiffPanelProvider {
    private(set) var stagedEntries: [DiffFileEntry] = []
    private(set) var unstagedEntries: [DiffFileEntry] = []
    private(set) var isLoading = false

    /// Currently expanded file path in the panel.
    var expandedFilePath: String?

    /// Refreshes both staged and unstaged file lists with their hunks.
    func refresh(gitProvider: GitStatusProvider) async {
        await MainActor.run { isLoading = true }

        let (stagedResult, unstagedResult, splitResult) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let staged = gitProvider.stagedDiff()
                let unstaged = gitProvider.unstagedDiff()
                let split = gitProvider.splitStatuses()
                continuation.resume(returning: (staged, unstaged, split))
            }
        }

        guard !Task.isCancelled else { return }

        let stagedFiles = buildEntries(
            diffs: stagedResult,
            statuses: splitResult.staged,
            isStaged: true
        )
        let unstagedFiles = buildEntries(
            diffs: unstagedResult,
            statuses: splitResult.unstaged,
            isStaged: false
        )

        await MainActor.run {
            self.stagedEntries = stagedFiles
            self.unstagedEntries = unstagedFiles
            self.isLoading = false
        }
    }

    /// Stages a hunk and refreshes.
    func stageHunk(_ hunk: DiffHunk, filePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.stageHunk(hunk, filePath: filePath))
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    /// Unstages a hunk and refreshes.
    func unstageHunk(_ hunk: DiffHunk, filePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.unstageHunk(hunk, filePath: filePath))
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    /// Discards an unstaged hunk (irreversible!) and refreshes.
    func discardHunk(_ hunk: DiffHunk, filePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.discardHunk(hunk, filePath: filePath))
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
            NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
        }
    }

    /// Stages all changes in a file and refreshes.
    func stageFile(_ relativePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.stageFile(relativePath))
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    /// Unstages all changes in a file and refreshes.
    func unstageFile(_ relativePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.unstageFile(relativePath))
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    /// Stages all files.
    func stageAll(gitProvider: GitStatusProvider) async {
        guard let url = gitProvider.repositoryURL else { return }
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.runGit(["add", "-A"], at: url)
                continuation.resume(returning: result.exitCode == 0)
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    /// Unstages all files.
    func unstageAll(gitProvider: GitStatusProvider) async {
        guard let url = gitProvider.repositoryURL else { return }
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.runGit(["reset", "HEAD"], at: url)
                continuation.resume(returning: result.exitCode == 0)
            }
        }
        if success {
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
        }
    }

    // MARK: - Private

    private func buildEntries(
        diffs: [String: [DiffHunk]],
        statuses: [String: GitFileStatus],
        isStaged: Bool
    ) -> [DiffFileEntry] {
        var entries: [DiffFileEntry] = []

        // Files that have diffs
        for (path, hunks) in diffs.sorted(by: { $0.key < $1.key }) {
            let status = statuses[path] ?? .modified
            entries.append(DiffFileEntry(
                relativePath: path,
                status: status,
                hunks: hunks,
                isStaged: isStaged
            ))
        }

        // Files with status but no diff (e.g., untracked, deleted)
        for (path, status) in statuses.sorted(by: { $0.key < $1.key }) where diffs[path] == nil {
            entries.append(DiffFileEntry(
                relativePath: path,
                status: status,
                hunks: [],
                isStaged: isStaged
            ))
        }

        return entries
    }
}
