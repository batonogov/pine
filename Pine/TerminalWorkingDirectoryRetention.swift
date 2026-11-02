//
//  TerminalWorkingDirectoryRetention.swift
//  Pine
//

import Foundation
import SwiftTerm

/// A process-generation deletion fence, independent of tab/pane lifetime.
/// Only positive cleanup completion releases it; bounded failure (including
/// deferred cleanup) and loss of the UI/controller reference fail closed.
nonisolated final class TerminalWorkingDirectoryRetention: Sendable {
    nonisolated private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var directories: [UUID: URL] = [:]
    }

    private static let storage = Storage()
    private let id = UUID()

    /// Identity is acquired off-main before launch; launch uses this same path.
    /// Never re-resolve an alias after its process generation has been admitted.
    init(canonicalDirectory: URL) {
        Self.storage.lock.withLock {
            Self.storage.directories[id] = canonicalDirectory.standardizedFileURL
        }
    }

    var isRetained: Bool {
        Self.storage.lock.withLock { Self.storage.directories[id] != nil }
    }

    /// Already-canonical snapshot. Retention checks perform lexical comparisons
    /// only, with no filesystem access on the main actor.
    static var retainedDirectories: [URL] {
        storage.lock.withLock { Array(storage.directories.values) }
    }

    static func retainsDirectory(in canonicalRoot: URL) -> Bool {
        let rootComponents = canonicalRoot.standardizedFileURL.pathComponents
        return retainedDirectories.contains {
            $0.pathComponents.starts(with: rootComponents)
        }
    }

    /// Only forkFailed proves no child ever existed. A channel failure can
    /// follow a successful fork; even a missing controller is not exit proof.
    func observeLaunchResult(_ result: Result<Void, LocalProcessError>) {
        if case .failure(.forkFailed) = result {
            finishCleanup(succeeded: true)
        }
    }

    func finishCleanup(succeeded: Bool) {
        guard succeeded else { return }
        _ = Self.storage.lock.withLock {
            Self.storage.directories.removeValue(forKey: id)
        }
    }
}
