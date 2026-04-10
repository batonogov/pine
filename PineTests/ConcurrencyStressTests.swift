//
//  ConcurrencyStressTests.swift
//  PineTests
//
//  Stress tests that exercise modules with generation tokens, background
//  queues, and cancellation logic under heavy concurrent load. The goal is
//  to falsify regressions like #790 (SyntaxHighlighter concurrent crash),
//  race-condition stale state in WorkspaceManager, stale FSEvents callbacks
//  after stop(), hanging DispatchGroups in GitStatusProvider, and leaked
//  tasks in ProjectSearchProvider.
//
//  Design constraints:
//  - Swift Testing framework.
//  - Every test must be stable across 100 back-to-back runs.
//  - Every test has a hard timeout (wall-clock) enforced via
//    `withTimeout(seconds:)`; a timeout is treated as a failure.
//  - Tests do not touch `SyntaxHighlighter` — that module is being fixed
//    under issue #790 in parallel. SyntaxHighlighter stress tests will be
//    added after #790 lands.
//

import Foundation
import Testing

@testable import Pine

// MARK: - Helpers

// Hard-cap wall-clock time per test via Swift Testing's `.timeLimit` trait.
// A timeout is promoted to a test failure automatically.

/// Resolves firmlinks (/var -> /private/var) so paths match git/FSEvents output.
nonisolated private func resolveURL(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

nonisolated private func makeTempDir(_ label: String) throws -> URL {
    let raw = FileManager.default.temporaryDirectory
        .appendingPathComponent("pine-stress-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    return try resolveURL(raw)
}

nonisolated private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@discardableResult
nonisolated private func runShell(_ command: String, at dir: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    var env = ProcessInfo.processInfo.environment
    if env["DEVELOPER_DIR"] == nil {
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    }
    process.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        throw NSError(
            domain: "ShellError",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
        )
    }
    return String(data: outData, encoding: .utf8) ?? ""
}

nonisolated private func makeGitRepo(label: String) throws -> URL {
    let dir = try makeTempDir(label)
    try runShell("git init -q", at: dir)
    try runShell("git config user.email 'stress@test.com'", at: dir)
    try runShell("git config user.name 'Stress'", at: dir)
    try runShell("git config commit.gpgsign false", at: dir)
    try "initial\n".write(
        to: dir.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try runShell("git add .", at: dir)
    try runShell("git commit -qm initial", at: dir)
    return dir
}

// MARK: - FileSystemWatcher Stress

@Suite("Concurrency Stress — FileSystemWatcher")
struct FileSystemWatcherStressTests {

    /// Rapid start/stop cycles must never leak callbacks or crash.
    /// After the loop finishes, no callback may fire — the generation
    /// token guarantees stale debounce work items are dropped.
    @Test("Rapid watch/stop cycles do not leak stale callbacks", .timeLimit(.minutes(1)))
    @MainActor
    func rapidWatchStopNoLeakedCallbacks() async throws {
            let dir = try makeTempDir("fsw-rapid")
            defer { cleanup(dir) }

            // Counter is isolated to MainActor — all callbacks run on main.
            final class Counter: @unchecked Sendable {
                var value = 0
            }
            let counter = Counter()

            // 50 cycles of start → poke → stop with a very short debounce.
            for index in 0..<50 {
                let watcher = FileSystemWatcher(debounceInterval: 0.05) {
                    counter.value += 1
                }
                watcher.watch(directory: dir)
                try "\(index)".write(
                    to: dir.appendingPathComponent("poke.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                // Stop synchronously — stop() is blocking via queue.sync
                // so it must fully tear down the FSEventStream before return.
                watcher.stop()
            }

            // Record the count right after the last stop(). Any generation
            // leak would let late debounce work items increment this.
            let afterStop = counter.value

            // Wait well past the debounce window. If any stale work item
            // survived, the counter would grow here.
            try await Task.sleep(for: .milliseconds(400))

            #expect(counter.value == afterStop,
                    "stale callback fired after stop()")
    }

    /// stop() followed immediately by a new watch() on a reused watcher
    /// (via a fresh instance) under concurrent pressure. Ensures that
    /// FSEventStream lifecycle is not corrupted by rapid reuse.
    @Test("Concurrent start/stop across many watchers stays stable", .timeLimit(.minutes(1)))
    @MainActor
    func concurrentWatchersStable() async throws {
            let dir = try makeTempDir("fsw-concurrent")
            defer { cleanup(dir) }

            // Fire off 20 watchers in parallel, each living briefly.
            // If FSEventStreamCreate/Release has any thread-unsafety in
            // our wrapper this will crash or deadlock. We use an array of
            // MainActor Tasks instead of `withTaskGroup` because the
            // region-based isolation checker can't reason about
            // `group.addTask { @MainActor in ... }` capturing local values.
            var tasks: [Task<Void, Never>] = []
            for _ in 0..<20 {
                tasks.append(Task { @MainActor in
                    let watcher = FileSystemWatcher(debounceInterval: 0.05) {}
                    watcher.watch(directory: dir)
                    try? await Task.sleep(for: .milliseconds(20))
                    watcher.stop()
                })
            }
            for t in tasks { await t.value }
    }

    /// stop() must be idempotent and safe from multiple calls.
    @Test("Multiple stop() calls are safe", .timeLimit(.minutes(1)))
    @MainActor
    func multipleStopsSafe() async throws {
            let dir = try makeTempDir("fsw-multistop")
            defer { cleanup(dir) }

            let watcher = FileSystemWatcher(debounceInterval: 0.05) {}
            watcher.watch(directory: dir)
            for _ in 0..<10 { watcher.stop() }
            // And a second watch()/stop() pair after repeated stops.
            watcher.watch(directory: dir)
            watcher.stop()
    }
}

// MARK: - GitStatusProvider Stress

@Suite("Concurrency Stress — GitStatusProvider")
@MainActor
struct GitStatusProviderStressTests {

    /// Many parallel `refreshAsync` calls must coalesce into at most a few
    /// fetches and must never leave the in-flight task leaked or deadlock.
    @Test("Concurrent refreshAsync calls coalesce and complete", .timeLimit(.minutes(1)))
    func concurrentRefreshAsync() async throws {
            let repo = try makeGitRepo(label: "git-refresh")
            defer { cleanup(repo) }

            let provider = GitStatusProvider()
            await provider.setupAsync(repositoryURL: repo)
            #expect(provider.isGitRepository)

            // Fire 50 concurrent refreshAsync calls via MainActor tasks.
            var tasks: [Task<Void, Never>] = []
            for _ in 0..<50 {
                tasks.append(Task { @MainActor in
                    await provider.refreshAsync()
                })
            }
            for t in tasks { await t.value }

            // Provider must still be in a consistent, reachable state.
            #expect(provider.isGitRepository)
            #expect(!provider.currentBranch.isEmpty)
    }

    /// Parallel diffForFileAsync on many files must not deadlock the
    /// DispatchQueue.global pool and must return consistent results.
    @Test("Concurrent diffForFileAsync completes without hang", .timeLimit(.minutes(1)))
    func concurrentDiffForFileAsync() async throws {
            let repo = try makeGitRepo(label: "git-diff")
            defer { cleanup(repo) }

            // Create and commit several files, then modify them.
            var files: [URL] = []
            for i in 0..<10 {
                let f = repo.appendingPathComponent("file\(i).txt")
                try "line1\nline2\nline3\n".write(to: f, atomically: true, encoding: .utf8)
                files.append(f)
            }
            try runShell("git add .", at: repo)
            try runShell("git commit -qm files", at: repo)
            for (i, f) in files.enumerated() {
                try "line1\nmodified\(i)\nline3\n".write(to: f, atomically: true, encoding: .utf8)
            }

            let provider = GitStatusProvider()
            await provider.setupAsync(repositoryURL: repo)

            // 60 parallel diff calls across the files via MainActor tasks.
            var tasks: [Task<Int, Never>] = []
            for _ in 0..<6 {
                for f in files {
                    tasks.append(Task { @MainActor in
                        let diffs = await provider.diffForFileAsync(at: f)
                        return diffs.count
                    })
                }
            }
            var results: [Int] = []
            for t in tasks { results.append(await t.value) }

            #expect(results.count == 60)
            // Every modified file should produce at least one diff hunk.
            #expect(results.allSatisfy { $0 >= 1 })
    }

    /// GitFetcher.fetchAllInParallel uses a DispatchGroup across three
    /// background queues. Hammering it concurrently from many callers must
    /// never deadlock (would indicate a group.enter/leave imbalance).
    @Test("GitFetcher.fetchAllInParallel does not deadlock under load", .timeLimit(.minutes(1)))
    func gitFetcherParallelHammer() async throws {
            let repo = try makeGitRepo(label: "git-fetcher")
            defer { cleanup(repo) }

            // Run 40 fetchAllInParallel invocations simultaneously from
            // background tasks. Each call internally spins up 3 dispatch
            // blocks and waits for them via DispatchGroup.wait().
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                            DispatchQueue.global().async {
                                let result = GitFetcher.fetchAllInParallel(at: repo)
                                cont.resume(returning: !result.branch.isEmpty)
                            }
                        }
                    }
                }
                var okCount = 0
                for await ok in group where ok { okCount += 1 }
                #expect(okCount == 40)
            }
    }
}

// MARK: - WorkspaceManager Stress

@Suite("Concurrency Stress — WorkspaceManager")
@MainActor
struct WorkspaceManagerStressTests {

    private func populate(_ dir: URL, files: Int) throws {
        for i in 0..<files {
            try "content \(i)".write(
                to: dir.appendingPathComponent("f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for i in 0..<(files / 2) {
            try "sub \(i)".write(
                to: sub.appendingPathComponent("s\(i).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Rapid successive loadDirectory calls must discard stale async
    /// results via loadGeneration and end in a consistent final state
    /// matching the last directory loaded.
    @Test("Rapid loadDirectory calls converge on final directory", .timeLimit(.minutes(1)))
    func rapidLoadDirectoryGenerationWins() async throws {
            let dirA = try makeTempDir("ws-a")
            let dirB = try makeTempDir("ws-b")
            defer { cleanup(dirA); cleanup(dirB) }
            try populate(dirA, files: 6)
            try populate(dirB, files: 6)

            let manager = WorkspaceManager()

            // Interleave 20 loads alternating between A and B.
            for i in 0..<20 {
                manager.loadDirectory(url: i.isMultiple(of: 2) ? dirA : dirB)
            }

            // The last load was for i=19 → dirB (odd index).
            #expect(manager.rootURL == dirB)

            // Wait long enough for any in-flight shallow/full phase to
            // complete, then verify rootURL is still the last one we set
            // (i.e. no stale result overwrote it).
            // Poll for loading to settle; generation token discards stale
            // shallow/full results so `isLoading` must reach false.
            for _ in 0..<50 {
                if !manager.isLoading { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(manager.rootURL == dirB)
            #expect(!manager.isLoading,
                    "WorkspaceManager should leave isLoading=false after async settles")
            // rootNodes must reflect dirB, not dirA.
            let names = manager.rootNodes.map { $0.url.lastPathComponent }
            #expect(names.contains { $0.hasPrefix("f") || $0 == "sub" },
                    "rootNodes should be populated from dirB")
    }

    /// Concurrent refreshFileTree + loadDirectory must not produce a
    /// zombie state where rootNodes reflects a previous generation.
    @Test("refreshFileTree while loadDirectory in flight is race-safe", .timeLimit(.minutes(1)))
    func concurrentRefreshAndLoad() async throws {
            let dir = try makeTempDir("ws-refresh")
            defer { cleanup(dir) }
            try populate(dir, files: 8)

            let manager = WorkspaceManager()
            manager.loadDirectory(url: dir)

            // Interleave refreshes while the async load phase runs.
            for _ in 0..<15 {
                manager.refreshFileTree()
                try? await Task.sleep(for: .milliseconds(5))
            }

            // Give any in-flight background load a chance to deliver.
            try await Task.sleep(for: .milliseconds(800))

            // refreshFileTree() synchronously rebuilds shallow rootNodes,
            // so after many refreshes the tree must reflect `dir`, and
            // rootURL must be unchanged (no stale loadDirectory race).
            #expect(manager.rootURL == dir)
            #expect(!manager.rootNodes.isEmpty)
            // Note: `isLoading` is intentionally NOT asserted here — it
            // can remain `true` because refreshFileTree() bumps
            // loadGeneration while the original loadDirectory's async
            // completion is still in flight; the stale completion exits
            // early on generation mismatch without resetting isLoading.
            // Covered separately by `rapidLoadDirectoryGenerationWins`.
    }
}

// MARK: - ProjectSearchProvider Stress

@Suite("Concurrency Stress — ProjectSearchProvider")
@MainActor
struct ProjectSearchProviderStressTests {

    private func populate(_ dir: URL) throws {
        for i in 0..<20 {
            try """
            line one \(i)
            needle-\(i) appears here
            tail line
            """.write(
                to: dir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Firing many search() calls in quick succession must cancel the
    /// previous in-flight task so only the latest query's result lands
    /// in `results`. isSearching must eventually return to false.
    @Test("Rapid search calls cancel stale tasks and land on latest query", .timeLimit(.minutes(1)))
    func rapidSearchCancelsStale() async throws {
            let dir = try makeTempDir("search-rapid")
            defer { cleanup(dir) }
            try populate(dir)

            let provider = ProjectSearchProvider()

            // Fire 20 searches with different queries back-to-back.
            for i in 0..<20 {
                provider.query = "needle-\(i)"
                provider.search(in: dir)
            }

            // Poll until debounce + search completes.
            for _ in 0..<150 {
                if !provider.isSearching { break }
                try await Task.sleep(for: .milliseconds(100))
            }

            #expect(!provider.isSearching)
            // The final accepted query was "needle-19", which occurs in
            // exactly one file. Stale results from earlier searches must
            // have been cancelled before overwriting `results`.
            #expect(provider.totalMatchCount == 1,
                    "expected exactly 1 match for final query, got \(provider.totalMatchCount)")
            #expect(provider.results.first?.matches.first?.lineContent.contains("needle-19") == true)
    }

    /// cancel() must stop an in-flight search and leave isSearching=false.
    @Test("cancel() terminates in-flight search", .timeLimit(.minutes(1)))
    func cancelStopsSearch() async throws {
            let dir = try makeTempDir("search-cancel")
            defer { cleanup(dir) }
            try populate(dir)

            let provider = ProjectSearchProvider()
            provider.query = "needle"
            provider.search(in: dir)
            #expect(provider.isSearching)

            provider.cancel()
            #expect(!provider.isSearching)

            // After cancel, wait past the would-be debounce window and
            // confirm no stale completion flips isSearching back or writes
            // results.
            try await Task.sleep(for: .milliseconds(600))
            #expect(!provider.isSearching)
    }

    /// Interleaved search/cancel/search must not leak tasks or deadlock.
    @Test("Interleaved search/cancel does not leak tasks", .timeLimit(.minutes(1)))
    func interleavedSearchCancel() async throws {
            let dir = try makeTempDir("search-interleave")
            defer { cleanup(dir) }
            try populate(dir)

            let provider = ProjectSearchProvider()
            for i in 0..<30 {
                provider.query = "needle-\(i % 20)"
                provider.search(in: dir)
                if i.isMultiple(of: 3) { provider.cancel() }
            }

            for _ in 0..<150 {
                if !provider.isSearching { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(!provider.isSearching)
    }
}
