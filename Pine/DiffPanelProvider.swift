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

    /// Currently selected file path shown in the detail view.
    var selectedFilePath: String?

    /// Returns the selected DiffFileEntry from staged or unstaged entries.
    var selectedEntry: DiffFileEntry? {
        guard let path = selectedFilePath else { return nil }
        return stagedEntries.first { $0.relativePath == path }
            ?? unstagedEntries.first { $0.relativePath == path }
    }

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

        let stagedFiles = buildEntries(diffs: stagedResult, statuses: splitResult.staged, isStaged: true)
        let unstagedFiles = buildEntries(diffs: unstagedResult, statuses: splitResult.unstaged, isStaged: false)

        await MainActor.run {
            self.stagedEntries = stagedFiles
            self.unstagedEntries = unstagedFiles
            self.isLoading = false

            if let path = selectedFilePath,
               !stagedFiles.contains(where: { $0.relativePath == path }),
               !unstagedFiles.contains(where: { $0.relativePath == path }) {
                selectedFilePath = nil
            }
        }
    }

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

    func discardFile(_ relativePath: String, gitProvider: GitStatusProvider) async {
        let success = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gitProvider.discardFile(relativePath))
            }
        }
        if success {
            if selectedFilePath == relativePath { selectedFilePath = nil }
            await gitProvider.refreshAsync()
            await refresh(gitProvider: gitProvider)
            NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
        }
    }

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

        for (path, hunks) in diffs.sorted(by: { $0.key < $1.key }) {
            let status = statuses[path] ?? .modified
            entries.append(DiffFileEntry(relativePath: path, status: status, hunks: hunks, isStaged: isStaged))
        }

        for (path, status) in statuses.sorted(by: { $0.key < $1.key }) where diffs[path] == nil {
            entries.append(DiffFileEntry(relativePath: path, status: status, hunks: [], isStaged: isStaged))
        }

        return entries
    }
}
