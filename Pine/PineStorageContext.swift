import Darwin
import Foundation

/// All application-owned persistence selects its scope before a store is created.
/// Testing also has a distinct bundle identifier: Cocoa/SwiftUI state must never
/// share the installed application's preferences or saved-window identity.
nonisolated enum PineStorageContext {
    static let namespaceEnvironmentKey = "PINE_TEST_STATE_NAMESPACE"
    static let testBundleIdentifier = "io.github.batonogov.pine.test-host"
    static let suitePrefix = "PineUITests.State."

    static let isTestHost: Bool = {
        #if PINE_TEST_HOST
        return true
        #else
        return false
        #endif
    }()

    // A missing/invalid namespace stays private even for direct test-host and
    // hosted unit-test launches. It never falls back to production storage.
    static let namespace = UUID(
        uuidString: ProcessInfo.processInfo.environment[namespaceEnvironmentKey] ?? ""
    ) ?? UUID()

    static var suiteName: String { suitePrefix + namespace.uuidString }

    // Foundation synchronizes UserDefaults access; the selected scope is immutable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isTestHost else { return .standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Cannot open isolated test preferences")
        }
        // UserDefaults suites inherit process launch arguments, retaining locale
        // and fixture overrides, but their persistent writes use only this suite.
        return defaults
    }()

    static var applicationSupportDirectory: URL {
        isTestHost ? testApplicationSupportDirectory : productionApplicationSupportDirectory
    }

    private static var productionApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Establish the private anchor before any store tries to create children.
    /// A stale namespace or symbolic link must never redirect recovery writes.
    private static let testApplicationSupportDirectory: URL = {
        do {
            return try prepareTestApplicationSupportDirectory(
                base: productionApplicationSupportDirectory, namespace: namespace
            )
        } catch {
            fatalError("Cannot establish private test storage")
        }
    }()

    static func prepareTestApplicationSupportDirectory(
        base: URL,
        namespace: UUID,
        maximumDepth: Int = 64,
        maximumEntries: Int = 100_000
    ) throws -> URL {
        let base = base.resolvingSymlinksInPath()
        var descriptor = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        for component in ["PineTestState", namespace.uuidString] {
            guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var information = stat()
            guard child >= 0, fstat(child, &information) == 0,
                  information.st_uid == getuid(), information.st_mode & 0o077 == 0 else {
                if child >= 0 { close(child) }
                throw CocoaError(.fileWriteNoPermission)
            }
            close(descriptor)
            descriptor = child
        }
        var scan = StorageScan(remainingEntries: maximumEntries, maximumDepth: maximumDepth)
        try scan.validate(directory: descriptor, depth: 0)
        // The task-store lock and its guard are deliberately linked together.
        // Every reference must be inside this namespace; a link to an owned
        // production file outside it is rejected without reading that file.
        guard scan.references.values.allSatisfy({ $0.observed == $0.expected }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return scopedApplicationSupportDirectory(base: base, testNamespace: namespace)
    }

    nonisolated private struct StorageIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// Inspect only the pre-existing test tree, before any application store is
    /// opened. This rejects stale redirects; URL-based consumers do not provide
    /// a defense against a malicious process concurrently mutating this tree.
    nonisolated private struct StorageScan {
        var remainingEntries: Int
        let maximumDepth: Int
        var references: [StorageIdentity: (observed: Int, expected: Int)] = [:]

        mutating func validate(directory: Int32, depth: Int) throws {
            guard depth < maximumDepth, remainingEntries >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            var before = stat()
            guard fstat(directory, &before) == 0 else { throw CocoaError(.fileReadNoPermission) }
            let opened = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw CocoaError(.fileReadNoPermission) }
            guard let stream = fdopendir(opened) else {
                close(opened)
                throw CocoaError(.fileReadNoPermission)
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw CocoaError(.fileReadNoPermission) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != ".." else { continue }
                guard remainingEntries > 0 else { throw CocoaError(.fileWriteNoPermission) }
                remainingEntries -= 1
                try validateEntry(name, parent: directory, depth: depth)
            }
            var after = stat()
            guard fstat(directory, &after) == 0, Self.unchanged(before, after) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        private mutating func validateEntry(_ name: String, parent: Int32, depth: Int) throws {
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_uid == getuid(),
                  before.st_mode & S_IFMT == S_IFDIR || before.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let isDirectory = before.st_mode & S_IFMT == S_IFDIR
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0)
            let child = openat(parent, name, flags)
            guard child >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, Self.unchanged(before, opened) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if isDirectory {
                try validate(directory: child, depth: depth + 1)
            } else {
                let identity = StorageIdentity(device: opened.st_dev, inode: opened.st_ino)
                let previous = references[identity] ?? (observed: 0, expected: Int(opened.st_nlink))
                guard previous.expected == Int(opened.st_nlink) else { throw CocoaError(.fileWriteNoPermission) }
                references[identity] = (previous.observed + 1, previous.expected)
            }
            var after = stat()
            guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, Self.unchanged(before, after) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        private static func unchanged(_ first: stat, _ second: stat) -> Bool {
            first.st_dev == second.st_dev && first.st_ino == second.st_ino
                && first.st_uid == second.st_uid && first.st_mode == second.st_mode
                && first.st_nlink == second.st_nlink && first.st_size == second.st_size
                && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
                && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
                && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
                && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
        }
    }

    static func scopedApplicationSupportDirectory(base: URL, testNamespace: UUID?) -> URL {
        guard let testNamespace else { return base }
        return base.appendingPathComponent("PineTestState", isDirectory: true)
            .appendingPathComponent(testNamespace.uuidString, isDirectory: true)
    }

    static func launchIsSafe(
        testHost: Bool,
        bundleIdentifier: String?,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Bool {
        if testHost { return bundleIdentifier == testBundleIdentifier }
        guard bundleIdentifier != testBundleIdentifier else { return false }
        let testMarkers = [
            namespaceEnvironmentKey, "PINE_APPLICATION_LIFECYCLE_CONFIG",
            "XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto",
            "PINE_PERSISTENCE_FAULT", "PINE_PERSISTENCE_PAUSE", "PINE_PERSISTENCE_CHECKPOINT_DIRECTORY",
        ]
        // Fixture families may seed durable state even without --reset-state.
        // Deny the entire private family so future hooks also require Testing.
        return testMarkers.allSatisfy { environment[$0] == nil }
            && !environment.keys.contains { $0.hasPrefix("PINE_UI_TEST_") }
            && !arguments.contains {
                $0 == "--reset-state" || $0 == "--application-lifecycle-process-test" || $0.hasPrefix("--ui-test-")
            }
    }
}
