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

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineStressTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

    // MARK: - Large File Tests

    func testOpen10kLineFile() {
        let url = createFile(name: "large10k.swift", lines: 10_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            tabManager.closeTab(id: tabManager.tabs[0].id)
        }
    }

    func testOpen50kLineFile() {
        let url = createFile(name: "large50k.swift", lines: 50_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            tabManager.closeTab(id: tabManager.tabs[0].id)
        }
    }

    func testOpen100kLineFile() {
        let url = createFile(name: "large100k.swift", lines: 100_000)
        let tabManager = TabManager()

        measure {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
            tabManager.closeTab(id: tabManager.tabs[0].id)
        }
    }

    func testLargeFileContentUpdate() {
        let url = createFile(name: "update_large.swift", lines: 10_000)
        let tabManager = TabManager()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        let content = tabManager.tabs[0].content

        measure {
            tabManager.updateContent(content + "\n// appended line")
        }
    }

    func testLargeFileMemory() {
        let url = createFile(name: "memory_test.swift", lines: 50_000)
        let tabManager = TabManager()

        let before = currentMemoryUsage()
        tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        let after = currentMemoryUsage()

        let deltaBytes = after - before
        // Sanity check: opening a 50k-line file should not use more than 100 MB
        XCTAssertLessThan(deltaBytes, 100 * 1_048_576, "Memory delta: \(deltaBytes / 1_048_576) MB")
    }

    // MARK: - Many Tabs Tests

    func testOpen50Tabs() {
        let urls = createFiles(count: 50, linesPerFile: 100)
        let tabManager = TabManager()

        measure {
            for url in urls {
                tabManager.openTab(url: url, syntaxHighlightingDisabled: false)
            }
            // Cleanup for next iteration
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

        // No leaked tabs
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

    // MARK: - Concurrent Operations Tests

    func testConcurrentSyntaxHighlightingAndGitParsing() {
        let code = generateSwiftFile(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let highlighter = SyntaxHighlighter.shared

        let grammar = Grammar(
            name: "StressSwift",
            extensions: ["stressswift"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct|return|if|else|for|while)\b"#,
                    scope: "keyword"
                ),
            ]
        )
        highlighter.registerGrammar(grammar)

        // Generate git status output
        let statusLines = (0..<500).map { "M  file\($0).swift" }.joined(separator: "\n")
        let diffOutput = (0..<200).map { """
            diff --git a/file\($0).swift b/file\($0).swift
            --- a/file\($0).swift
            +++ b/file\($0).swift
            @@ -1,3 +1,4 @@
             import Foundation
            +// new line
             class Foo {}
            """
        }.joined(separator: "\n")

        measure {
            // Simulate concurrent work
            highlighter.highlight(textStorage: textStorage, language: "stressswift", font: font)
            _ = GitStatusProvider.parseStatusOutput(statusLines)
            _ = GitStatusProvider.parseDiff(diffOutput)
        }
    }

    func testConcurrentHighlightAndFoldCalculation() {
        let code = generateSwiftFile(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let highlighter = SyntaxHighlighter.shared

        // Reuse grammar registered above or register fresh
        let grammar = Grammar(
            name: "StressFold",
            extensions: ["stressfold"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct)\b"#,
                    scope: "keyword"
                ),
            ]
        )
        highlighter.registerGrammar(grammar)

        let skipRanges = highlighter.commentAndStringRanges(in: code, language: "stressfold")

        measure {
            highlighter.highlight(textStorage: textStorage, language: "stressfold", font: font)
            _ = FoldRangeCalculator.calculate(in: code, skipRanges: skipRanges)
        }
    }

    func testConcurrentSearchAndHighlight() {
        let lines = 5000
        let code = generateSwiftFile(lines: lines)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let highlighter = SyntaxHighlighter.shared

        let file = tempDir.appendingPathComponent("concurrent_search.swift")
        try? code.write(to: file, atomically: true, encoding: .utf8)

        let grammar = Grammar(
            name: "StressSearch",
            extensions: ["stresssearch"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #"\b(func|var|let|class)\b"#, scope: "keyword"),
            ]
        )
        highlighter.registerGrammar(grammar)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "stresssearch", font: font)
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

        // Create many files rapidly
        for i in 0..<50 {
            let file = tempDir.appendingPathComponent("watch_\(i).txt")
            try? "content \(i)".write(to: file, atomically: true, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 5.0)
        watcher.stop()

        // Callback should have fired at least once (debounced)
        XCTAssertGreaterThanOrEqual(callbackCount, 1)
    }

    // MARK: - External Change Detection Stress

    func testExternalChangeDetection50Tabs() {
        let urls = createFiles(count: 50, linesPerFile: 100)
        let tabManager = TabManager()
        for url in urls {
            tabManager.openTab(url: url, syntaxHighlightingDisabled: true)
        }

        // Modify all files externally
        for url in urls {
            try? "// externally modified\n".write(to: url, atomically: true, encoding: .utf8)
        }

        measure {
            _ = tabManager.checkExternalChanges()
        }
    }

    // MARK: - WorkspaceManager File Tree Stress

    func testLoadLargeFileTree() {
        // Create 500 files in nested directories
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
