//
//  LoggerTests.swift
//  PineTests
//
//  Created by Pine on 24.03.2026.
//

import Foundation
import Testing
import os

@testable import Pine

@MainActor
struct LoggerTests {

    // MARK: - Subsystem

    @Test func subsystemUsesExpectedValue() {
        let expected = Bundle.main.bundleIdentifier ?? "io.github.batonogov.pine"
        #expect(LogCategory.subsystem == expected)
    }

    @Test func subsystemFallbackIsCorrect() {
        // В тестовом окружении bundleIdentifier может отличаться,
        // но fallback должен быть именно "io.github.batonogov.pine"
        let fallback = "io.github.batonogov.pine"
        let result = Bundle.main.bundleIdentifier ?? fallback
        #expect(result == LogCategory.subsystem)
    }

    // MARK: - Categories

    @Test func syntaxCategoryRawValue() {
        #expect(LogCategory.syntax.rawValue == "syntax")
    }

    @Test func gitCategoryRawValue() {
        #expect(LogCategory.git.rawValue == "git")
    }

    @Test func fileTreeCategoryRawValue() {
        #expect(LogCategory.fileTree.rawValue == "fileTree")
    }

    @Test func searchCategoryRawValue() {
        #expect(LogCategory.search.rawValue == "search")
    }

    @Test func terminalCategoryRawValue() {
        #expect(LogCategory.terminal.rawValue == "terminal")
    }

    @Test func editorCategoryRawValue() {
        #expect(LogCategory.editor.rawValue == "editor")
    }

    @Test func appCategoryRawValue() {
        #expect(LogCategory.app.rawValue == "app")
    }

    @Test func migrationCategoryRawValue() {
        #expect(LogCategory.migration.rawValue == "migration")
    }

    @Test func lspCategoryRawValue() {
        #expect(LogCategory.lsp.rawValue == "lsp")
    }

    @Test func taskCategoryRawValue() {
        #expect(LogCategory.task.rawValue == "task")
    }

    @Test func extensibilityCategoryRawValue() {
        #expect(LogCategory.extensibility.rawValue == "extensibility")
    }

    // MARK: - Uniqueness

    @Test func allCategoriesAreUnique() {
        let rawValues = LogCategory.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    // MARK: - CaseIterable

    @Test func expectedCategoryCount() {
        #expect(LogCategory.allCases.count == 12)
    }

    @Test func allCasesContainsAllCategories() {
        let expected: Set<LogCategory> = [
            .syntax,
            .git,
            .fileTree,
            .search,
            .terminal,
            .editor,
            .app,
            .migration,
            .lsp,
            .task,
            .extensibility,
            .agent,
        ]
        #expect(Set(LogCategory.allCases) == expected)
    }

    // MARK: - Logger static properties exist and are usable

    @Test func loggerStaticPropertiesDoNotCrash() {
        Logger.syntax.debug("test")
        Logger.git.debug("test")
        Logger.fileTree.debug("test")
        Logger.search.debug("test")
        Logger.terminal.debug("test")
        Logger.editor.debug("test")
        Logger.app.debug("test")
        Logger.migration.debug("test")
        Logger.lsp.debug("test")
        Logger.task.debug("test")
        Logger.extensibility.debug("test")
    }

    // MARK: - Logger creation from category

    @Test func loggerCanBeCreatedFromAnyCategory() {
        for category in LogCategory.allCases {
            let logger = Logger(subsystem: LogCategory.subsystem, category: category.rawValue)
            logger.debug("Testing category: \(category.rawValue)")
        }
    }
}
