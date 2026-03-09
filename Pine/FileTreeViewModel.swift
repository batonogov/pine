//
//  FileTreeViewModel.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

/// Одна открытая вкладка редактора.
/// Identifiable — для ForEach, Hashable — для selection.
struct EditorTab: Identifiable, Hashable {
    let id: URL          // Уникальный ключ = путь к файлу
    let name: String     // Имя файла (отображается на вкладке)
    let url: URL         // Полный путь
    var content: String  // Содержимое файла
    var savedContent: String // Содержимое на момент последнего сохранения

    /// Есть ли несохранённые изменения
    var hasUnsavedChanges: Bool { content != savedContent }

    // Hashable по id (не по content — содержимое меняется)
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Одна вкладка терминала. Содержит ссылку на свою сессию.
/// class (не struct), чтобы session не копировалась при передаче.
@Observable
final class TerminalTab: Identifiable, Hashable {
    let id = UUID()
    var name: String
    let session = TerminalSession()

    init(name: String) {
        self.name = name
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@Observable
final class FileTreeViewModel {
    var rootNodes: [FileNode] = []
    var projectName: String = "No Project"
    var rootURL: URL?
    var selectedFile: FileNode?

    // MARK: - Вкладки редактора

    /// Массив открытых вкладок
    var openTabs: [EditorTab] = []

    /// ID активной вкладки (та, что сейчас видна в редакторе)
    var activeTabID: URL?

    /// Содержимое активной вкладки — двусторонняя связь с редактором.
    /// Computed property: читает/пишет напрямую в массив openTabs.
    var activeTabContent: String {
        get {
            guard let id = activeTabID,
                  let tab = openTabs.first(where: { $0.id == id })
            else { return "" }
            return tab.content
        }
        set {
            guard let id = activeTabID,
                  let index = openTabs.firstIndex(where: { $0.id == id })
            else { return }
            openTabs[index].content = newValue
        }
    }

    /// Активная вкладка (для отображения имени, расширения и т.д.)
    var activeTab: EditorTab? {
        guard let id = activeTabID else { return nil }
        return openTabs.first(where: { $0.id == id })
    }

    // MARK: - Вкладки терминала

    var terminalTabs: [TerminalTab] = [TerminalTab(name: "Terminal")]
    var activeTerminalID: UUID?

    // MARK: - Открытие папки

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDirectory(url: url)
    }

    func loadDirectory(url: URL) {
        rootURL = url
        projectName = url.lastPathComponent

        let root = FileNode(url: url)
        root.loadChildren()
        rootNodes = root.children ?? []

        // При смене проекта закрываем старые вкладки
        openTabs.removeAll()
        activeTabID = nil

        // Инициализируем первую вкладку терминала
        if terminalTabs.isEmpty {
            terminalTabs = [TerminalTab(name: "Terminal")]
        }
        activeTerminalID = terminalTabs.first?.id
    }

    // MARK: - Выбор файла (открытие вкладки)

    func selectFile(_ node: FileNode) {
        guard !node.isDirectory else { return }
        selectedFile = node

        // Если файл уже открыт — просто переключаемся на его вкладку
        if openTabs.contains(where: { $0.id == node.url }) {
            activeTabID = node.url
            return
        }

        // Иначе — читаем файл и создаём новую вкладку
        do {
            let content = try String(contentsOf: node.url, encoding: .utf8)
            let tab = EditorTab(id: node.url, name: node.name, url: node.url, content: content, savedContent: content)
            openTabs.append(tab)
            activeTabID = tab.id
        } catch {
            let errorText = "// Error: \(error.localizedDescription)"
            let tab = EditorTab(id: node.url, name: node.name, url: node.url,
                                content: errorText, savedContent: errorText)
            openTabs.append(tab)
            activeTabID = tab.id
        }
    }

    // MARK: - Закрытие вкладки

    /// Вкладка, ожидающая подтверждения закрытия (для алерта)
    var tabPendingClose: EditorTab?

    func closeTab(_ tab: EditorTab) {
        // Если есть несохранённые изменения — показываем алерт
        if tab.hasUnsavedChanges {
            tabPendingClose = tab
            return
        }
        forceCloseTab(tab)
    }

    /// Сохраняет и закрывает вкладку
    func saveAndCloseTab(_ tab: EditorTab) {
        if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
            do {
                try openTabs[index].content.write(to: openTabs[index].url, atomically: true, encoding: .utf8)
                openTabs[index].savedContent = openTabs[index].content
            } catch {
                print("Error saving file: \(error.localizedDescription)")
            }
        }
        forceCloseTab(tab)
    }

    /// Закрывает вкладку без сохранения
    func forceCloseTab(_ tab: EditorTab) {
        openTabs.removeAll { $0.id == tab.id }

        // Если закрыли активную — переключаемся на последнюю оставшуюся
        if activeTabID == tab.id {
            activeTabID = openTabs.last?.id
        }
    }

    // MARK: - Сохранение файла

    func saveCurrentFile() {
        guard let id = activeTabID,
              let index = openTabs.firstIndex(where: { $0.id == id })
        else { return }

        do {
            try openTabs[index].content.write(to: openTabs[index].url, atomically: true, encoding: .utf8)
            openTabs[index].savedContent = openTabs[index].content
        } catch {
            print("Error saving file: \(error.localizedDescription)")
        }
    }

    // MARK: - Терминал

    /// Активная вкладка терминала
    var activeTerminalTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first(where: { $0.id == id })
    }

    /// Запускает сессии всех незапущенных терминалов (вызывается при старте)
    func startTerminals() {
        for tab in terminalTabs where !tab.session.isRunning {
            tab.session.start(workingDirectory: rootURL)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

    func addTerminalTab() {
        let number = terminalTabs.count + 1
        let tab = TerminalTab(name: "Terminal \(number)")
        tab.session.start(workingDirectory: rootURL)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
    }

    func closeTerminalTab(_ tab: TerminalTab) {
        tab.session.stop()  // Останавливаем процесс zsh
        terminalTabs.removeAll { $0.id == tab.id }
        if activeTerminalID == tab.id {
            activeTerminalID = terminalTabs.last?.id
        }
    }
}
