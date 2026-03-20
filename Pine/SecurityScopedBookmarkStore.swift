//
//  SecurityScopedBookmarkStore.swift
//  Pine
//
//  Created by Claude on 20.03.2026.
//

import Foundation

/// Persists and resolves security-scoped bookmarks for project directories.
///
/// In App Sandbox, file access beyond user-selected locations requires
/// security-scoped bookmarks. This store saves bookmark data to UserDefaults
/// keyed by canonical path, and resolves them back to accessible URLs.
///
/// Outside App Sandbox the bookmark API still works (the security-scope
/// option is simply ignored), so this code is safe to use in both builds.
enum SecurityScopedBookmarkStore {

    private static let bookmarksKey = "securityScopedBookmarks"

    // MARK: - Save

    /// Creates and persists a security-scoped bookmark for the given URL.
    /// Returns `true` on success.
    @discardableResult
    static func saveBookmark(for url: URL, defaults: UserDefaults = .standard) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        guard let data = try? canonical.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return false
        }

        var bookmarks = loadAllBookmarks(defaults: defaults)
        bookmarks[canonical.path] = data
        defaults.set(bookmarks, forKey: bookmarksKey)
        return true
    }

    // MARK: - Resolve

    /// Resolves a previously saved bookmark for the given canonical path.
    /// Automatically refreshes stale bookmarks when possible.
    /// Returns the resolved URL, or `nil` if no bookmark exists or resolution fails.
    static func resolveBookmark(
        forPath path: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        let bookmarks = loadAllBookmarks(defaults: defaults)
        guard let data = bookmarks[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        // Refresh stale bookmark if the directory still exists
        if isStale {
            saveBookmark(for: url, defaults: defaults)
        }

        return url
    }

    // MARK: - Remove

    /// Removes the stored bookmark for the given canonical path.
    static func removeBookmark(forPath path: String, defaults: UserDefaults = .standard) {
        var bookmarks = loadAllBookmarks(defaults: defaults)
        bookmarks.removeValue(forKey: path)
        defaults.set(bookmarks, forKey: bookmarksKey)
    }

    /// Removes all stored bookmarks.
    static func removeAllBookmarks(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarksKey)
    }

    // MARK: - Security-scoped access

    /// Begins accessing a security-scoped resource.
    /// Outside sandbox this is a no-op that always succeeds.
    @discardableResult
    static func startAccessing(_ url: URL) -> Bool {
        guard SandboxEnvironment.isSandboxed else { return true }
        return url.startAccessingSecurityScopedResource()
    }

    /// Stops accessing a security-scoped resource.
    static func stopAccessing(_ url: URL) {
        guard SandboxEnvironment.isSandboxed else { return }
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Internal

    private static func loadAllBookmarks(defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }
}
