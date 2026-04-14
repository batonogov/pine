//
//  ProjectSearchProviderEdgeTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("ProjectSearchProvider Edge Case Tests")
@MainActor
struct ProjectSearchProviderEdgeTests {

    private func createTestProject(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSearchEdge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = dir.appendingPathComponent(name)
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - isBinaryFile

    @Test func isBinaryFile_image() {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        #expect(ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_pdf() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        #expect(ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_font() {
        let url = URL(fileURLWithPath: "/tmp/test.ttf")
        #expect(ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_swift_notBinary() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_js_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/test.js")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_ts_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/test.ts")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_tsx_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/test.tsx")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_vue_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/App.vue")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_svelte_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/App.svelte")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_mjs_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/module.mjs")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_cjs_overrideNotBinary() {
        let url = URL(fileURLWithPath: "/tmp/module.cjs")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test func isBinaryFile_unknownExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz_unknown_ext")
        // Unknown extension → no UTType → not binary
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    // MARK: - searchFile edge cases

    @Test func searchFile_multipleMatchesPerLine() throws {
        let dir = try createTestProject(files: ["test.txt": "aaa"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "a",
            isCaseSensitive: false
        )
        #expect(matches.count == 3)
    }

    @Test func searchFile_respectsRemainingCapacity() throws {
        let dir = try createTestProject(files: ["test.txt": "a\na\na\na\na"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "a",
            isCaseSensitive: false,
            remainingCapacity: 2
        )
        #expect(matches.count == 2)
    }

    @Test func searchFile_caseSensitive_matchesExactCase() throws {
        let dir = try createTestProject(files: ["test.txt": "Hello hello HELLO"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "Hello",
            isCaseSensitive: true
        )
        #expect(matches.count == 1)
        #expect(matches[0].matchRangeStart == 0)
    }

    @Test func searchFile_caseSensitive_noMatch() throws {
        let dir = try createTestProject(files: ["test.txt": "hello world"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "Hello",
            isCaseSensitive: true
        )
        #expect(matches.isEmpty)
    }

    @Test func searchFile_nonexistentFile() {
        let matches = ProjectSearchProvider.searchFile(
            at: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID()).txt"),
            query: "test",
            isCaseSensitive: false
        )
        #expect(matches.isEmpty)
    }

    @Test func searchFile_emptyFile() throws {
        let dir = try createTestProject(files: ["empty.txt": ""])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("empty.txt"),
            query: "test",
            isCaseSensitive: false
        )
        #expect(matches.isEmpty)
    }

    @Test func searchFile_leadsWithWhitespace_offsetAdjusted() throws {
        let dir = try createTestProject(files: ["test.txt": "    hello world"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "hello",
            isCaseSensitive: false
        )
        #expect(matches.count == 1)
        // matchRangeStart should be relative to trimmed content
        #expect(matches[0].matchRangeStart == 0)
    }

    // MARK: - SearchMatch

    @Test func searchMatch_id_isDeterministic() {
        let m1 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 0, matchRangeLength: 4)
        let m2 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 0, matchRangeLength: 4)
        #expect(m1.id == m2.id)
    }

    @Test func searchMatch_differentPositions_differentIds() {
        let m1 = SearchMatch(lineNumber: 1, lineContent: "test", matchRangeStart: 0, matchRangeLength: 4)
        let m2 = SearchMatch(lineNumber: 2, lineContent: "test", matchRangeStart: 0, matchRangeLength: 4)
        #expect(m1.id != m2.id)
    }

    // MARK: - SearchFileGroup

    @Test func searchFileGroup_idIsURL() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let group = SearchFileGroup(url: url, relativePath: "test.swift", matches: [])
        #expect(group.id == url)
    }

    // MARK: - ProjectSearchProvider state

    @Test func cancel_stopsSearch() {
        let provider = ProjectSearchProvider()
        provider.query = "test"
        provider.cancel()
        #expect(provider.isSearching == false)
    }

    // MARK: - collectSearchableFiles

    @Test func collectSearchableFiles_skipsHiddenGit() throws {
        let dir = try createTestProject(files: [
            "visible.swift": "hello"
        ])
        // Create .git directory
        let gitDir = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        defer { cleanup(dir) }

        let rootPath = dir.resolvingSymlinksInPath().path
        let resolvedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: resolvedRoot
        )
        let fileNames = files.map { $0.0.lastPathComponent }
        #expect(fileNames.contains("visible.swift"))
        #expect(!fileNames.contains("HEAD"))
    }
}
