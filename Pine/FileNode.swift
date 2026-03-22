//
//  FileNode.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import Foundation

/// Один узел дерева файлов — файл или папка.
final class FileNode: Identifiable, Hashable {
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
                let isCycle = isSymlink && context.visitedRealPaths.contains(realPath)
                let isOutsideRoot = isSymlink && !Self.pathIsWithinRoot(realPath, rootRealPath: context.rootRealPath)

                if isCycle || isOutsideRoot {
                    self.children = []
                    return
                }

                // Gitignored directories are visible and expandable,
                // but loaded shallow (immediate children only) for performance.
                // Subdirectories inside can be expanded on-demand via loadChildren().
                if Self.isIgnoredDirectory(url, context: context) {
                    context.visitedRealPaths.insert(realPath)
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
                    return
                }

                context.visitedRealPaths.insert(realPath)
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
            print("Error loading directory \(url.path): \(error)")
            return []
        }
    }

    func loadChildren() {
        let context = projectRoot.map {
            LoadContext(projectRoot: $0, ignoredPaths: ignoredPaths ?? [])
        }
        children = Self.loadContents(of: url, context: context)
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

/// Tracks state during recursive file tree loading for cycle and boundary protection.
private class LoadContext {
    let rootRealPath: String
    let ignoredPaths: Set<String>
    let maxDepth: Int
    var visitedRealPaths: Set<String>

    /// Set to true when at least one directory was skipped due to maxDepth.
    /// Used by WorkspaceManager to decide whether Phase 2 (full load) is needed.
    var reachedDepthLimit = false

    /// Cache for resolved symlink paths to avoid redundant I/O.
    private var symlinkCache: [URL: String] = [:]

    init(projectRoot: URL, ignoredPaths: Set<String> = [], maxDepth: Int = .max) {
        let realPath = projectRoot.resolvingSymlinksInPath().path
        self.rootRealPath = realPath
        self.ignoredPaths = ignoredPaths
        self.maxDepth = maxDepth
        self.visitedRealPaths = []
    }

    /// Returns the resolved symlink path for the URL, caching the result.
    func resolveSymlinks(_ url: URL) -> String {
        if let cached = symlinkCache[url] {
            return cached
        }
        let resolved = url.resolvingSymlinksInPath().path
        symlinkCache[url] = resolved
        return resolved
    }
}
