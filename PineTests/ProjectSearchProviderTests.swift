//
//  ProjectSearchProviderTests.swift
//  PineTests
//
//  Created by Claude on 18.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectSearchProvider Tests")
@MainActor
struct ProjectSearchProviderTests {

    /// Creates a temporary directory with test files.
    private func createTestProject(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSearchTests-\(UUID().uuidString)")
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

    /// Helper to resolve root path for collectSearchableFiles.
    private func resolvedRootPath(for dir: URL) -> String {
        let resolved = dir.resolvingSymlinksInPath().path
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    // MARK: - searchFile tests

    @Test("searchFile finds matches in file content")
    func searchFileFindsMatches() throws {
        let dir = try createTestProject(files: ["test.swift": "let x = 1\nlet y = 2\nlet x = 3"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.swift"),
            query: "let x",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 3)
    }

    @Test("searchFile case-insensitive finds mixed case")
    func searchFileCaseInsensitive() throws {
        let dir = try createTestProject(files: ["test.txt": "Hello World\nhello world\nHELLO WORLD"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "hello",
            isCaseSensitive: false
        )

        #expect(matches.count == 3)
    }

    @Test("searchFile case-sensitive only finds exact case")
    func searchFileCaseSensitive() throws {
        let dir = try createTestProject(files: ["test.txt": "Hello World\nhello world\nHELLO WORLD"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "hello",
            isCaseSensitive: true
        )

        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 2)
    }

    @Test("searchFile returns empty for no matches")
    func searchFileNoMatches() throws {
        let dir = try createTestProject(files: ["test.txt": "some content here"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "notfound",
            isCaseSensitive: false
        )

        #expect(matches.isEmpty)
    }

    @Test("searchFile respects remaining capacity")
    func searchFileRespectsCapacity() throws {
        let dir = try createTestProject(files: ["test.txt": "aaa\naaa\naaa\naaa\naaa"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "aaa",
            isCaseSensitive: false,
            remainingCapacity: 2
        )

        #expect(matches.count == 2)
    }

    @Test("searchFile finds multiple matches on same line")
    func searchFileMultipleMatchesSameLine() throws {
        let dir = try createTestProject(files: ["test.txt": "foo bar foo baz foo"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "foo",
            isCaseSensitive: false
        )

        #expect(matches.count == 3)
        #expect(matches.allSatisfy { $0.lineNumber == 1 })
    }

    @Test("searchFile returns correct line numbers (1-based)")
    func searchFileLineNumbers() throws {
        let dir = try createTestProject(files: ["test.txt": "a\nb\nc\nd\ne"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "c",
            isCaseSensitive: false
        )

        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 3)
    }

    @Test("searchFile handles special characters without crashing")
    func searchFileSpecialCharacters() throws {
        let dir = try createTestProject(files: ["test.swift": "func foo() { }\nfunc bar() { }"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.swift"),
            query: "func(",
            isCaseSensitive: false
        )

        // "func(" doesn't match because of space before (
        #expect(matches.isEmpty)
    }

    // MARK: - collectSearchableFiles tests

    @Test("collectSearchableFiles skips .git directory")
    func collectSkipsGitDir() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            ".git/config": "git config"
        ])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("config"))
    }

    @Test("collectSearchableFiles skips binary files")
    func collectSkipsBinaryFiles() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            "image.png": "fake png"
        ])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("image.png"))
    }

    @Test("collectSearchableFiles skips ignored directories")
    func collectSkipsIgnoredDirs() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            "build/output.txt": "build output"
        ])
        defer { cleanup(dir) }

        let buildPath = dir.appendingPathComponent("build").resolvingSymlinksInPath().path
        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [buildPath], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("output.txt"))
    }

    @Test("collectSearchableFiles skips large files")
    func collectSkipsLargeFiles() throws {
        let dir = try createTestProject(files: ["main.swift": "code"])
        defer { cleanup(dir) }

        // Create a file larger than 1MB
        let largeURL = dir.appendingPathComponent("large.txt")
        let largeData = Data(count: ProjectSearchProvider.maxFileSize + 1)
        try largeData.write(to: largeURL)

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("large.txt"))
    }

    @Test("collectSearchableFiles returns relative paths")
    func collectReturnsRelativePaths() throws {
        let dir = try createTestProject(files: ["sub/file.txt": "content"])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )

        #expect(files.count == 1)
        #expect(files[0].1 == "sub/file.txt")
    }

    // MARK: - performSearch integration tests

    @Test("performSearch returns grouped results")
    func performSearchGroupedResults() async throws {
        let dir = try createTestProject(files: [
            "a.swift": "let foo = 1",
            "b.swift": "var foo = 2\nlet bar = 3",
            "c.txt": "no match here"
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "foo",
            isCaseSensitive: false,
            rootURL: dir
        )

        #expect(groups.count == 2)
        let totalMatches = groups.reduce(0) { $0 + $1.matches.count }
        #expect(totalMatches == 2)
    }

    @Test("performSearch with empty query returns empty results")
    func performSearchEmptyQuery() async {
        let groups = await ProjectSearchProvider.performSearch(
            query: "",
            isCaseSensitive: false,
            rootURL: URL(fileURLWithPath: "/tmp")
        )

        #expect(groups.isEmpty)
    }

    @Test("performSearch uses relative paths")
    func performSearchRelativePaths() async throws {
        let dir = try createTestProject(files: ["sub/file.txt": "hello"])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "hello",
            isCaseSensitive: false,
            rootURL: dir
        )

        #expect(groups.count == 1)
        #expect(groups[0].relativePath == "sub/file.txt")
    }

    // MARK: - isBinaryFile tests

    @Test("isBinaryFile detects image files")
    func isBinaryDetectsImages() {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        #expect(ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile allows text files")
    func isBinaryAllowsText() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile allows unknown extensions")
    func isBinaryAllowsUnknown() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz123")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile treats .js as text, not binary")
    func isBinaryAllowsJS() {
        let url = URL(fileURLWithPath: "/tmp/test.js")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile treats .ts as text, not binary")
    func isBinaryAllowsTS() {
        let url = URL(fileURLWithPath: "/tmp/test.ts")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile treats .jsx and .tsx as text, not binary")
    func isBinaryAllowsJSXAndTSX() {
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.jsx")))
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.tsx")))
    }

    @Test("isBinaryFile treats .mjs and .mts as text, not binary")
    func isBinaryAllowsMJSAndMTS() {
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.mjs")))
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.mts")))
    }

    @Test("isBinaryFile treats .vue, .svelte, .astro as text, not binary")
    func isBinaryAllowsWebFrameworkExtensions() {
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/App.vue")))
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/Component.svelte")))
        #expect(!ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/page.astro")))
    }

    @Test("isBinaryFile correctly detects real binary files")
    func isBinaryDetectsRealBinaries() {
        #expect(ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.png")))
        #expect(ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.jpg")))
        #expect(ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.mp4")))
        #expect(ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.pdf")))
        #expect(ProjectSearchProvider.isBinaryFile(url: URL(fileURLWithPath: "/tmp/test.zip")))
    }

    // MARK: - SearchMatch identity tests

    @Test("SearchMatch id is deterministic from lineNumber and matchRangeStart")
    func searchMatchIdDeterministic() {
        let match1 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        let match2 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        #expect(match1.id == match2.id)
    }

    @Test("SearchMatch id differs for different positions")
    func searchMatchIdDiffers() {
        let match1 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        let match2 = SearchMatch(lineNumber: 6, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        #expect(match1.id != match2.id)
    }

    // MARK: - Provider state tests

    @Test("Empty query clears results")
    func emptyQueryClearsResults() {
        let provider = ProjectSearchProvider()
        provider.query = ""
        provider.search(in: URL(fileURLWithPath: "/tmp"))
        #expect(provider.results.isEmpty)
        #expect(provider.totalMatchCount == 0)
        #expect(!provider.isSearching)
    }

    @Test("Cancel stops search")
    func cancelStopsSearch() {
        let provider = ProjectSearchProvider()
        provider.query = "test"
        provider.search(in: URL(fileURLWithPath: "/tmp"))
        provider.cancel()
        #expect(!provider.isSearching)
    }

    @Test("Toggling case sensitivity re-searches with different results")
    func toggleCaseSensitivityChangesResults() async throws {
        let dir = try createTestProject(files: [
            "test.txt": "Hello\nhello\nHELLO"
        ])
        defer { cleanup(dir) }

        // Case-insensitive: should find all 3
        let allMatches = await ProjectSearchProvider.performSearch(
            query: "hello",
            isCaseSensitive: false,
            rootURL: dir
        )
        #expect(allMatches.flatMap(\.matches).count == 3)

        // Case-sensitive: should find only "hello"
        let exactMatches = await ProjectSearchProvider.performSearch(
            query: "hello",
            isCaseSensitive: true,
            rootURL: dir
        )
        #expect(exactMatches.flatMap(\.matches).count == 1)
        #expect(exactMatches[0].matches[0].lineNumber == 2)
    }

    @Test("Search clears previous results when query changes")
    func searchClearsPreviousResults() async throws {
        let dir = try createTestProject(files: [
            "test.txt": "alpha beta gamma"
        ])
        defer { cleanup(dir) }

        let first = await ProjectSearchProvider.performSearch(
            query: "alpha",
            isCaseSensitive: false,
            rootURL: dir
        )
        #expect(first.flatMap(\.matches).count == 1)

        let second = await ProjectSearchProvider.performSearch(
            query: "notfound",
            isCaseSensitive: false,
            rootURL: dir
        )
        #expect(second.isEmpty)
    }

    @Test("performSearch respects maxResults limit")
    func performSearchRespectsMaxResults() async throws {
        // Create a file with many matches
        let lines = (1...1500).map { "match \($0)" }.joined(separator: "\n")
        let dir = try createTestProject(files: ["big.txt": lines])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "match",
            isCaseSensitive: false,
            rootURL: dir
        )
        let totalMatches = groups.flatMap(\.matches).count

        #expect(totalMatches <= ProjectSearchProvider.maxResults)
    }

    // MARK: - searchFile: empty file

    @Test("searchFile returns empty for empty file")
    func searchFileEmptyFile() throws {
        let dir = try createTestProject(files: ["empty.txt": ""])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("empty.txt"),
            query: "anything",
            isCaseSensitive: false
        )

        #expect(matches.isEmpty)
    }

    // MARK: - searchFile: unicode content

    @Test("searchFile finds Cyrillic text")
    func searchFileCyrillic() throws {
        let dir = try createTestProject(files: ["rus.txt": "Привет мир\nДругая строка\nПривет снова"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("rus.txt"),
            query: "Привет",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 3)
    }

    @Test("searchFile finds emoji")
    func searchFileEmoji() throws {
        let dir = try createTestProject(files: ["emoji.txt": "Hello 🌲 world\nNo tree here\n🌲 again"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("emoji.txt"),
            query: "🌲",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 3)
    }

    @Test("searchFile finds CJK characters")
    func searchFileCJK() throws {
        let dir = try createTestProject(files: ["cjk.txt": "你好世界\n日本語テスト\n你好再见"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("cjk.txt"),
            query: "你好",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 3)
    }

    // MARK: - searchFile: trailing newline

    @Test("searchFile handles trailing newline without phantom match")
    func searchFileTrailingNewline() throws {
        let dir = try createTestProject(files: ["trail.txt": "line1\nline2\n"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("trail.txt"),
            query: "line",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
    }

    // MARK: - searchFile: long line trimming

    @Test("searchFile trims long lines to 200 characters")
    func searchFileLongLineTrimming() throws {
        let longLine = String(repeating: "a", count: 300) + "FIND" + String(repeating: "b", count: 300)
        let dir = try createTestProject(files: ["long.txt": longLine])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("long.txt"),
            query: "FIND",
            isCaseSensitive: true
        )

        #expect(matches.count == 1)
        #expect(matches[0].lineContent.count <= 200)
    }

    // MARK: - SearchFileGroup model

    @Test("SearchFileGroup id equals url")
    func searchFileGroupId() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let group = SearchFileGroup(url: url, relativePath: "test.swift", matches: [])

        #expect(group.id == url)
    }

    // MARK: - searchFile across all supported language file types

    @Test("searchFile finds matches in all supported language files", arguments: [
        ("main.c", "int main() { return MARKER; }"),
        ("main.cpp", "int main() { return MARKER; }"),
        ("style.css", ".header { color: MARKER; }"),
        ("main.dart", "void main() { print(MARKER); }"),
        ("patch.diff", "+added MARKER line"),
        ("Dockerfile", "RUN echo MARKER"),
        ("main.go", "func main() { fmt.Println(MARKER) }"),
        ("schema.graphql", "type Query { MARKER: String }"),
        ("build.groovy", "println MARKER"),
        ("main.tf", "variable \"MARKER\" {}"),
        ("index.html", "<div>MARKER</div>"),
        ("config.ini", "key = MARKER"),
        ("Main.java", "System.out.println(MARKER);"),
        ("index.js", "const x = MARKER;"),
        ("app.ts", "const x: string = MARKER;"),
        ("data.json", "{\"key\": \"MARKER\"}"),
        ("Main.kt", "fun main() { println(MARKER) }"),
        ("app.log", "INFO: MARKER happened"),
        ("Makefile", "all: MARKER"),
        ("README.md", "# MARKER title"),
        ("nginx.conf", "server_name MARKER;"),
        ("default.nix", "{ pkgs ? import <nixpkgs> {} }: MARKER"),
        ("schema.prisma", "model MARKER { id Int @id }"),
        ("message.proto", "message MARKER { string name = 1; }"),
        ("main.py", "print(MARKER)"),
        ("main.rb", "puts MARKER"),
        ("main.rs", "fn main() { println!(MARKER); }"),
        ("script.sh", "echo MARKER"),
        ("query.sql", "SELECT * FROM MARKER;"),
        ("config.sshconfig", "Host MARKER"),
        ("main.swift", "print(MARKER)"),
        ("config.toml", "key = \"MARKER\""),
        ("data.xml", "<root>MARKER</root>"),
        ("config.yaml", "key: MARKER")
    ])
    func searchFileAllLanguages(filename: String, content: String) throws {
        let dir = try createTestProject(files: [filename: content])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent(filename),
            query: "MARKER",
            isCaseSensitive: true
        )

        #expect(matches.count == 1, "Expected match in \(filename)")
        #expect(matches[0].lineContent.contains("MARKER"))
    }

    @Test("collectSearchableFiles includes all supported language files")
    func collectIncludesAllLanguageFiles() throws {
        let files: [String: String] = [
            "main.c": "code", "main.cpp": "code", "style.css": "code",
            "main.dart": "code", "patch.diff": "code", "Dockerfile": "code",
            "main.go": "code", "schema.graphql": "code", "build.groovy": "code",
            "main.tf": "code", "index.html": "code", "config.ini": "code",
            "Main.java": "code", "index.js": "code", "app.ts": "code",
            "data.json": "code",
            "Main.kt": "code", "app.log": "code", "Makefile": "code",
            "README.md": "code", "nginx.conf": "code", "default.nix": "code",
            "schema.prisma": "code", "message.proto": "code", "main.py": "code",
            "main.rb": "code", "main.rs": "code", "script.sh": "code",
            "query.sql": "code", "config.sshconfig": "code", "main.swift": "code",
            "config.toml": "code", "data.xml": "code",
            "config.yaml": "code"
        ]
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let collected = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(collected.map(\.0.lastPathComponent))

        for filename in files.keys {
            #expect(names.contains(filename), "collectSearchableFiles should include \(filename)")
        }
    }

    @Test("performSearch finds matches across multiple language files")
    func performSearchAcrossLanguages() async throws {
        let dir = try createTestProject(files: [
            "main.swift": "let x = NEEDLE",
            "main.py": "x = NEEDLE",
            "main.go": "x := NEEDLE",
            "main.rs": "let x = NEEDLE;",
            "Main.java": "String x = NEEDLE;",
            "style.css": ".NEEDLE { color: red; }",
            "data.json": "{\"key\": \"NEEDLE\"}",
            "config.yaml": "key: NEEDLE",
            "index.html": "<div>NEEDLE</div>"
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "NEEDLE",
            isCaseSensitive: true,
            rootURL: dir
        )

        #expect(groups.count == 9, "Should find matches in all 9 files")
        let totalMatches = groups.flatMap(\.matches).count
        #expect(totalMatches == 9)
    }

    @Test("performSearch finds matches in .js and .ts files")
    func performSearchFindsJSAndTS() async throws {
        let dir = try createTestProject(files: [
            "app.js": "const greeting = 'NEEDLE';",
            "utils.ts": "export const value: string = 'NEEDLE';",
            "main.swift": "let x = \"NEEDLE\""
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "NEEDLE",
            isCaseSensitive: true,
            rootURL: dir
        )

        let filenames = Set(groups.map(\.url.lastPathComponent))
        #expect(filenames.contains("app.js"), "Should find matches in .js files")
        #expect(filenames.contains("utils.ts"), "Should find matches in .ts files")
        #expect(filenames.contains("main.swift"), "Should find matches in .swift files")
        #expect(groups.count == 3)
    }

    @Test("collectSearchableFiles includes .js and .ts files")
    func collectIncludesJSAndTS() throws {
        let dir = try createTestProject(files: [
            "index.js": "code",
            "app.ts": "code",
            "component.jsx": "code",
            "component.tsx": "code"
        ])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("index.js"))
        #expect(names.contains("app.ts"))
        #expect(names.contains("component.jsx"))
        #expect(names.contains("component.tsx"))
    }

    @Test("SearchFileGroup with empty matches")
    func searchFileGroupEmptyMatches() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let group = SearchFileGroup(url: url, relativePath: "test.swift", matches: [])

        #expect(group.matches.isEmpty)
        #expect(group.relativePath == "test.swift")
    }

    // MARK: - search() debounce

    @Test("search cancels previous task on rapid input")
    func searchDebouncesCancelsPrevious() async throws {
        let dir = try createTestProject(files: ["test.txt": "alpha beta gamma"])
        defer { cleanup(dir) }

        let provider = ProjectSearchProvider()

        // Rapid-fire queries — only the last one should produce results
        provider.query = "alpha"
        provider.search(in: dir)
        provider.query = "beta"
        provider.search(in: dir)
        provider.query = "gamma"
        provider.search(in: dir)

        // Wait for debounce + search to complete
        try await Task.sleep(for: .milliseconds(600))

        #expect(provider.results.flatMap(\.matches).allSatisfy {
            $0.lineContent.contains("gamma") || $0.lineContent.contains("alpha beta gamma")
        })
    }

    @Test("search with whitespace-only query clears results")
    func searchWhitespaceOnlyQuery() {
        let provider = ProjectSearchProvider()
        provider.query = "   "
        provider.search(in: URL(fileURLWithPath: "/tmp"))

        #expect(provider.results.isEmpty)
        #expect(!provider.isSearching)
    }
}
