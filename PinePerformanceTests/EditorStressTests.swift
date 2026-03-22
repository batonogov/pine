//
//  EditorStressTests.swift
//  PinePerformanceTests
//

import XCTest
import AppKit
@testable import Pine

@MainActor
final class EditorStressTests: XCTestCase {

    private var tempDir: URL!
    private var highlighter: SyntaxHighlighter!
    private let stressGrammar = Grammar(
        name: "StressTest",
        extensions: ["stresstest"],
        rules: [
            GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
            GrammarRule(
                pattern: #"\b(func|var|let|class|struct|return|if|else|for|while)\b"#,
                scope: "keyword"
            ),
        ]
    )

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineStressTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        highlighter = SyntaxHighlighter.shared
        highlighter.registerGrammar(stressGrammar)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func generateSwiftFile(lines: Int) -> String {
        var result: [String] = ["import Foundation", ""]
        var lineCount = 2
        var classIndex = 0
        while lineCount < lines {
            result.append("class Stress\(classIndex) {")
            result.append("    var value: Int = \(classIndex)")
            for m in 0..<3 {
                guard lineCount + 6 < lines else { break }
                result.append("    func method\(m)() -> String {")
                result.append("        let x = value * \(m + 1)")
                result.append("        return \"result: \\(x)\"")
                result.append("    }")
                lineCount += 4
            }
            result.append("}")
            result.append("")
            lineCount += 4
            classIndex += 1
        }
        return result.joined(separator: "\n")
    }

    private func createFile(name: String, lines: Int) -> URL {
        let content = generateSwiftFile(lines: lines)
        let url = tempDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func createFiles(count: Int, linesPerFile: Int) -> [URL] {
        (0..<count).map { i in
            createFile(name: "file\(i).swift", lines: linesPerFile)
        }
    }

    private func generateDiffOutput(fileCount: Int) -> String {
        (0..<fileCount).map {
            "diff --git a/file\($0).swift b/file\($0).swift\n"
                + "--- a/file\($0).swift\n"
                + "+++ b/file\($0).swift\n"
                + "@@ -1,3 +1,4 @@\n"
                + " import Foundation\n"
                + "+// new line\n"
                + " class Foo {}"
        }.joined(separator: "\n")
    }

    // MARK: - Large File Tests

    func testOpen10kLineFile() {
        let url = createFile(name: "large10k.swift", lines: 10_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            if let first = tabManager.tabs.first {
                tabManager.closeTab(id: first.id)
            }
        }
    }

    func testOpen50kLineFile() {
        let url = createFile(name: "large50k.swift", lines: 50_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            if let first = tabManager.tabs.first {
                tabManager.closeTab(id: first.id)
            }
        }
    }

    func testOpen100kLineFile() {
        let url = createFile(name: "large100k.swift", lines: 100_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
            if let first = tabManager.tabs.first {
                tabManager.closeTab(id: first.id)
            }
        }
    }

    func testLargeFileContentUpdate() {
        let url = createFile(name: "update_large.swift", lines: 10_000)
        let tabManager = TabManager()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        guard let content = tabManager.tabs.first?.content else { return }

        measure {
            tabManager.updateContent(content + "\n// appended line")
        }
    }

    // resident_size includes the entire process (XCTest runner, caches, etc.)
    // so this is a coarse sanity check, not a precise measurement.
    func testLargeFileMemory() {
        let url = createFile(name: "memory_test.swift", lines: 50_000)
        let tabManager = TabManager()

        let before = currentMemoryUsage()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        let after = currentMemoryUsage()

        let deltaBytes = after - before
        XCTAssertLessThan(deltaBytes, 200 * 1_048_576, "Memory delta: \(deltaBytes / 1_048_576) MB")
    }

    // MARK: - Many Tabs Tests

    func testOpen50Tabs() {
        let urls = createFiles(count: 50, linesPerFile: 100)
        let tabManager = TabManager()

        measure {
            for url in urls {
                tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            }
            for tab in tabManager.tabs {
                tabManager.closeTab(id: tab.id)
            }
        }
    }

    func testOpen100Tabs() {
        let urls = createFiles(count: 100, linesPerFile: 50)
        let tabManager = TabManager()

        measure {
            for url in urls {
                tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            }
            for tab in tabManager.tabs {
                tabManager.closeTab(id: tab.id)
            }
        }
    }

    func testTabSwitching50Tabs() {
        let urls = createFiles(count: 50, linesPerFile: 200)
        let tabManager = TabManager()
        for url in urls {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
        }

        measure {
            for tab in tabManager.tabs {
                tabManager.activeTabID = tab.id
            }
        }
    }

    func testTabSwitchingWith100TabsAndContentUpdate() {
        let urls = createFiles(count: 100, linesPerFile: 100)
        let tabManager = TabManager()
        for url in urls {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        }

        measure {
            for tab in tabManager.tabs {
                tabManager.activeTabID = tab.id
                tabManager.updateContent(tab.content + "\n// edit")
            }
        }
    }

    // MARK: - Rapid Operations Tests

    func testRapidOpenClose() {
        let urls = createFiles(count: 20, linesPerFile: 100)
        let tabManager = TabManager()

        measure {
            for _ in 0..<50 {
                for url in urls {
                    tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
                }
                for tab in tabManager.tabs {
                    tabManager.closeTab(id: tab.id)
                }
            }
        }

        XCTAssertTrue(tabManager.tabs.isEmpty)
    }

    func testRapidOpenCloseInterleavedSingle() {
        let urls = createFiles(count: 50, linesPerFile: 100)
        let tabManager = TabManager()

        measure {
            for url in urls {
                tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
                if let last = tabManager.tabs.last {
                    tabManager.closeTab(id: last.id)
                }
            }
        }

        XCTAssertTrue(tabManager.tabs.isEmpty)
    }

    func testRapidContentUpdates() {
        let url = createFile(name: "rapid_edit.swift", lines: 500)
        let tabManager = TabManager()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)

        measure {
            for i in 0..<1000 {
                tabManager.updateContent("let x\(i) = \(i)\n")
            }
        }
    }

    func testRapidSaveCycles() throws {
        let url = createFile(name: "rapid_save.swift", lines: 200)
        let tabManager = TabManager()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)

        measure {
            for i in 0..<100 {
                tabManager.updateContent("// Iteration \(i)\n")
                tabManager.saveActiveTab()
            }
        }
    }

    // MARK: - Combined Throughput Tests

    func testThroughputHighlightingAndGitParsing() {
        let code = generateSwiftFile(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let statusLines = (0..<500).map { "M  file\($0).swift" }.joined(separator: "\n")
        let diffOutput = generateDiffOutput(fileCount: 200)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "stresstest", font: font)
            _ = GitStatusProvider.parseStatusOutput(statusLines)
            _ = GitStatusProvider.parseDiff(diffOutput)
        }
    }

    func testThroughputHighlightAndFoldCalculation() {
        let code = generateSwiftFile(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let skipRanges = highlighter.commentAndStringRanges(in: code, language: "stresstest")

        measure {
            highlighter.highlight(textStorage: textStorage, language: "stresstest", font: font)
            _ = FoldRangeCalculator.calculate(text: code, skipRanges: skipRanges)
        }
    }

    func testThroughputSearchAndHighlight() {
        let code = generateSwiftFile(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let file = tempDir.appendingPathComponent("throughput_search.swift")
        try? code.write(to: file, atomically: true, encoding: .utf8)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "stresstest", font: font)
            _ = ProjectSearchProvider.searchFile(at: file, query: "value", isCaseSensitive: false)
        }
    }

    // MARK: - FileSystemWatcher Stress

    func testFileWatcherRapidStartStop() {
        measure {
            for _ in 0..<100 {
                let watcher = FileSystemWatcher { }
                watcher.watch(directory: tempDir)
                watcher.stop()
            }
        }
    }

    func testFileWatcherWithRapidFileCreation() {
        let expectation = expectation(description: "watcher callback")
        expectation.assertForOverFulfill = false

        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.1) {
            callbackCount += 1
            if callbackCount >= 1 {
                expectation.fulfill()
            }
        }
        watcher.watch(directory: tempDir)

        for i in 0..<50 {
            let file = tempDir.appendingPathComponent("watch_\(i).txt")
            try? "content \(i)".write(to: file, atomically: true, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 5.0)
        watcher.stop()

        XCTAssertGreaterThanOrEqual(callbackCount, 1)
    }

    // MARK: - External Change Detection Stress

    func testExternalChangeDetection50Tabs() {
        let urls = createFiles(count: 50, linesPerFile: 100)
        let tabManager = TabManager()
        for url in urls {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        }

        for url in urls {
            try? "// externally modified\n".write(to: url, atomically: true, encoding: .utf8)
        }

        measure {
            _ = tabManager.checkExternalChanges()
        }
    }

    // MARK: - WorkspaceManager File Tree Stress

    func testLoadLargeFileTree() {
        for dir in 0..<10 {
            let subdir = tempDir.appendingPathComponent("dir\(dir)")
            try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            for file in 0..<50 {
                let url = subdir.appendingPathComponent("file\(file).swift")
                try? "// content".write(to: url, atomically: true, encoding: .utf8)
            }
        }

        let workspace = WorkspaceManager()

        measure {
            workspace.loadDirectory(url: tempDir)
        }
    }

    // MARK: - Memory Utility

    private func currentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
