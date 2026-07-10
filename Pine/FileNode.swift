//
//  FileNode.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import Foundation
import os

/// Один узел дерева файлов — файл или папка.
nonisolated final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let id: URL               // Уникальный идентификатор = полный путь к файлу
    let name: String           // Имя файла/папки (отображается в UI)
    let url: URL               // Полный путь
    let isDirectory: Bool      // true = папка, false = файл
    let isSymlink: Bool        // true = символическая ссылка

    /// Project root used for symlink boundary checks during loadChildren().
    private let projectRoot: URL?

    /// Ignored paths forwarded to loadChildren() and used for shallow-loading gitignored directories.
    private let ignoredPaths: Set<String>?

    var children: [FileNode]?
    private(set) var hasDeferredChildren = false

    /// Для List(children:): nil = лист (файл), непустой массив = папка с содержимым.
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        let items = children ?? []
        return items.isEmpty ? nil : items
    }

    /// Backward-compatible initializer (no symlink protection).
    convenience init(url: URL) {
        self.init(url: url, context: nil)
    }

    /// Initializer with project root boundary and cycle protection.
    convenience init(url: URL, projectRoot: URL) {
        let context = LoadContext(projectRoot: projectRoot)
        self.init(url: url, context: context)
    }

    /// Initializer with project root boundary, cycle protection, and gitignored shallow-loading.
    convenience init(url: URL, projectRoot: URL, ignoredPaths: Set<String>) {
        let context = LoadContext(projectRoot: projectRoot, ignoredPaths: ignoredPaths)
        self.init(url: url, context: context)
    }

    /// Initializer with depth-limited loading for progressive/async tree construction.
    convenience init(url: URL, projectRoot: URL, ignoredPaths: Set<String>, maxDepth: Int) {
        let context = LoadContext(projectRoot: projectRoot, ignoredPaths: ignoredPaths, maxDepth: maxDepth)
        self.init(url: url, context: context)
    }

    /// Internal designated initializer.
    private init(url: URL, context: LoadContext?, depth: Int = 0) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.projectRoot = context.map { URL(fileURLWithPath: $0.rootRealPath) }
        self.ignoredPaths = context?.ignoredPaths

        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        self.isSymlink = resourceValues?.isSymbolicLink ?? false

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue

        if isDir.boolValue {
            if let context {
                let realPath = context.resolveSymlinks(url)
                let isCycle = isSymlink && context.hasVisited(realPath)
                let isOutsideRoot = isSymlink && !Self.pathIsWithinRoot(realPath, rootRealPath: context.rootRealPath)

                if isCycle || isOutsideRoot {
                    self.children = []
                    return
                }

                // Gitignored directories are visible and expandable,
                // but loaded shallow (immediate children only) for performance.
                // Subdirectories inside can be expanded on-demand via loadChildren().
                if Self.isIgnoredDirectory(url, context: context) {
                    context.markVisited(realPath)
                    let shallowContext = LoadContext(
                        projectRoot: URL(fileURLWithPath: context.rootRealPath),
                        ignoredPaths: context.ignoredPaths,
                        maxDepth: 0
                    )
                    self.children = Self.loadContents(of: url, context: shallowContext, depth: 1)
                    return
                }

                // Depth-limited: directories beyond maxDepth are shallow
                // (empty children), loaded on-demand via loadChildren().
                if depth > context.maxDepth {
                    context.reachedDepthLimit = true
                    self.children = []
                    self.hasDeferredChildren = true
                    return
                }

                context.markVisited(realPath)
                self.children = Self.loadContents(of: url, context: context, depth: depth + 1)
            } else {
                self.children = Self.loadContents(of: url, context: nil, depth: 0)
            }
        } else {
            self.children = nil
        }
    }

    // MARK: - Загрузка содержимого папки

    /// Names always hidden from the file tree.
    private static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Returns true if the directory at `url` is gitignored based on its relative path from the project root.
    private static func isIgnoredDirectory(_ url: URL, context: LoadContext) -> Bool {
        guard !context.ignoredPaths.isEmpty else { return false }
        let rootPath = context.rootRealPath
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let fullPath = context.resolveSymlinks(url)
        guard fullPath.hasPrefix(prefix) else { return false }
        let relativePath = String(fullPath.dropFirst(prefix.count))
        return context.ignoredPaths.contains(relativePath)
    }

    private static func loadContents(of url: URL, context: LoadContext?, depth: Int = 0) -> [FileNode] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            return contents
                .filter { childURL in
                    let name = childURL.lastPathComponent
                    return !hiddenNames.contains(name)
                }
                .map { FileNode(url: $0, context: context, depth: depth) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory == rhs.isDirectory {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.isDirectory && !rhs.isDirectory
                }
        } catch {
            Logger.fileTree.error("Error loading directory \(url.path): \(error)")
            return []
        }
    }

    func loadChildren() {
        replaceChildren(loadedChildren())
    }

    func loadedChildren() -> [FileNode] {
        let context = projectRoot.map {
            LoadContext(projectRoot: $0, ignoredPaths: ignoredPaths ?? [])
        }
        return Self.loadContents(of: url, context: context)
    }

    func replaceChildren(_ loadedChildren: [FileNode]) {
        children = loadedChildren
        hasDeferredChildren = false
    }

    /// Transfers previously-loaded children from `oldNodes` into matching
    /// deferred nodes inside `newNodes` (keyed by URL), so that expanded
    /// deep folders do not lose their content when a refresh replaces the
    /// tree with fresh (shallow) instances.
    ///
    /// Without this, every FSEvents-triggered `setRootNodes(shallowChildren)`
    /// replaces the whole tree with fresh instances where folders beyond
    /// `shallowDepth` (and every gitignored subdirectory) are
    /// `hasDeferredChildren = true, children = []`. The sidebar then shows a
    /// `ProgressView` gap while `.onChange(of: treeRevision)` re-triggers an
    /// async deferred load — visible as flicker (#1097).
    ///
    /// Merging adopts the previously-loaded children WITHOUT clearing
    /// `hasDeferredChildren`. Keeping the deferred flag true lets the
    /// sidebar's `.onChange(of: treeRevision)` re-trigger
    /// `loadDeferredChildrenIfNeeded`, which reloads fresh data in the
    /// background while the old children stay visible (no ProgressView gap).
    /// This is essential for gitignored subdirectories (e.g. `node_modules/*`):
    /// they are always shallow-loaded (`maxDepth: 0`) on a separate
    /// `LoadContext`, so `wasDepthLimit` does not propagate and Phase 2 never
    /// refreshes them — without the background reload they would go stale.
    ///
    /// Pure static helper so it is unit-testable without a WorkspaceManager.
    static func mergeLoadedSubtrees(
        into newNodes: [FileNode],
        preservingFrom oldNodes: [FileNode]
    ) {
        guard !oldNodes.isEmpty else { return }

        // Index directories that have loaded children by URL so a deferred
        // counterpart in the new tree can adopt them. Include directories
        // that are themselves still flagged deferred but already carry
        // (previously-merged) children — this chains merged children across
        // successive setRootNodes calls (Phase 1 → Phase 2, or rapid
        // successive refreshes) so a gitignored subdir does not briefly go
        // empty between phases while its background reload is in flight.
        var loadedByURL: [URL: FileNode] = [:]
        var oldStack: [FileNode] = oldNodes
        while let n = oldStack.popLast() {
            guard n.isDirectory else { continue }
            if let kids = n.children, !kids.isEmpty {
                loadedByURL[n.url] = n
            }
            if let kids = n.children { oldStack.append(contentsOf: kids) }
        }
        guard !loadedByURL.isEmpty else { return }

        // Walk the new tree; for each deferred directory with an empty
        // children array that has a loaded counterpart, adopt its children.
        // Transferred children are already fully loaded (loadedChildren uses
        // maxDepth = .max), so we do not descend into them. Crucially, we keep
        // `hasDeferredChildren = true` (do NOT call replaceChildren) so the
        // sidebar re-triggers a background reload of fresh data.
        var newStack: [FileNode] = newNodes
        while let n = newStack.popLast() {
            guard n.isDirectory else { continue }
            if n.hasDeferredChildren,
               n.children?.isEmpty ?? true,
               let old = loadedByURL[n.url],
               let oldKids = old.children, !oldKids.isEmpty {
                n.children = oldKids
                continue
            }
            if let kids = n.children { newStack.append(contentsOf: kids) }
        }
    }

    /// Result of a depth-limited tree build, including whether the depth limit was reached.
    struct LoadResult {
        let root: FileNode
        let wasDepthLimited: Bool
    }

    /// Builds a file tree with an optional depth limit and reports whether the limit was hit.
    static func loadTree(
        url: URL, projectRoot: URL,
        ignoredPaths: Set<String>, maxDepth: Int
    ) -> LoadResult {
        let context = LoadContext(projectRoot: projectRoot, ignoredPaths: ignoredPaths, maxDepth: maxDepth)
        let root = FileNode(url: url, context: context)
        return LoadResult(root: root, wasDepthLimited: context.reachedDepthLimit)
    }

    // MARK: - Root boundary check

    /// Returns true if the URL (after resolving symlinks) is within the project root.
    static func isWithinProjectRoot(_ url: URL, projectRoot: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().path
        let rootCanonical = projectRoot.resolvingSymlinksInPath().path
        return pathIsWithinRoot(canonical, rootRealPath: rootCanonical)
    }

    private static func pathIsWithinRoot(_ path: String, rootRealPath: String?) -> Bool {
        guard let root = rootRealPath else { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    // MARK: - Hashable

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Load Context

/// Shared mutable state for recursive tree loading.
/// Separated into a dedicated class so that `LoadContext` itself can be a value type,
/// eliminating the use-after-free crash caused by ARC deallocation ordering issues
/// with the previous class-based `LoadContext` (see #405).
nonisolated private final class LoadState {
    var visitedRealPaths: Set<String> = []
    var reachedDepthLimit = false
    var symlinkCache: [URL: String] = [:]
}

/// Tracks configuration and shared state during recursive file tree loading
/// for cycle detection, boundary protection, and depth limiting.
///
/// Value type by design: the struct is cheap to copy (only immutable config +
/// a single reference to shared `LoadState`), and being a struct avoids the
/// ARC deallocation crash that occurred with the previous class-based approach.
nonisolated private struct LoadContext {
    let rootRealPath: String
    let ignoredPaths: Set<String>
    let maxDepth: Int
    let state: LoadState

    /// Whether a given real path has already been visited (cycle detection).
    func hasVisited(_ realPath: String) -> Bool {
        state.visitedRealPaths.contains(realPath)
    }

    /// Records a real path as visited.
    func markVisited(_ realPath: String) {
        state.visitedRealPaths.insert(realPath)
    }

    /// Set to true when at least one directory was skipped due to maxDepth.
    /// Used by WorkspaceManager to decide whether Phase 2 (full load) is needed.
    var reachedDepthLimit: Bool {
        get { state.reachedDepthLimit }
        nonmutating set { state.reachedDepthLimit = newValue }
    }

    init(projectRoot: URL, ignoredPaths: Set<String> = [], maxDepth: Int = .max) {
        let realPath = projectRoot.resolvingSymlinksInPath().path
        self.rootRealPath = realPath
        self.ignoredPaths = ignoredPaths
        self.maxDepth = maxDepth
        self.state = LoadState()
    }

    /// Returns the resolved symlink path for the URL, caching the result.
    func resolveSymlinks(_ url: URL) -> String {
        if let cached = state.symlinkCache[url] {
            return cached
        }
        let resolved = url.resolvingSymlinksInPath().path
        state.symlinkCache[url] = resolved
        return resolved
    }
}
