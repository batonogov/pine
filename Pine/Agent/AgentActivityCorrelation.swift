//
//  AgentActivityCorrelation.swift
//  Pine
//

import CryptoKit
import Darwin
import Foundation

/// Content identity, not size/mtime: same-sized writes with restored timestamps
/// must still differ. All opens, metadata reads, and streaming hashing stay off
/// the main actor. Non-regular files and symlinks are deliberately not followed.
nonisolated enum AgentActivityFingerprint {
    static func snapshot(rootURL: URL, paths: [String]) async -> [String: Data] {
        await runOnBackground {
            precondition(!Thread.isMainThread)
            var result: [String: Data] = [:]
            for path in paths {
                if let digest = digest(at: rootURL.appendingPathComponent(path)) {
                    result[path] = digest
                }
            }
            return result
        }
    }

    private static func digest(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else { return nil }
        do {
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
            return Data(hash.finalize())
        } catch {
            return nil
        }
    }
}

/// One worker plus one latest pending request bounds refresh storms. Sequence
/// fencing discards superseded work; both requests and the accepted baseline
/// belong to an exact root/session-ID set, never whichever session finishes last.
@MainActor
final class AgentActivityCorrelation {
    typealias Fingerprinter = @Sendable (URL, [String]) async -> [String: Data]

    private struct Identity: Equatable {
        let rootURL: URL
        let sessionIDs: Set<UUID>
    }

    private struct Baseline {
        let unavailableSeedPaths: Set<String>
        let fingerprints: [String: Data]
    }

    private struct Request {
        let sequence: UInt64
        let identity: Identity
        let paths: [String]
        let sessions: [AgentSession]
    }

    private let store: AgentActivityStore
    private let currentSessionIDs: () -> Set<UUID>
    private let fingerprint: Fingerprinter
    private var sequence: UInt64 = 0
    private var identity: Identity?
    private var baseline: Baseline?
    private var pending: Request?
    private var worker: Task<Void, Never>?

    init(
        store: AgentActivityStore,
        currentSessionIDs: @escaping () -> Set<UUID>,
        fingerprint: @escaping Fingerprinter = { root, paths in
            await AgentActivityFingerprint.snapshot(rootURL: root, paths: paths)
        }
    ) {
        self.store = store
        self.currentSessionIDs = currentSessionIDs
        self.fingerprint = fingerprint
    }

    @discardableResult
    func submit(rootURL: URL, paths: [String], sessions: [AgentSession]) -> Task<Void, Never>? {
        sequence += 1
        let live = sessions.filter { $0.state != .done && $0.liveness == .live }
        let nextIdentity = Identity(rootURL: rootURL, sessionIDs: Set(live.map(\.id)))
        if identity != nextIdentity {
            identity = nextIdentity
            baseline = nil
        }
        guard !live.isEmpty else {
            baseline = nil
            pending = nil
            return worker
        }
        pending = Request(
            sequence: sequence,
            identity: nextIdentity,
            paths: Array(Set(paths)).sorted(),
            sessions: live
        )
        if worker == nil {
            worker = Task { await self.drain() }
        }
        return worker
    }

    func waitUntilIdle() async {
        await worker?.value
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            let result = await fingerprint(request.identity.rootURL, request.paths)
            let current = currentSessionIDs()
            // Even a stale worker must invalidate an old seed when ownership
            // changed without a refresh. Do not clear the newest pending request:
            // it may already belong to the new owner and must seed cleanly.
            if identity?.sessionIDs != current {
                baseline = nil
            }
            guard request.sequence == sequence,
                  request.identity == identity,
                  request.identity.sessionIDs == current else { continue }
            if let baseline {
                for path in request.paths {
                    guard let digest = result[path] else { continue }
                    if let previous = baseline.fingerprints[path] {
                        guard previous != digest else { continue }
                    } else {
                        // A path present in an unavailable seed has no known
                        // content yet; its first readable snapshot only seeds.
                        guard !baseline.unavailableSeedPaths.contains(path) else { continue }
                    }
                    store.noteFileSystemChange(
                        at: request.identity.rootURL.appendingPathComponent(path),
                        activeSessions: request.sessions,
                        contentChanged: true
                    )
                }
            }
            // A failed read is uncertainty, not deletion or a content change.
            // Keep known digests only while their path remains in the dirty set.
            var accepted = result
            for path in request.paths where accepted[path] == nil {
                accepted[path] = baseline?.fingerprints[path]
            }
            let unavailableSeedPaths: Set<String>
            if let baseline {
                unavailableSeedPaths = baseline.unavailableSeedPaths
                    .intersection(request.paths)
                    .subtracting(result.keys)
            } else {
                unavailableSeedPaths = Set(request.paths).subtracting(result.keys)
            }
            baseline = Baseline(
                unavailableSeedPaths: unavailableSeedPaths,
                fingerprints: accepted
            )
        }
        worker = nil
    }
}
