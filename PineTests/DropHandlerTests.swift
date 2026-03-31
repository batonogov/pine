//
//  DropHandlerTests.swift
//  PineTests
//
//  Created by Claude on 24.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("DropHandler Tests")
@MainActor
struct DropHandlerTests {

    /// Creates a temporary file for testing.
    private func tempFile(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a temporary directory for testing.
    private func tempDirectory(name: String = "TestProject") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - classifyURLs

    @Test("classifyURLs separates files and directories")
    func classifyURLsSeparatesFilesAndDirectories() {
        let file1 = tempFile(name: "a.swift")
        let file2 = tempFile(name: "b.txt", content: "world")
        let dir = tempDirectory()

        let result = DropHandler.classifyURLs([file1, dir, file2])

        #expect(result.files.count == 2)
        #expect(result.directories.count == 1)
        #expect(result.files.contains(file1))
        #expect(result.files.contains(file2))
        #expect(result.directories.contains(dir))
    }

    @Test("classifyURLs returns empty for empty input")
    func classifyURLsEmpty() {
        let result = DropHandler.classifyURLs([])

        #expect(result.files.isEmpty)
        #expect(result.directories.isEmpty)
    }

    @Test("classifyURLs ignores nonexistent URLs")
    func classifyURLsIgnoresNonexistent() {
        let fake = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/file.txt")

        let result = DropHandler.classifyURLs([fake])

        #expect(result.files.isEmpty)
        #expect(result.directories.isEmpty)
    }

    @Test("classifyURLs handles mixed valid and invalid URLs")
    func classifyURLsMixed() {
        let file = tempFile()
        let fake = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")

        let result = DropHandler.classifyURLs([file, fake])

        #expect(result.files.count == 1)
        #expect(result.directories.isEmpty)
    }

    // MARK: - shouldOpenAsProject

    @Test("Single directory should open as project")
    func singleDirectoryOpensAsProject() {
        let dir = tempDirectory()
        let classified = DropHandler.ClassifiedURLs(files: [], directories: [dir])

        #expect(DropHandler.shouldOpenAsProject(classified))
    }

    @Test("Only files should not open as project")
    func onlyFilesShouldNotOpenAsProject() {
        let file = tempFile()
        let classified = DropHandler.ClassifiedURLs(files: [file], directories: [])

        #expect(!DropHandler.shouldOpenAsProject(classified))
    }

    @Test("Directory with files should open as project")
    func directoryWithFilesShouldOpenAsProject() {
        let file = tempFile()
        let dir = tempDirectory()
        let classified = DropHandler.ClassifiedURLs(files: [file], directories: [dir])

        #expect(DropHandler.shouldOpenAsProject(classified))
    }

    @Test("Empty classified should not open as project")
    func emptyClassifiedShouldNotOpenAsProject() {
        let classified = DropHandler.ClassifiedURLs(files: [], directories: [])

        #expect(!DropHandler.shouldOpenAsProject(classified))
    }

    // MARK: - openFilesAsTabs

    @Test("openFilesAsTabs opens files in TabManager")
    func openFilesAsTabs() {
        let file1 = tempFile(name: "a.swift", content: "let a = 1")
        let file2 = tempFile(name: "b.swift", content: "let b = 2")
        let tabManager = TabManager()

        DropHandler.openFilesAsTabs([file1, file2], in: tabManager)

        #expect(tabManager.tabs.count == 2)
        // Last file should be active
        #expect(tabManager.activeTab?.url == file2)
    }

    @Test("openFilesAsTabs with empty array does nothing")
    func openFilesAsTabsEmpty() {
        let tabManager = TabManager()

        DropHandler.openFilesAsTabs([], in: tabManager)

        #expect(tabManager.tabs.isEmpty)
    }

    @Test("openFilesAsTabs deduplicates already open files")
    func openFilesAsTabsDeduplicates() {
        let file = tempFile(name: "dup.swift", content: "dup")
        let tabManager = TabManager()
        tabManager.openTab(url: file)
        #expect(tabManager.tabs.count == 1)

        DropHandler.openFilesAsTabs([file], in: tabManager)

        #expect(tabManager.tabs.count == 1)
    }
}
