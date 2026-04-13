//
//  FullProjectSearchPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
@testable import Pine

final class FullProjectSearchPerformanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineFullSearchPerf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

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

    // MARK: - Large Dataset Search

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

        measure {
            var totalMatches = 0
            for (fileURL, _) in files {
                let matches = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "uniqueSearchTarget12345", isCaseSensitive: false
                )
                totalMatches += matches.count
            }
            // Verify we found the needle
            XCTAssertEqual(totalMatches, 1)
        }
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

        measure {
            var totalMatches = 0
            for (fileURL, _) in files {
                let matches = ProjectSearchProvider.searchFile(
                    at: fileURL, query: "value", isCaseSensitive: false
                )
                totalMatches += matches.count
            }
            XCTAssertGreaterThan(totalMatches, 10_000)
        }
    }
}
