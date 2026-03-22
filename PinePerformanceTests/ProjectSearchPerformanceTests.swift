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
}
