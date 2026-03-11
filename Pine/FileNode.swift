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

    var children: [FileNode]?

    /// Для List(children:): nil = лист (файл), непустой массив = папка с содержимым.
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        let items = children ?? []
        return items.isEmpty ? nil : items
    }

    init(url: URL) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        self.children = isDir.boolValue ? Self.loadContents(of: url) : nil
    }

    // MARK: - Загрузка содержимого папки

    private static func loadContents(of url: URL) -> [FileNode] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return contents
                .map { FileNode(url: $0) }
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
        children = Self.loadContents(of: url)
    }

    // MARK: - Hashable

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
