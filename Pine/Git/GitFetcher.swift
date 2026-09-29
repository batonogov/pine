//
//  GitFetcher.swift
//  Pine
//
//  Background-thread git fetch operations using parallel DispatchGroup.
//  Deliberately not @MainActor to avoid Swift 6 strict concurrency issues.
//

import Foundation

/// Namespace for git fetch operations that run on background threads.
/// Deliberately **not** `@MainActor` so closures inside `DispatchQueue.global().async`
/// do not inherit MainActor isolation -- prevents `dispatch_assert_queue_fail`
/// crash under Swift 6 strict concurrency (issue #613).
/// Marked `nonisolated` to opt out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum GitFetcher {

    /// Runs branch, status+ignored, and branch-list fetches in parallel.
    /// Safe to call from any thread (all work happens on background queues).
    /// Each variable is written by exactly one thread; `group.wait()` ensures
    /// happens-before ordering so the reads after wait are safe.
    static func fetchAllInParallel(
        at url: URL
    ) -> (branch: String, statuses: [String: GitFileStatus], ignored: Set<String>, branches: [String]) {
        let group = DispatchGroup()
        // nonisolated(unsafe): each var is written by exactly one dispatch block,
        // and group.wait() provides happens-before guarantee before reads.
        nonisolated(unsafe) var branch = ""
        nonisolated(unsafe) var statuses: [String: GitFileStatus] = [:]
        nonisolated(unsafe) var ignored: Set<String> = []
        nonisolated(unsafe) var branchList: [String] = []

        // Each fetch body runs inside its own autoreleasepool (#1548): raw
        // global-queue work items execute with no pool in place, and git
        // process output plus parsing produce autoreleased Foundation
        // temporaries that would otherwise sit in the worker thread's
        // fallback pool until the thread is torn down. `fetchAllInParallel`
        // is synchronous, so `runOnBackground` (async-only) cannot be used
        // without changing its callers.
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            branch = autoreleasepool { fetchBranch(at: url) }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = autoreleasepool { fetchStatusAndIgnored(at: url) }
            statuses = result.statuses
            ignored = result.ignored
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            branchList = autoreleasepool { fetchBranches(at: url) }
            group.leave()
        }

        // Bounded wait (#1622): each body is deadline-bounded inside
        // GitCommand — including the spawn step — but a body can still fail
        // to *start* when the global queue's worker pool is saturated by
        // other blocked callers on a loaded runner. An unbounded wait would
        // then block the caller forever, and a synchronous caller can be the
        // main thread (the test-only synchronous `GitStatusProvider.setup`
        // path). On timeout return an empty snapshot: callers treat it as
        // "git state unavailable" and degrade one refresh instead of hanging
        // the process. The in-flight bodies keep their captured storage
        // alive, and nothing here reads the partial results, so the early
        // return races nothing.
        guard group.wait(timeout: .now() + Self.fetchTimeout) == .success else {
            return (branch: "", statuses: [:], ignored: [], branches: [])
        }
        return (branch, statuses, ignored, branchList)
    }

    /// Upper bound on one `fetchAllInParallel` wait. Each body runs exactly
    /// one deadline-bounded `GitCommand.run`; the factor covers scheduling
    /// delay on a loaded runner without turning a stuck worker pool into an
    /// unbounded block.
    private static let fetchTimeout: TimeInterval = GitCommand.defaultTimeout * 2

    static func fetchBranch(at url: URL) -> String {
        let result = GitCommand.run(["rev-parse", "--abbrev-ref", "HEAD"], at: url)
        return result.succeeded
            ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    static func fetchStatusAndIgnored(
        at url: URL
    ) -> (statuses: [String: GitFileStatus], ignored: Set<String>) {
        let result = GitCommand.run(
            ["--no-optional-locks", "status", "--ignored", "--porcelain"],
            at: url
        )
        guard result.succeeded else { return ([:], []) }
        return (
            GitParser.parseStatusOutput(result.output),
            GitParser.parseIgnoredOutput(result.output)
        )
    }

    static func fetchBranches(at url: URL) -> [String] {
        let result = GitCommand.run(
            ["branch", "--sort=-committerdate", "--format=%(refname:short)"],
            at: url
        )
        guard result.succeeded else { return [] }
        return result.output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }
}
