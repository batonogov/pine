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
    private var migrations: [(from: Int, to: Int, migrate: (UserDefaults) -> Void)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    func runMigrations() {
        let hasVersionKey = defaults.object(forKey: Self.schemaVersionKey) != nil
        let storedVersion = defaults.integer(forKey: Self.schemaVersionKey)

        if storedVersion == Self.latestVersion {
            Logger.migration.info("Schema already at version \(Self.latestVersion), no migrations needed")
            return
        }

        if !hasVersionKey && !hasExistingData() {
            // Fresh install — no data to migrate, just stamp latest version
            Logger.migration.info("Fresh install detected, setting schema version to \(Self.latestVersion)")
            defaults.set(Self.latestVersion, forKey: Self.schemaVersionKey)
            return
        }

        // Run pending migrations
        var currentVersion = storedVersion
        let sortedMigrations = migrations.sorted { $0.from < $1.from }

        for migration in sortedMigrations where migration.from >= currentVersion {
            Logger.migration.info("Running migration v\(migration.from) → v\(migration.to)")
            migration.migrate(defaults)
            currentVersion = migration.to
        }

        defaults.set(Self.latestVersion, forKey: Self.schemaVersionKey)
        Logger.migration.info("Migration complete, schema now at version \(Self.latestVersion)")
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

    // MARK: - Default Migrations

    /// Creates a MigrationManager with all built-in migrations registered.
    static func withDefaultMigrations(defaults: UserDefaults = .standard) -> MigrationManager {
        var manager = MigrationManager(defaults: defaults)

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
