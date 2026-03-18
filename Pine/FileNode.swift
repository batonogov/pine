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

    /// Ignored paths passed at construction time, forwarded to loadChildren().
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

    /// Initializer with project root boundary, cycle protection, and gitignored path skipping.
    convenience init(url: URL, projectRoot: URL, ignoredPaths: Set<String>) {
        let context = LoadContext(projectRoot: projectRoot, ignoredPaths: ignoredPaths)
        self.init(url: url, context: context)
    }

    /// Internal designated initializer.
    private init(url: URL, context: LoadContext?) {
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
                let realPath = url.resolvingSymlinksInPath().path
                let isCycle = isSymlink && context.visitedRealPaths.contains(realPath)
                let isOutsideRoot = isSymlink && !Self.pathIsWithinRoot(realPath, rootRealPath: context.rootRealPath)

                if isCycle || isOutsideRoot {
                    self.children = []
                    return
                }

                context.visitedRealPaths.insert(realPath)
                self.children = Self.loadContents(of: url, context: context)
            } else {
                self.children = Self.loadContents(of: url, context: nil)
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
        let fullPath = url.resolvingSymlinksInPath().path
        guard fullPath.hasPrefix(prefix) else { return false }
        let relativePath = String(fullPath.dropFirst(prefix.count))
        return context.ignoredPaths.contains(relativePath)
    }

    private static func loadContents(of url: URL, context: LoadContext?) -> [FileNode] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            return contents
                .filter { childURL in
                    let name = childURL.lastPathComponent
                    if hiddenNames.contains(name) { return false }
                    // Skip gitignored directories (but keep gitignored files — they show grey in sidebar)
                    if let context {
                        let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        if isDir && isIgnoredDirectory(childURL, context: context) {
                            return false
                        }
                    }
                    return true
                }
                .map { FileNode(url: $0, context: context) }
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
    var visitedRealPaths: Set<String>

    init(projectRoot: URL, ignoredPaths: Set<String> = []) {
        let realPath = projectRoot.resolvingSymlinksInPath().path
        self.rootRealPath = realPath
        self.ignoredPaths = ignoredPaths
        self.visitedRealPaths = []
    }
}
