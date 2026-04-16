//
//  ProjectSearchPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
@testable import Pine

final class ProjectSearchPerformanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinePerformanceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func createFiles(count: Int, linesPerFile: Int) {
        for i in 0..<count {
            let subdir = tempDir.appendingPathComponent("dir\(i / 50)")
            try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

            var lines: [String] = []
            for j in 0..<linesPerFile {
                lines.append("let variable\(j) = \"value_\(i)_\(j)\" // line \(j)")
            }
            let content = lines.joined(separator: "\n")
            let file = subdir.appendingPathComponent("file\(i).swift")
            try? content.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Single File Search

    func testSearchSingleLargeFile() {
        let lines = (0..<5000).map { "let value\($0) = compute(\($0)) // target marker" }
        let content = lines.joined(separator: "\n")
        let file = tempDir.appendingPathComponent("large.swift")
        try? content.write(to: file, atomically: true, encoding: .utf8)

        measure {
            _ = ProjectSearchProvider.searchFile(at: file, query: "target", isCaseSensitive: false)
        }
    }

    func testSearchSingleFileCaseSensitive() {
        let lines = (0..<5000).map { "let Value\($0) = compute(\($0)) // Target marker" }
        let content = lines.joined(separator: "\n")
        let file = tempDir.appendingPathComponent("large_cs.swift")
        try? content.write(to: file, atomically: true, encoding: .utf8)

        measure {
            _ = ProjectSearchProvider.searchFile(at: file, query: "Target", isCaseSensitive: true)
        }
    }

    // MARK: - Multi-file Search (synchronous — searchFile across many files)

    func testSearchAcross200Files() {
        createFiles(count: 200, linesPerFile: 50)

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        measure {
            for (fileURL, _) in files {
                _ = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "value", isCaseSensitive: false
                )
            }
        }
    }

    func testSearchAcross500Files() {
        createFiles(count: 500, linesPerFile: 30)

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        measure {
            for (fileURL, _) in files {
                _ = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "variable", isCaseSensitive: false
                )
            }
        }
    }

    // MARK: - File Collection

    func testCollectSearchableFiles() {
        createFiles(count: 500, linesPerFile: 10)

        measure {
            _ = ProjectSearchProvider.collectSearchableFiles(
                rootURL: tempDir,
                ignoredDirs: [],
                resolvedRootPath: tempDir.resolvingSymlinksInPath().path + "/"
            )
        }
    }

    // MARK: - Large Dataset Search

    /// Creates a realistic project structure with varied file contents.
    private func createProjectStructure(
        dirCount: Int,
        filesPerDir: Int,
        linesPerFile: Int
    ) {
        let keywords = ["import", "class", "func", "var", "let", "return", "if", "else", "guard"]
        let types = ["String", "Int", "Bool", "Double", "Array", "Dictionary", "Optional"]

        for dir in 0..<dirCount {
            let subdir = tempDir.appendingPathComponent("module\(dir)/Sources")
            try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

            for file in 0..<filesPerDir {
                var lines: [String] = [
                    "import Foundation",
                    "",
                    "/// Module \(dir) - File \(file)",
                    "class Component\(dir)_\(file) {",
                ]
                for line in 0..<linesPerFile {
                    let keyword = keywords[line % keywords.count]
                    let type = types[line % types.count]
                    lines.append("    \(keyword) property\(line): \(type) = \"\(dir)_\(file)_\(line)\"")
                    if line % 10 == 0 {
                        lines.append("    // TODO: refactor this section")
                        lines.append("    /// Documentation for property\(line)")
                    }
                }
                lines.append("}")
                let content = lines.joined(separator: "\n")
                let fileURL = subdir.appendingPathComponent("Component\(dir)_\(file).swift")
                try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Creates a .gitignore to simulate real filtering.
    private func createGitignore(dirs: [String]) {
        let content = dirs.joined(separator: "\n") + "\n.DS_Store\n*.xcuserdata\n"
        let url = tempDir.appendingPathComponent(".gitignore")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 1000 files (20 dirs x 50 files), 100 lines each — ~100k total lines.
    func testSearchLargeProject1000Files() {
        createProjectStructure(dirCount: 20, filesPerDir: 50, linesPerFile: 100)

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        measure {
            for (fileURL, _) in files {
                _ = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "property", isCaseSensitive: false
                )
            }
        }
    }

    /// Search with case-sensitive matching on a large dataset.
    func testSearchLargeProjectCaseSensitive() {
        createProjectStructure(dirCount: 10, filesPerDir: 50, linesPerFile: 100)

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        measure {
            for (fileURL, _) in files {
                _ = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "Component", isCaseSensitive: true
                )
            }
        }
    }

    /// Search for a rare term (few matches) in a large project.
    /// Assertions are outside measure {} to avoid running 10x.
    func testSearchRareTermLargeProject() {
        createProjectStructure(dirCount: 20, filesPerDir: 50, linesPerFile: 100)

        // Add one file with the unique term
        let specialFile = tempDir.appendingPathComponent("module0/Sources/Special.swift")
        try? "let uniqueSearchTarget12345 = true\n".write(
            to: specialFile, atomically: true, encoding: .utf8
        )

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        var lastTotalMatches = 0

        measure {
            var totalMatches = 0
            for (fileURL, _) in files {
                let matches = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "uniqueSearchTarget12345", isCaseSensitive: false
                )
                totalMatches += matches.count
            }
            lastTotalMatches = totalMatches
        }

        // Verify outside measure {} — runs once, not 10x
        XCTAssertEqual(lastTotalMatches, 1)
    }

    /// Tests file collection performance on a large directory tree.
    func testCollectSearchableFilesLargeTree() {
        createProjectStructure(dirCount: 30, filesPerDir: 40, linesPerFile: 20)
        createGitignore(dirs: ["build", "DerivedData", ".build"])

        measure {
            _ = ProjectSearchProvider.collectSearchableFiles(
                rootURL: tempDir,
                ignoredDirs: [".git", "build", "DerivedData", ".build"],
                resolvedRootPath: tempDir.resolvingSymlinksInPath().path + "/"
            )
        }
    }

    /// Tests search throughput: many files with many matches per file.
    /// Assertions are outside measure {} to avoid running 10x.
    func testSearchHighMatchDensity() {
        // Create files where the query matches on every line
        for i in 0..<200 {
            let subdir = tempDir.appendingPathComponent("dense\(i / 20)")
            try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

            let lines = (0..<200).map { "let value\($0) = compute(value: \($0))" }
            let content = lines.joined(separator: "\n")
            let file = subdir.appendingPathComponent("dense\(i).swift")
            try? content.write(to: file, atomically: true, encoding: .utf8)
        }

        let resolvedRoot = tempDir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: tempDir,
            ignoredDirs: [],
            resolvedRootPath: resolvedRoot
        )

        var lastTotalMatches = 0

        measure {
            var totalMatches = 0
            for (fileURL, _) in files {
                let matches = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "value", isCaseSensitive: false
                )
                totalMatches += matches.count
            }
            lastTotalMatches = totalMatches
        }

        // Verify outside measure {} — runs once, not 10x
        XCTAssertGreaterThan(lastTotalMatches, 10_000)
    }
}
