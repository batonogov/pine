//
//  MigrationManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct MigrationManagerTests {

    /// Creates a fresh in-memory UserDefaults suite for test isolation.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.pine.test.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    // MARK: - Fresh install starts at latest version

    @Test func freshInstall_setsLatestVersion() {
        let defaults = makeDefaults()

        let manager = MigrationManager(defaults: defaults)
        manager.runMigrations()

        #expect(defaults.integer(forKey: MigrationManager.schemaVersionKey) == MigrationManager.latestVersion)
    }

    @Test func freshInstall_doesNotRunMigrations() {
        let defaults = makeDefaults()
        var migrationRan = false

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in
            migrationRan = true
        }
        manager.runMigrations()

        #expect(!migrationRan)
    }

    // MARK: - Migration v0 → v1

    @Test func migration_v0_to_v1_runs() {
        let defaults = makeDefaults()
        // Simulate a pre-migration installation (version 0 = no key set, but has data)
        defaults.set("some-old-data", forKey: "legacyKey")
        defaults.set(0, forKey: MigrationManager.schemaVersionKey)

        var migrationRan = false

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { defs in
            migrationRan = true
            defs.removeObject(forKey: "legacyKey")
        }
        manager.runMigrations()

        #expect(migrationRan)
        #expect(defaults.object(forKey: "legacyKey") == nil)
        #expect(defaults.integer(forKey: MigrationManager.schemaVersionKey) == MigrationManager.latestVersion)
    }

    // MARK: - Sequential migration chain

    @Test func migration_chain_runs_in_order() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: MigrationManager.schemaVersionKey)

        var order: [Int] = []

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in order.append(1) }
        manager.registerMigration(from: 1, to: 2) { _ in order.append(2) }
        manager.registerMigration(from: 2, to: 3) { _ in order.append(3) }
        manager.runMigrations()

        #expect(order == [1, 2, 3])
        #expect(defaults.integer(forKey: MigrationManager.schemaVersionKey) == MigrationManager.latestVersion)
    }

    @Test func migration_skips_already_applied() {
        let defaults = makeDefaults()
        defaults.set(2, forKey: MigrationManager.schemaVersionKey)

        var ranVersions: [Int] = []

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in ranVersions.append(1) }
        manager.registerMigration(from: 1, to: 2) { _ in ranVersions.append(2) }
        manager.registerMigration(from: 2, to: 3) { _ in ranVersions.append(3) }
        manager.runMigrations()

        #expect(ranVersions == [3])
    }

    // MARK: - Idempotency

    @Test func migration_idempotent_secondRunNoOp() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: MigrationManager.schemaVersionKey)

        var runCount = 0

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in runCount += 1 }

        manager.runMigrations()
        #expect(runCount == 1)

        // Second run should be a no-op — version is already at latest
        manager.runMigrations()
        #expect(runCount == 1)
    }

    // MARK: - Backward compatibility

    @Test func existingData_withoutVersionKey_treatedAsVersion0() {
        let defaults = makeDefaults()
        // Simulate existing install that never had schema versioning
        // (no schemaVersionKey set — defaults.integer returns 0)
        defaults.set("existing-session", forKey: "sessionState:/some/path")

        var migratedFromZero = false

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in migratedFromZero = true }
        manager.runMigrations()

        #expect(migratedFromZero)
        #expect(defaults.integer(forKey: MigrationManager.schemaVersionKey) == MigrationManager.latestVersion)
    }

    @Test func noExistingData_noVersionKey_freshInstall() {
        let defaults = makeDefaults()
        // Completely fresh — no data at all, no version key

        var migrationRan = false

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in migrationRan = true }
        manager.runMigrations()

        // Fresh install should NOT run migrations — just stamp latest version
        #expect(!migrationRan)
        #expect(defaults.integer(forKey: MigrationManager.schemaVersionKey) == MigrationManager.latestVersion)
    }

    // MARK: - Already at latest version

    @Test func alreadyAtLatestVersion_noMigrationsRun() {
        let defaults = makeDefaults()
        defaults.set(MigrationManager.latestVersion, forKey: MigrationManager.schemaVersionKey)

        var migrationRan = false

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { _ in migrationRan = true }
        manager.runMigrations()

        #expect(!migrationRan)
    }

    // MARK: - Migration mutates UserDefaults

    @Test func migration_transformsData() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: MigrationManager.schemaVersionKey)
        defaults.set(["path1", "path2"], forKey: "recentProjectPaths")

        var manager = MigrationManager(defaults: defaults)
        manager.registerMigration(from: 0, to: 1) { defs in
            // Simulate cleaning up stale recent projects
            if var paths = defs.stringArray(forKey: "recentProjectPaths") {
                paths.removeAll { $0 == "path1" }
                defs.set(paths, forKey: "recentProjectPaths")
            }
        }
        manager.runMigrations()

        let remaining = defaults.stringArray(forKey: "recentProjectPaths")
        #expect(remaining == ["path2"])
    }
}
