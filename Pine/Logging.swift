//
//  Logging.swift
//  Pine
//
//  Created by Pine on 24.03.2026.
//

import Foundation
import os

/// Категории логирования Pine для Console.app.
nonisolated enum LogCategory: String, CaseIterable {
    case syntax
    case git
    case fileTree
    case search
    case terminal
    case editor
    case app
    case migration
    case lsp

    /// Subsystem для всех логгеров Pine.
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.batonogov.pine"
}

nonisolated extension Logger {

    /// Подсветка синтаксиса: загрузка грамматик, компиляция regex, применение стилей.
    static let syntax = Logger(subsystem: LogCategory.subsystem, category: LogCategory.syntax.rawValue)

    /// Git-операции: статус, diff, blame, ветки.
    static let git = Logger(subsystem: LogCategory.subsystem, category: LogCategory.git.rawValue)

    /// Файловое дерево: загрузка, обновление, FSEvents.
    static let fileTree = Logger(subsystem: LogCategory.subsystem, category: LogCategory.fileTree.rawValue)

    /// Поиск по проекту.
    static let search = Logger(subsystem: LogCategory.subsystem, category: LogCategory.search.rawValue)

    /// Терминал: создание сессий, процессы.
    static let terminal = Logger(subsystem: LogCategory.subsystem, category: LogCategory.terminal.rawValue)

    /// Редактор: табы, сохранение, ввод.
    static let editor = Logger(subsystem: LogCategory.subsystem, category: LogCategory.editor.rawValue)

    /// Приложение: запуск, окна, жизненный цикл.
    static let app = Logger(subsystem: LogCategory.subsystem, category: LogCategory.app.rawValue)

    /// Миграции данных.
    static let migration = Logger(subsystem: LogCategory.subsystem, category: LogCategory.migration.rawValue)

    /// LSP: языковые серверы, JSON-RPC, autocomplete.
    static let lsp = Logger(subsystem: LogCategory.subsystem, category: LogCategory.lsp.rawValue)
}
