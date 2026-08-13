//
//  MigrationManager.swift
//  Pine
//

import Foundation
import os

/// Manages sequential data migrations for UserDefaults schema changes.
///
/// On app launch, checks the stored schema version and applies any pending
/// migrations in order. Each migration is a pure function that reads old
/// format data and writes new format data.
///
/// Usage:
/// ```
/// var manager = MigrationManager()
/// manager.registerMigration(from: 0, to: 1) { defaults in
///     // transform data from v0 to v1
/// }
/// manager.runMigrations()
/// ```
struct MigrationManager {
    /// UserDefaults key for the stored schema version.
    static let schemaVersionKey = "pineSchemaVersion"

    /// The latest schema version. Bump this when adding new migrations.
    static let latestVersion = 1

    /// Keys that indicate an existing (non-fresh) installation.
    /// If none of these are present and no version key exists, treat as fresh install.
    private static let existingInstallIndicators = [
        "lastSessionState",         // Legacy session key
        "recentProjectPaths",       // Recent projects
        "blameVisible"              // Git blame preference
    ]

    /// Additional key prefixes to check for existing data.
    private static let existingInstallPrefixedKeys = [
        "sessionState:"             // Per-project session keys
    ]

    private let defaults: UserDefaults
    private let faultInjector: PersistenceFaultInjector
    private var migrations: [(from: Int, to: Int, migrate: (UserDefaults) -> Void)] = []

    init(
        defaults: UserDefaults = .standard,
        faultInjector: PersistenceFaultInjector = .processEnvironment
    ) {
        self.defaults = defaults
        self.faultInjector = faultInjector
    }

    /// Registers a migration step from one version to the next.
    /// Migrations must be registered in ascending order (from: 0 → to: 1, from: 1 → to: 2, etc.).
    mutating func registerMigration(from: Int, to: Int, migrate: @escaping (UserDefaults) -> Void) {
        migrations.append((from: from, to: to, migrate: migrate))
    }

    /// Runs all pending migrations and updates the stored schema version.
    ///
    /// - Fresh install (no existing data, no version key): stamps latest version, skips migrations.
    /// - Existing install without version key: treats as version 0 and runs all migrations.
    /// - Existing install with version key: runs only migrations newer than the stored version.
    @discardableResult
    func runMigrations() -> Bool {
        let hasVersionKey = defaults.object(forKey: Self.schemaVersionKey) != nil
        let storedVersion = defaults.integer(forKey: Self.schemaVersionKey)
        let registeredVersion = migrations.map(\.to).max() ?? Self.latestVersion
        let targetVersion = max(Self.latestVersion, registeredVersion)

        if storedVersion == targetVersion {
            Logger.migration.info("Schema already at version \(targetVersion), no migrations needed")
            return true
        }

        guard storedVersion < targetVersion else {
            Logger.migration.error(
                "Refusing unknown future schema v\(storedVersion); supported through v\(targetVersion)"
            )
            return false
        }

        if !hasVersionKey && !hasExistingData() {
            // Fresh install — no data to migrate, just stamp latest version
            do {
                try runPreReplacementCheckpoints()
                Logger.migration.info(
                    "Fresh install detected, setting schema version to \(targetVersion)"
                )
                defaults.set(targetVersion, forKey: Self.schemaVersionKey)
                try faultInjector.checkpoint(
                    store: .preferences,
                    phase: .afterAtomicReplace
                )
                return true
            } catch {
                Logger.migration.error(
                    "Failed to persist fresh-install schema v\(targetVersion): \(error)"
                )
                return false
            }
        }

        // Run pending migrations
        let original = defaults.dictionaryRepresentation()
        var currentVersion = storedVersion
        let sortedMigrations = migrations.sorted { $0.from < $1.from }
        var didReplace = false

        do {
            try faultInjector.checkpoint(
                store: .preferences,
                phase: .beforeWrite
            )
            for migration in sortedMigrations where migration.from >= currentVersion {
                Logger.migration.info("Running migration v\(migration.from) → v\(migration.to)")
                migration.migrate(defaults)
                currentVersion = migration.to
            }
            try faultInjector.checkpoint(
                store: .preferences,
                phase: .afterTemporaryWrite
            )
            try faultInjector.checkpoint(
                store: .preferences,
                phase: .beforeSync
            )
            try faultInjector.checkpoint(
                store: .preferences,
                phase: .beforeAtomicReplace
            )

            defaults.set(targetVersion, forKey: Self.schemaVersionKey)
            didReplace = true
            try faultInjector.checkpoint(
                store: .preferences,
                phase: .afterAtomicReplace
            )
            Logger.migration.info("Migration complete, schema now at version \(targetVersion)")
            return true
        } catch {
            if !didReplace { restoreDefaults(original) }
            Logger.migration.error(
                "Migration to schema v\(targetVersion) failed safely: \(error)"
            )
            return false
        }
    }

    // MARK: - Private

    /// Returns true if UserDefaults contains keys indicating an existing Pine installation.
    private func hasExistingData() -> Bool {
        for key in Self.existingInstallIndicators where defaults.object(forKey: key) != nil {
            return true
        }
        // Check for prefixed keys (e.g. per-project session keys like "sessionState:/path/...")
        let allKeys = defaults.dictionaryRepresentation().keys
        for prefix in Self.existingInstallPrefixedKeys
            where allKeys.contains(where: { $0.hasPrefix(prefix) }) {
            return true
        }
        return false
    }

    private func runPreReplacementCheckpoints() throws {
        for phase in [
            PersistenceWritePhase.beforeWrite,
            .afterTemporaryWrite,
            .beforeSync,
            .beforeAtomicReplace,
        ] {
            try faultInjector.checkpoint(store: .preferences, phase: phase)
        }
    }

    private func restoreDefaults(_ snapshot: [String: Any]) {
        for key in defaults.dictionaryRepresentation().keys
            where snapshot[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in snapshot {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: - Default Migrations

    /// Creates a MigrationManager with all built-in migrations registered.
    static func withDefaultMigrations(
        defaults: UserDefaults = .standard,
        faultInjector: PersistenceFaultInjector = .processEnvironment
    ) -> MigrationManager {
        var manager = MigrationManager(
            defaults: defaults,
            faultInjector: faultInjector
        )

        // Migration v0 → v1: Clean up stale recent projects that no longer exist on disk
        manager.registerMigration(from: 0, to: 1) { defs in
            if var paths = defs.stringArray(forKey: "recentProjectPaths") {
                let before = paths.count
                paths.removeAll { path in
                    var isDir: ObjCBool = false
                    return !FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                        || !isDir.boolValue
                }
                if paths.count != before {
                    defs.set(paths, forKey: "recentProjectPaths")
                    Logger.migration
                        .info("Cleaned \(before - paths.count) stale recent project(s)")
                }
            }
        }

        // Validate that latestVersion matches the last registered migration
        if let lastMigration = manager.migrations.max(by: { $0.to < $1.to }) {
            assert(
                latestVersion == lastMigration.to,
                "latestVersion (\(latestVersion)) must equal the last migration's target (\(lastMigration.to))"
            )
        }

        return manager
    }
}
