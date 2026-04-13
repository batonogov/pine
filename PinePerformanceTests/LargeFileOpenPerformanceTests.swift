//
//  LargeFileOpenPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
@testable import Pine

@MainActor
final class LargeFileOpenPerformanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineLargeFilePerf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Generates a large Swift-like file of approximately the given byte size.
    private func generateFile(approximateBytes: Int) -> URL {
        let line = "    let variableName = \"some value\" // a comment about this line\n"
        let lineSize = line.utf8.count
        let lineCount = approximateBytes / lineSize
        var content = "import Foundation\n\n"
        for i in 0..<lineCount {
            if i % 50 == 0 {
                content += "\nclass Module\(i / 50) {\n"
            }
            content += "    let variable\(i) = \"value_\(i)\" // line \(i)\n"
            if i % 50 == 49 {
                content += "}\n"
            }
        }
        let url = tempDir.appendingPathComponent("large_\(approximateBytes).swift")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 10MB File (Partial Load Path)

    /// Tests opening a 10MB file, which triggers the partial load path
    /// (only first 1MB is loaded). This is a critical user-facing operation.
    func testOpen10MBFilePartialLoad() {
        let url = generateFile(approximateBytes: 10 * 1_048_576)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
            if let tab = tabManager.tabs.first {
                tabManager.closeTab(id: tab.id)
            }
        }
    }

    /// Tests opening a 5MB file with syntax highlighting disabled.
    func testOpen5MBFileNoHighlight() {
        let url = generateFile(approximateBytes: 5 * 1_048_576)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
            if let tab = tabManager.tabs.first {
                tabManager.closeTab(id: tab.id)
            }
        }
    }

    /// Tests opening a 1MB file with syntax highlighting enabled.
    /// This is the threshold where the large file dialog would appear.
    func testOpen1MBFileWithHighlight() {
        let url = generateFile(approximateBytes: 1_048_576)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            if let tab = tabManager.tabs.first {
                tabManager.closeTab(id: tab.id)
            }
        }
    }

    /// Tests sequential open of multiple large files to simulate
    /// real-world project exploration.
    func testSequentialOpen5LargeFiles() {
        let urls = (0..<5).map { _ in generateFile(approximateBytes: 2 * 1_048_576) }
        let tabManager = TabManager()

        measure {
            for url in urls {
                tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
            }
            for tab in tabManager.tabs {
                tabManager.closeTab(id: tab.id)
            }
        }
    }
}
