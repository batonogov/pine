//
//  TabEditorStateTests.swift
//  PineTests
//
//  Tests for per-tab editor state persistence (scroll, cursor, fold state).
//

import Foundation
import Testing

@testable import Pine

@Suite("PerTabEditorState Tests")
struct TabEditorStateTests {

    // MARK: - Serialization / deserialization

    @Test("PerTabEditorState encodes and decodes correctly")
    func roundTripCodable() throws {
        let state = PerTabEditorState(
            cursorPosition: 42,
            scrollOffset: 123.5,
            foldedRanges: [
                PerTabEditorState.SerializableFoldRange(
                    startLine: 10, endLine: 20,
                    startCharIndex: 100, endCharIndex: 250,
                    kind: "braces"
                )
            ]
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PerTabEditorState.self, from: data)

        #expect(decoded.cursorPosition == 42)
        #expect(decoded.scrollOffset == 123.5)
        #expect(decoded.foldedRanges?.count == 1)
        #expect(decoded.foldedRanges?[0].startLine == 10)
        #expect(decoded.foldedRanges?[0].endLine == 20)
        #expect(decoded.foldedRanges?[0].startCharIndex == 100)
        #expect(decoded.foldedRanges?[0].endCharIndex == 250)
        #expect(decoded.foldedRanges?[0].kind == "braces")
    }

    @Test("PerTabEditorState decodes with missing foldedRanges (backwards compat)")
    func decodesWithoutFoldedRanges() throws {
        let json = """
        {"cursorPosition": 10, "scrollOffset": 50.0}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PerTabEditorState.self, from: data)

        #expect(decoded.cursorPosition == 10)
        #expect(decoded.scrollOffset == 50.0)
        #expect(decoded.foldedRanges == nil)
    }

    @Test("PerTabEditorState with zero values")
    func zeroValues() throws {
        let state = PerTabEditorState(cursorPosition: 0, scrollOffset: 0, foldedRanges: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PerTabEditorState.self, from: data)

        #expect(decoded.cursorPosition == 0)
        #expect(decoded.scrollOffset == 0)
        #expect(decoded.foldedRanges == nil)
    }

    // MARK: - FoldState conversion

    @Test("FoldState converts to serializable fold ranges")
    func foldStateToSerializable() {
        var foldState = FoldState()
        foldState.fold(FoldableRange(
            startLine: 5, endLine: 15,
            startCharIndex: 50, endCharIndex: 200,
            kind: .braces
        ))
        foldState.fold(FoldableRange(
            startLine: 20, endLine: 25,
            startCharIndex: 300, endCharIndex: 400,
            kind: .brackets
        ))

        let serializable = PerTabEditorState.serializableFoldRanges(from: foldState)

        #expect(serializable.count == 2)
        #expect(serializable[0].startLine == 5)
        #expect(serializable[0].endLine == 15)
        #expect(serializable[0].kind == "braces")
        #expect(serializable[1].startLine == 20)
        #expect(serializable[1].kind == "brackets")
    }

    @Test("Serializable fold ranges restore to FoldState")
    func serializableToFoldState() {
        let ranges = [
            PerTabEditorState.SerializableFoldRange(
                startLine: 5, endLine: 15,
                startCharIndex: 50, endCharIndex: 200,
                kind: "braces"
            ),
            PerTabEditorState.SerializableFoldRange(
                startLine: 20, endLine: 25,
                startCharIndex: 300, endCharIndex: 400,
                kind: "parentheses"
            )
        ]

        let foldState = PerTabEditorState.restoreFoldState(from: ranges)

        #expect(foldState.foldedRanges.count == 2)
        #expect(foldState.foldedRanges[0].startLine == 5)
        #expect(foldState.foldedRanges[0].endLine == 15)
        #expect(foldState.foldedRanges[0].kind == .braces)
        #expect(foldState.foldedRanges[1].startLine == 20)
        #expect(foldState.foldedRanges[1].kind == .parentheses)
        #expect(foldState.isLineHidden(6))
        #expect(foldState.isLineHidden(14))
        #expect(!foldState.isLineHidden(5))
        #expect(!foldState.isLineHidden(15))
    }

    @Test("Empty fold state produces empty serializable ranges")
    func emptyFoldState() {
        let foldState = FoldState()
        let serializable = PerTabEditorState.serializableFoldRanges(from: foldState)
        #expect(serializable.isEmpty)
    }

    @Test("Empty serializable ranges produce empty fold state")
    func emptySerializableRanges() {
        let foldState = PerTabEditorState.restoreFoldState(from: [])
        #expect(foldState.foldedRanges.isEmpty)
    }

    @Test("Unknown fold kind defaults to braces")
    func unknownFoldKind() {
        let ranges = [
            PerTabEditorState.SerializableFoldRange(
                startLine: 1, endLine: 5,
                startCharIndex: 0, endCharIndex: 50,
                kind: "unknown_kind"
            )
        ]
        let foldState = PerTabEditorState.restoreFoldState(from: ranges)
        #expect(foldState.foldedRanges[0].kind == .braces)
    }

    // MARK: - SessionState integration

    @Test("SessionState saves and loads editor states")
    func sessionStateEditorStates() throws {
        let suiteName = "TabEditorStateTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removeSuite(named: suiteName) }

        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let fileURL = projectURL.appendingPathComponent("main.swift")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let editorStates: [String: PerTabEditorState] = [
            fileURL.path: PerTabEditorState(
                cursorPosition: 100,
                scrollOffset: 500.0,
                foldedRanges: [
                    PerTabEditorState.SerializableFoldRange(
                        startLine: 3, endLine: 8,
                        startCharIndex: 30, endCharIndex: 80,
                        kind: "braces"
                    )
                ]
            )
        ]

        SessionState.save(
            projectURL: projectURL,
            openFileURLs: [fileURL],
            activeFileURL: fileURL,
            editorStates: editorStates,
            defaults: defaults
        )

        let loaded = SessionState.load(for: projectURL, defaults: defaults)

        #expect(loaded != nil)
        #expect(loaded?.editorStates?[fileURL.path]?.cursorPosition == 100)
        #expect(loaded?.editorStates?[fileURL.path]?.scrollOffset == 500.0)
        #expect(loaded?.editorStates?[fileURL.path]?.foldedRanges?.count == 1)
    }

    @Test("SessionState without editor states loads successfully (backwards compat)")
    func sessionStateBackwardsCompat() throws {
        let suiteName = "TabEditorStateTests-compat-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removeSuite(named: suiteName) }

        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        // Save without editorStates
        SessionState.save(
            projectURL: projectURL,
            openFileURLs: [],
            defaults: defaults
        )

        let loaded = SessionState.load(for: projectURL, defaults: defaults)

        #expect(loaded != nil)
        #expect(loaded?.editorStates == nil)
    }

    // MARK: - EditorTab state capture

    @Test("TabManager preserves cursor position across tab switches")
    func tabManagerPreservesCursorPosition() {
        let tabManager = TabManager()

        let url1 = URL(fileURLWithPath: "/tmp/file1.swift")
        let url2 = URL(fileURLWithPath: "/tmp/file2.swift")

        var tab1 = EditorTab(url: url1, content: "Hello world\nSecond line", savedContent: "Hello world\nSecond line")
        var tab2 = EditorTab(url: url2, content: "Another file", savedContent: "Another file")

        tabManager.tabs = [tab1, tab2]
        tabManager.activeTabID = tab1.id

        // Simulate editing position in tab1
        tabManager.updateEditorState(cursorPosition: 15, scrollOffset: 200.0)

        // Switch to tab2
        tabManager.activeTabID = tab2.id
        tabManager.updateEditorState(cursorPosition: 5, scrollOffset: 50.0)

        // Switch back to tab1 — state should be preserved
        tabManager.activeTabID = tab1.id
        let restoredTab = tabManager.activeTab
        #expect(restoredTab?.cursorPosition == 15)
        #expect(restoredTab?.scrollOffset == 200.0)
    }

    @Test("TabManager preserves fold state across tab switches")
    func tabManagerPreservesFoldState() {
        let tabManager = TabManager()

        let url1 = URL(fileURLWithPath: "/tmp/file1.swift")
        let url2 = URL(fileURLWithPath: "/tmp/file2.swift")

        let tab1 = EditorTab(url: url1, content: "content", savedContent: "content")
        let tab2 = EditorTab(url: url2, content: "content", savedContent: "content")

        tabManager.tabs = [tab1, tab2]
        tabManager.activeTabID = tab1.id

        // Fold a range in tab1
        var foldState = FoldState()
        foldState.fold(FoldableRange(
            startLine: 1, endLine: 5,
            startCharIndex: 0, endCharIndex: 50,
            kind: .braces
        ))
        tabManager.updateFoldState(foldState)

        // Switch to tab2
        tabManager.activeTabID = tab2.id

        // Switch back to tab1 — fold state should be preserved
        tabManager.activeTabID = tab1.id
        let restoredTab = tabManager.activeTab
        #expect(restoredTab?.foldState.foldedRanges.count == 1)
        #expect(restoredTab?.foldState.isLineHidden(3) == true)
    }

    // MARK: - PerTabEditorState from EditorTab

    @Test("PerTabEditorState captures state from EditorTab")
    func captureFromEditorTab() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "line1\nline2\nline3",
            savedContent: "line1\nline2\nline3"
        )
        tab.cursorPosition = 42
        tab.scrollOffset = 300.0
        tab.foldState.fold(FoldableRange(
            startLine: 1, endLine: 3,
            startCharIndex: 0, endCharIndex: 20,
            kind: .braces
        ))

        let state = PerTabEditorState.capture(from: tab)

        #expect(state.cursorPosition == 42)
        #expect(state.scrollOffset == 300.0)
        #expect(state.foldedRanges?.count == 1)
        #expect(state.foldedRanges?[0].startLine == 1)
    }

    @Test("PerTabEditorState capture omits fold ranges when none folded")
    func captureNoFolds() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "content",
            savedContent: "content"
        )
        let state = PerTabEditorState.capture(from: tab)

        #expect(state.cursorPosition == 0)
        #expect(state.scrollOffset == 0)
        #expect(state.foldedRanges == nil)
    }

    // MARK: - Apply to EditorTab

    @Test("PerTabEditorState applies to EditorTab")
    func applyToEditorTab() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "line1\nline2\nline3\nline4\nline5",
            savedContent: "line1\nline2\nline3\nline4\nline5"
        )

        let state = PerTabEditorState(
            cursorPosition: 25,
            scrollOffset: 150.0,
            foldedRanges: [
                PerTabEditorState.SerializableFoldRange(
                    startLine: 1, endLine: 4,
                    startCharIndex: 0, endCharIndex: 20,
                    kind: "braces"
                )
            ]
        )

        state.apply(to: &tab)

        #expect(tab.cursorPosition == 25)
        #expect(tab.scrollOffset == 150.0)
        #expect(tab.foldState.foldedRanges.count == 1)
        #expect(tab.foldState.isLineHidden(2))
        #expect(tab.foldState.isLineHidden(3))
        #expect(!tab.foldState.isLineHidden(1))
        #expect(!tab.foldState.isLineHidden(4))
    }

    @Test("PerTabEditorState clamps cursor position to content length")
    func applyClampsOutOfBoundsCursor() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "short",
            savedContent: "short"
        )

        let state = PerTabEditorState(
            cursorPosition: 999,
            scrollOffset: 0,
            foldedRanges: nil
        )

        state.apply(to: &tab)

        #expect(tab.cursorPosition == tab.content.utf16.count)
    }

    @Test("PerTabEditorState apply without fold ranges preserves existing fold state")
    func applyWithoutFolds() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "long enough content for cursor",
            savedContent: "long enough content for cursor"
        )
        tab.foldState.fold(FoldableRange(
            startLine: 1, endLine: 5,
            startCharIndex: 0, endCharIndex: 50,
            kind: .braces
        ))

        let state = PerTabEditorState(
            cursorPosition: 10,
            scrollOffset: 100.0,
            foldedRanges: nil
        )

        state.apply(to: &tab)

        #expect(tab.cursorPosition == 10)
        #expect(tab.scrollOffset == 100.0)
        // No foldedRanges in state — should clear the fold state (session restore starts fresh)
        #expect(tab.foldState.foldedRanges.isEmpty)
    }

    // MARK: - SessionState existingEditorStates filtering

    @Test("existingEditorStates filters to project root paths")
    func existingEditorStatesFiltering() throws {
        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let srcDir = projectURL.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let insideURL = srcDir.appendingPathComponent("main.swift")
        FileManager.default.createFile(atPath: insideURL.path, contents: nil)
        let insidePath = insideURL.path
        let outsidePath = "/other/project/file.swift"

        let state = SessionState(
            projectPath: projectURL.path,
            openFilePaths: [],
            editorStates: [
                insidePath: PerTabEditorState(cursorPosition: 10, scrollOffset: 50.0, foldedRanges: nil),
                outsidePath: PerTabEditorState(cursorPosition: 20, scrollOffset: 100.0, foldedRanges: nil)
            ]
        )

        let filtered = state.existingEditorStates
        // Only inside-project entry should survive
        #expect(filtered?[insidePath] != nil)
        #expect(filtered?[outsidePath] == nil)
    }
}
