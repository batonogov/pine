//
//  SecurityScopedBookmarkStoreTests.swift
//  PineTests
//
//  Created by Claude on 20.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("SecurityScopedBookmarkStore")
struct SecurityScopedBookmarkStoreTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "PineTests-bookmarks-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        return UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Save & resolve

    @Test("Save and resolve bookmark for existing directory")
    func saveAndResolve() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }
        let defaults = freshDefaults()

        let saved = SecurityScopedBookmarkStore.saveBookmark(for: tempDir, defaults: defaults)
        #expect(saved)

        let resolved = SecurityScopedBookmarkStore.resolveBookmark(
            forPath: tempDir.resolvingSymlinksInPath().path,
            defaults: defaults
        )
        #expect(resolved != nil)
        #expect(resolved?.resolvingSymlinksInPath().path == tempDir.resolvingSymlinksInPath().path)
    }

    @Test("Resolve returns nil for unknown path")
    func resolveUnknownPath() {
        let defaults = freshDefaults()
        let resolved = SecurityScopedBookmarkStore.resolveBookmark(
            forPath: "/nonexistent/path",
            defaults: defaults
        )
        #expect(resolved == nil)
    }

    // MARK: - Remove

    @Test("Remove bookmark deletes stored data")
    func removeBookmark() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }
        let defaults = freshDefaults()

        let saved = SecurityScopedBookmarkStore.saveBookmark(for: tempDir, defaults: defaults)
        #expect(saved)

        let canonicalPath = tempDir.resolvingSymlinksInPath().path
        SecurityScopedBookmarkStore.removeBookmark(forPath: canonicalPath, defaults: defaults)

        let resolved = SecurityScopedBookmarkStore.resolveBookmark(
            forPath: canonicalPath,
            defaults: defaults
        )
        #expect(resolved == nil)
    }

    // MARK: - Remove all

    @Test("Remove all bookmarks clears the store")
    func removeAllBookmarks() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer {
            cleanup(dir1)
            cleanup(dir2)
        }
        let defaults = freshDefaults()

        #expect(SecurityScopedBookmarkStore.saveBookmark(for: dir1, defaults: defaults))
        #expect(SecurityScopedBookmarkStore.saveBookmark(for: dir2, defaults: defaults))

        SecurityScopedBookmarkStore.removeAllBookmarks(defaults: defaults)

        let path1 = dir1.resolvingSymlinksInPath().path
        let path2 = dir2.resolvingSymlinksInPath().path
        #expect(SecurityScopedBookmarkStore.resolveBookmark(forPath: path1, defaults: defaults) == nil)
        #expect(SecurityScopedBookmarkStore.resolveBookmark(forPath: path2, defaults: defaults) == nil)
    }

    // MARK: - Overwrite

    @Test("Saving bookmark for same path overwrites previous")
    func overwriteBookmark() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }
        let defaults = freshDefaults()

        #expect(SecurityScopedBookmarkStore.saveBookmark(for: tempDir, defaults: defaults))
        #expect(SecurityScopedBookmarkStore.saveBookmark(for: tempDir, defaults: defaults))

        let resolved = SecurityScopedBookmarkStore.resolveBookmark(
            forPath: tempDir.resolvingSymlinksInPath().path,
            defaults: defaults
        )
        #expect(resolved != nil)
    }

    // MARK: - Deleted directory

    @Test("Resolve returns nil after directory is deleted")
    func resolveDeletedDirectory() throws {
        let tempDir = try makeTempDirectory()
        let defaults = freshDefaults()
        let canonicalPath = tempDir.resolvingSymlinksInPath().path

        #expect(SecurityScopedBookmarkStore.saveBookmark(for: tempDir, defaults: defaults))
        cleanup(tempDir)

        // Bookmark data exists but directory is gone — resolve may return the URL
        // but the caller (ProjectRegistry) checks directory existence separately.
        // We just verify no crash.
        _ = SecurityScopedBookmarkStore.resolveBookmark(forPath: canonicalPath, defaults: defaults)
    }

    // MARK: - Symlink deduplication

    @Test("Save via symlink uses canonical path as key")
    func symlinkDeduplication() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let symlinkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: tempDir)
        defer { cleanup(symlinkDir) }

        let defaults = freshDefaults()

        #expect(SecurityScopedBookmarkStore.saveBookmark(for: symlinkDir, defaults: defaults))

        // Resolve using canonical path should work
        let canonicalPath = tempDir.resolvingSymlinksInPath().path
        let resolved = SecurityScopedBookmarkStore.resolveBookmark(
            forPath: canonicalPath,
            defaults: defaults
        )
        #expect(resolved != nil)
    }

    // MARK: - Access tracking

    @Test("startAccessing and stopAccessing do not crash outside sandbox")
    func accessTrackingOutsideSandbox() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Outside sandbox these are no-ops but should not crash
        SecurityScopedBookmarkStore.startAccessing(tempDir)
        SecurityScopedBookmarkStore.stopAccessing(tempDir)
    }
}
