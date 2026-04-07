//
//  SidebarExpansionState.swift
//  Pine
//
//  Tracks which folders are expanded in the sidebar file tree (#739).
//

import Foundation

/// Observable holder for the set of expanded folder URLs in the sidebar.
///
/// Pine renders the sidebar with a recursive `DisclosureGroup` tree so that a
/// single click anywhere on a folder row toggles its expansion (Finder/Xcode/Zed
/// behaviour). This state object stores the expanded folders by URL so that
/// expansion is preserved across `FileNode` reloads (each refresh produces new
/// `FileNode` instances even though their URLs are stable).
@MainActor
@Observable
final class SidebarExpansionState {
    /// Paths of folders currently expanded in the sidebar.
    ///
    /// We key on filesystem paths rather than `URL` because URLs returned by
    /// `FileManager.contentsOfDirectory` carry a trailing slash for directories
    /// while URLs built via `appendingPathComponent` do not — the same logical
    /// folder would otherwise compare unequal. `FileNodeRow` makes the same
    /// trade-off when checking rename state.
    private(set) var expandedPaths: Set<String> = []

    /// Convenience accessor for tests/debugging that prefer URLs.
    var expandedURLs: Set<URL> {
        Set(expandedPaths.map { URL(fileURLWithPath: $0) })
    }

    private static func key(for url: URL) -> String {
        // Resolve symlinks so that `/var/folders/...` and `/private/var/folders/...`
        // (which macOS produces depending on the API used) collapse to the same key.
        // Also normalises trailing slashes that `contentsOfDirectory` adds for
        // directories but `appendingPathComponent` does not.
        url.resolvingSymlinksInPath().path
    }

    func isExpanded(_ url: URL) -> Bool {
        expandedPaths.contains(Self.key(for: url))
    }

    func setExpanded(_ url: URL, _ expanded: Bool) {
        let key = Self.key(for: url)
        if expanded {
            expandedPaths.insert(key)
        } else {
            expandedPaths.remove(key)
        }
    }

    /// Toggles expansion for `url` and returns the new expanded state.
    @discardableResult
    func toggle(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        if expandedPaths.contains(key) {
            expandedPaths.remove(key)
            return false
        }
        expandedPaths.insert(key)
        return true
    }

    func collapseAll() {
        expandedPaths.removeAll()
    }

    /// Removes any expanded paths that are no longer present in the tree rooted
    /// at `nodes`. Used to keep the set bounded after file deletions.
    func prune(toMatch nodes: [FileNode]) {
        var alive: Set<String> = []
        var stack: [FileNode] = nodes
        while let node = stack.popLast() {
            if node.isDirectory {
                alive.insert(Self.key(for: node.url))
                if let children = node.children {
                    stack.append(contentsOf: children)
                }
            }
        }
        expandedPaths.formIntersection(alive)
    }
}
