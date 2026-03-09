//
//  FileNode.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

/// Один узел дерева файлов — файл или папка.
/// @Observable — современная замена ObservableObject (Swift 5.9+).
/// Не требует @Published — все var-свойства отслеживаются автоматически.
@Observable
final class FileNode: Identifiable, Hashable {
    let id: URL               // Уникальный идентификатор = полный путь к файлу
    let name: String           // Имя файла/папки (отображается в UI)
    let url: URL               // Полный путь
    let isDirectory: Bool      // true = папка, false = файл

    // С @Observable не нужен @Published — SwiftUI сам отслеживает изменения.
    var children: [FileNode]?

    init(url: URL) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        self.children = isDir.boolValue ? [] : nil
    }

    // MARK: - Загрузка содержимого папки

    func loadChildren() {
        guard isDirectory else { return }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            children = contents
                .map { FileNode(url: $0) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory == rhs.isDirectory {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.isDirectory && !rhs.isDirectory
                }
        } catch {
            print("Error loading directory \(url.path): \(error)")
            children = []
        }
    }

    // MARK: - Hashable

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
