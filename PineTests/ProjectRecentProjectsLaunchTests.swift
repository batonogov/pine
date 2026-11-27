//
//  ProjectRecentProjectsLaunchTests.swift
//  PineTests
//
//  Launch-time loading of the recent-projects list must not probe the
//  filesystem (#1869): recent roots usually live under ~/Documents, and
//  stat-ing them before any user action raises the system Documents-access
//  prompt that an ad-hoc build cannot permanently answer. Missing directories
//  stay listed until a failed open prunes them.
//

import Foundation
import Testing
@testable import Pine

@Suite(.serialized)
struct ProjectRecentProjectsLaunchTests {
    private let storeKey = "recentProjectPaths"

    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "ProjectRecentProjectsLaunchTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("UserDefaults(suiteName:) returned nil for \(suite)")
            // Unreachable in practice; the suite below keeps the types honest.
            return (UserDefaults.standard, suite)
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeExistingDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1869-exists-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRegistry(defaults: UserDefaults) -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
    }

    @Test func missingRecentSurvivesLaunchWithoutStoreRewrite() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = makeExistingDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1869-gone-\(UUID().uuidString)", isDirectory: true)
        let stored = [missing.path, existing.path]
        defaults.set(stored, forKey: storeKey)

        let registry = makeRegistry(defaults: defaults)

        // The missing entry stays listed in stored order: launch performed no
        // existence check, so there was nothing to drop it against.
        #expect(registry.recentProjects.map(\.path) == stored)
        // Launch did not rewrite the store either: no pruning save at init.
        #expect(defaults.stringArray(forKey: storeKey) == stored)
    }

    @Test func launchKeepsExistingRecentsCanonicalAndDeduplicated() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = makeExistingDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }
        // The stored path is canonical, as every save path produces. A literal
        // duplicate of it must collapse, and order must be preserved.
        let stored = [existing.path, existing.path]
        defaults.set(stored, forKey: storeKey)

        let registry = makeRegistry(defaults: defaults)

        #expect(registry.recentProjects.map(\.path) == [existing.path])
    }

    @Test func launchCapsTheListAtTenEntries() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let paths = (0..<14).map { index in
            "/tmp/pine-1869-cap-\(index)-\(UUID().uuidString)"
        }
        defaults.set(paths, forKey: storeKey)

        let registry = makeRegistry(defaults: defaults)

        #expect(registry.recentProjects.count == 10)
        #expect(registry.recentProjects.map(\.path) == Array(paths.prefix(10)))
    }

    @Test func pruneRemovesOnlyTheMissingEntryAndItsRecord() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = makeExistingDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1869-gone-\(UUID().uuidString)", isDirectory: true)
        let stored = [missing.path, existing.path]
        defaults.set(stored, forKey: storeKey)
        let registry = makeRegistry(defaults: defaults)
        #expect(registry.recentProjects.map(\.path) == stored)

        registry.pruneRecentProjectIfMissing(existing)

        // An existing directory is never pruned, including by a raced call.
        #expect(registry.recentProjects.map(\.path) == stored)
        #expect(defaults.stringArray(forKey: storeKey) == stored)

        registry.pruneRecentProjectIfMissing(missing)

        #expect(registry.recentProjects.map(\.path) == [existing.path])
        #expect(defaults.stringArray(forKey: storeKey) == [existing.path])
    }
}
