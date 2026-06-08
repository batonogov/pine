//
//  GitStatusProvider.swift
//  Pine
//
//  Created by Claude on 10.03.2026.
//

import Foundation

// MARK: - GitStatusProvider

@MainActor
@Observable
final class GitStatusProvider {
    var currentBranch: String = ""
    var fileStatuses: [String: GitFileStatus] = [:]
    var ignoredPaths: Set<String> = []
    var isGitRepository: Bool = false
    var branches: [String] = []

    var repositoryURL: URL?
    var gitRootPath: String?
    /// Shared progress tracker -- set by ProjectManager after init.
    weak var progressTracker: ProgressTracker?

    /// True when the working tree has any uncommitted changes (modified, staged, untracked, etc.).
    var hasUncommittedChanges: Bool { !fileStatuses.isEmpty }

    // MARK: - Refresh Coalescing (issue #738)

    private var inFlightRefreshTask: Task<Void, Never>?
    private var pendingRefreshCount: Int = 0

    /// Test hook: increments every time `applyFetchedResults` actually writes
    /// at least one observable property.
    private(set) var observableUpdateCount: Int = 0

    // MARK: - Setup & Refresh

    func setup(repositoryURL: URL) {
        self.repositoryURL = repositoryURL
        let result = Self.runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
        let detected = result.exitCode == 0
        if detected {
            gitRootPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let fetched = Self.fetchAllInParallel(at: repositoryURL)
            applyFetchedResults(fetched, isRepository: true)
        } else {
            applyEmptyState()
        }
    }

    func refresh() {
        guard isGitRepository, let url = repositoryURL else { return }
        applyFetchedResults(Self.fetchAllInParallel(at: url), isRepository: true)
    }

    /// Atomically applies pre-fetched git results to observable properties.
    ///
    /// Critical: each property is checked for equality before assignment so
    /// `@Observable` does not emit a change event when nothing actually
    /// changed. This is the core of the anti-flicker fix (issue #738).
    private func applyFetchedResults(
        _ result: (branch: String, statuses: [String: GitFileStatus], ignored: Set<String>, branches: [String]),
        isRepository: Bool
    ) {
        var changed = false
        if currentBranch != result.branch {
            currentBranch = result.branch
            changed = true
        }
        if fileStatuses != result.statuses {
            fileStatuses = result.statuses
            changed = true
        }
        if ignoredPaths != result.ignored {
            ignoredPaths = result.ignored
            changed = true
        }
        if branches != result.branches {
            branches = result.branches
            changed = true
        }
        if isGitRepository != isRepository {
            isGitRepository = isRepository
            changed = true
        }
        if changed { observableUpdateCount &+= 1 }
    }

    /// Resets all observable git state to the empty/non-repository values.
    func applyEmptyState() {
        applyFetchedResults((branch: "", statuses: [:], ignored: [], branches: []), isRepository: false)
    }

    /// Public atomic apply used by `WorkspaceManager` after a background
    /// fetch (so observers see one consistent state, not five staggered
    /// individual property updates). Issue #738.
    func applyFetched(
        branch: String,
        statuses: [String: GitFileStatus],
        ignored: Set<String>,
        branches: [String],
        isRepository: Bool
    ) {
        applyFetchedResults(
            (branch: branch, statuses: statuses, ignored: ignored, branches: branches),
            isRepository: isRepository
        )
    }

    /// Async version of setup -- runs git detection and initial refresh
    /// on a background thread using parallel DispatchGroup.
    func setupAsync(repositoryURL: URL) async {
        // nonisolated-check:ignore -- closure body only calls nonisolated static helpers; tracked in #720
        let (isRepo, rootPath, branch, statuses, ignored, branchList) = await runOnBackground {
            let result = GitCommand.run(["rev-parse", "--show-toplevel"], at: repositoryURL)
            let isRepo = result.exitCode == 0
            guard isRepo else {
                return (false, nil as String?, "", [:] as [String: GitFileStatus], Set<String>(), [String]())
            }
            let rootPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let fetched = GitFetcher.fetchAllInParallel(at: repositoryURL)
            return (true, rootPath, fetched.branch, fetched.statuses, fetched.ignored, fetched.branches)
        }

        // Assign root path before fetching so observers see a consistent (root, statuses) pair
        self.repositoryURL = repositoryURL
        self.gitRootPath = rootPath
        applyFetchedResults(
            (branch: branch, statuses: statuses, ignored: ignored, branches: branchList),
            isRepository: isRepo
        )
    }

    // MARK: - Static Fetch Methods (Facade delegates to GitFetcher)

    nonisolated static func fetchAllInParallel(
        at url: URL
    ) -> (branch: String, statuses: [String: GitFileStatus], ignored: Set<String>, branches: [String]) {
        GitFetcher.fetchAllInParallel(at: url)
    }

    nonisolated static func fetchBranch(at url: URL) -> String {
        GitFetcher.fetchBranch(at: url)
    }

    nonisolated static func fetchStatusAndIgnored(
        at url: URL
    ) -> (statuses: [String: GitFileStatus], ignored: Set<String>) {
        GitFetcher.fetchStatusAndIgnored(at: url)
    }

    nonisolated static func fetchBranches(at url: URL) -> [String] {
        GitFetcher.fetchBranches(at: url)
    }

    // MARK: - Async Refresh

    /// Coalesces concurrent callers (issue #738): if a refresh is already
    /// running, additional callers wait for the current pass and trigger at
    /// most one follow-up.
    func refreshAsync() async {
        guard isGitRepository, repositoryURL != nil else { return }

        if let existing = inFlightRefreshTask {
            pendingRefreshCount = min(pendingRefreshCount + 1, 1)
            await existing.value
            if let next = inFlightRefreshTask {
                await next.value
            }
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runRefreshLoop()
        }
        inFlightRefreshTask = task
        await task.value
    }

    private func runRefreshLoop() async {
        defer { inFlightRefreshTask = nil }
        repeat {
            pendingRefreshCount = 0
            await runSingleRefresh()
        } while pendingRefreshCount > 0
    }

    private func runSingleRefresh() async {
        guard isGitRepository, let url = repositoryURL else { return }
        let progressID = progressTracker?.beginOperation(Strings.progressGitStatus)
        defer {
            if let progressID { self.progressTracker?.endOperation(progressID) }
        }

        // nonisolated-check:ignore -- closure body only calls nonisolated static helpers; tracked in #720
        let fetched = await runOnBackground {
            GitFetcher.fetchAllInParallel(at: url)
        }

        // Repository may have been torn down (e.g. .git deleted on the fly) —
        // detect by checking if previously-present data suddenly vanished.
        let looksUnreachable = fetched.branch.isEmpty
            && fetched.statuses.isEmpty
            && fetched.branches.isEmpty
            && (!self.currentBranch.isEmpty || !self.branches.isEmpty)
        if looksUnreachable {
            let stillRepo = Self.runGit(["rev-parse", "--show-toplevel"], at: url).exitCode == 0
            if !stillRepo {
                applyEmptyState()
            }
            return
        }

        applyFetchedResults(fetched, isRepository: true)
    }

    // MARK: - Status Queries

    func statusForFile(at url: URL) -> GitFileStatus? {
        guard let path = relativePath(for: url) else { return nil }
        if let status = fileStatuses[path] { return status }
        // git status --porcelain reports untracked directories as a single entry
        // with a trailing slash, so individual files inside need a prefix check.
        if isInsideUntrackedDirectory(path) { return .untracked }
        return nil
    }

    func isIgnored(at url: URL) -> Bool {
        guard let path = relativePath(for: url) else { return false }
        return isPathIgnored(path)
    }

    private func isPathIgnored(_ path: String) -> Bool {
        if ignoredPaths.contains(path) { return true }
        // Walk up parent directories — O(depth) instead of O(ignoredPaths.count)
        var components = path.components(separatedBy: "/")
        while components.count > 1 {
            components.removeLast()
            if ignoredPaths.contains(components.joined(separator: "/")) { return true }
        }
        return false
    }

    func statusForDirectory(at url: URL) -> GitFileStatus? {
        guard let dirPath = relativePath(for: url) else { return nil }
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"

        var hasModified = false
        var hasStaged = false
        var hasUntracked = false
        var hasConflict = false

        for (path, status) in fileStatuses {
            guard path.hasPrefix(prefix) else { continue }
            switch status {
            case .conflict:           hasConflict = true
            case .modified, .mixed:   hasModified = true
            case .staged, .added:     hasStaged = true
            case .untracked:          hasUntracked = true
            case .deleted:            hasModified = true
            }
        }

        if hasConflict { return .conflict }
        if hasModified { return .modified }
        if hasStaged { return .staged }
        if hasUntracked { return .untracked }
        if isInsideUntrackedDirectory(prefix) { return .untracked }
        return nil
    }

    // MARK: - Diff for Gutter

    func diffForFile(at url: URL) -> [GitLineDiff] {
        guard isGitRepository, let repoURL = repositoryURL else { return [] }
        let headCheck = Self.runGit(["rev-parse", "HEAD"], at: repoURL)
        guard headCheck.exitCode == 0 else { return [] }

        let result = Self.runGit(["diff", "HEAD", "--unified=0", "--", url.path], at: repoURL)
        guard result.exitCode == 0, !result.output.isEmpty else { return [] }
        return GitParser.parseDiff(result.output)
    }

    func diffForFileAsync(at url: URL) async -> [GitLineDiff] {
        guard isGitRepository, let repoURL = repositoryURL else { return [] }
        let filePath = url.path

        // nonisolated-check:ignore -- closure body only calls nonisolated static helpers; tracked in #720
        return await runOnBackground {
            let headCheck = GitCommand.run(["rev-parse", "HEAD"], at: repoURL)
            guard headCheck.exitCode == 0 else { return [] }
            let result = GitCommand.run(
                ["diff", "HEAD", "--unified=0", "--", filePath],
                at: repoURL
            )
            guard result.exitCode == 0, !result.output.isEmpty else { return [] }
            return GitParser.parseDiff(result.output)
        }
    }

    // MARK: - Private Helpers

    private func isInsideUntrackedDirectory(_ path: String) -> Bool {
        for (key, status) in fileStatuses where status == .untracked && key.hasSuffix("/") {
            if path.hasPrefix(key) { return true }
        }
        return false
    }

    private func relativePath(for url: URL) -> String? {
        guard let rootPath = gitRootPath else { return nil }
        let filePath = url.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    // MARK: - Parser & Command Facade (backwards compatibility)

    nonisolated static func unquoteGitPath(_ path: String) -> String {
        GitParser.unquoteGitPath(path)
    }

    nonisolated static func parseStatusOutput(_ output: String) -> [String: GitFileStatus] {
        GitParser.parseStatusOutput(output)
    }

    nonisolated static func parseIgnoredOutput(_ output: String) -> Set<String> {
        GitParser.parseIgnoredOutput(output)
    }

    nonisolated static func parseBlame(_ output: String) -> [GitBlameLine] {
        GitParser.parseBlame(output)
    }

    nonisolated static func parseDiff(_ diffOutput: String) -> [GitLineDiff] {
        GitParser.parseDiff(diffOutput)
    }

    nonisolated static func parseHunkNewStart(_ header: String) -> Int? {
        GitParser.parseHunkNewStart(header)
    }

    nonisolated static let defaultGitTimeout: TimeInterval = GitCommand.defaultTimeout

    nonisolated static func runGit(
        _ arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultGitTimeout
    ) -> (output: String, errorOutput: String, exitCode: Int32) {
        let result = GitCommand.run(arguments, at: directory, timeout: timeout)
        return (result.output, result.errorOutput, result.exitCode)
    }
}
