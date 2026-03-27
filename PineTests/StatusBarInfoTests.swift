//
//  StatusBarInfoTests.swift
//  PineTests
//
//  Created by Claude on 21.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("StatusBarInfo Tests")
struct StatusBarInfoTests {

    // MARK: - CursorLocation from position

    @Test("Line and column for empty string")
    func cursorLocationEmptyString() {
        let loc = CursorLocation(position: 0, in: "")
        #expect(loc.line == 1)
        #expect(loc.column == 1)
    }

    @Test("Line and column at start of string")
    func cursorLocationStart() {
        let loc = CursorLocation(position: 0, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 1)
    }

    @Test("Line and column mid-first line")
    func cursorLocationMidFirstLine() {
        let loc = CursorLocation(position: 3, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 4)
    }

    @Test("Line and column at newline boundary")
    func cursorLocationAtNewline() {
        let loc = CursorLocation(position: 5, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 6)
    }

    @Test("Line and column at start of second line")
    func cursorLocationSecondLine() {
        let loc = CursorLocation(position: 6, in: "hello\nworld")
        #expect(loc.line == 2)
        #expect(loc.column == 1)
    }

    @Test("Line and column at end of content")
    func cursorLocationEnd() {
        let loc = CursorLocation(position: 11, in: "hello\nworld")
        #expect(loc.line == 2)
        #expect(loc.column == 6)
    }

    @Test("Line and column with multiple lines")
    func cursorLocationMultipleLines() {
        let content = "line1\nline2\nline3"
        // Position 12 = start of "line3"
        let loc = CursorLocation(position: 12, in: content)
        #expect(loc.line == 3)
        #expect(loc.column == 1)
    }

    @Test("Line and column with CRLF line endings")
    func cursorLocationCRLF() {
        let content = "hello\r\nworld"
        // Position 7 = start of "world"
        let loc = CursorLocation(position: 7, in: content)
        #expect(loc.line == 2)
        #expect(loc.column == 1)
    }

    @Test("Position beyond content length clamps to end")
    func cursorLocationBeyondEnd() {
        let loc = CursorLocation(position: 100, in: "hello")
        #expect(loc.line == 1)
        #expect(loc.column == 6)
    }

    // MARK: - Line ending detection

    @Test("Detect LF line endings")
    func detectLF() {
        let ending = LineEnding.detect(in: "hello\nworld\n")
        #expect(ending == .lf)
    }

    @Test("Detect CRLF line endings")
    func detectCRLF() {
        let ending = LineEnding.detect(in: "hello\r\nworld\r\n")
        #expect(ending == .crlf)
    }

    @Test("Detect mixed defaults to LF")
    func detectMixed() {
        let ending = LineEnding.detect(in: "hello\nworld\r\n")
        #expect(ending == .lf)
    }

    @Test("Empty content defaults to LF")
    func detectEmptyContent() {
        let ending = LineEnding.detect(in: "")
        #expect(ending == .lf)
    }

    @Test("No line endings defaults to LF")
    func detectNoLineEndings() {
        let ending = LineEnding.detect(in: "hello world")
        #expect(ending == .lf)
    }

    @Test("LineEnding display names")
    func lineEndingDisplayName() {
        #expect(LineEnding.lf.displayName == "LF")
        #expect(LineEnding.crlf.displayName == "CRLF")
    }

    // MARK: - Line ending conversion

    @Test("Convert LF to CRLF")
    func convertLFToCRLF() {
        let result = LineEnding.crlf.convert("hello\nworld\n")
        #expect(result == "hello\r\nworld\r\n")
    }

    @Test("Convert CRLF to LF")
    func convertCRLFToLF() {
        let result = LineEnding.lf.convert("hello\r\nworld\r\n")
        #expect(result == "hello\nworld\n")
    }

    @Test("Convert already matching line endings is no-op")
    func convertNoOp() {
        let lfContent = "hello\nworld\n"
        #expect(LineEnding.lf.convert(lfContent) == lfContent)

        let crlfContent = "hello\r\nworld\r\n"
        #expect(LineEnding.crlf.convert(crlfContent) == crlfContent)
    }

    @Test("Convert mixed line endings normalizes to target")
    func convertMixed() {
        let mixed = "line1\nline2\r\nline3\n"
        let toLF = LineEnding.lf.convert(mixed)
        #expect(toLF == "line1\nline2\nline3\n")

        let toCRLF = LineEnding.crlf.convert(mixed)
        #expect(toCRLF == "line1\r\nline2\r\nline3\r\n")
    }

    @Test("Convert empty string")
    func convertEmpty() {
        #expect(LineEnding.lf.convert("") == "")
        #expect(LineEnding.crlf.convert("") == "")
    }

    @Test("Convert string with no line endings")
    func convertNoLineEndings() {
        #expect(LineEnding.lf.convert("hello") == "hello")
        #expect(LineEnding.crlf.convert("hello") == "hello")
    }

    @Test("The opposite property returns the other line ending")
    func lineEndingOpposite() {
        #expect(LineEnding.lf.opposite == .crlf)
        #expect(LineEnding.crlf.opposite == .lf)
    }

    // MARK: - TabManager line ending conversion

    @Test("TabManager converts line endings and marks dirty")
    func tabManagerConvertLineEndings() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.swift")
        try? "hello\nworld\n".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        #expect(manager.activeTab?.cachedLineEnding == .lf)

        manager.convertActiveTabLineEndings(to: .crlf)
        #expect(manager.activeTab?.content == "hello\r\nworld\r\n")
        #expect(manager.activeTab?.cachedLineEnding == .crlf)
        #expect(manager.activeTab?.isDirty == true)
    }

    @Test("TabManager convert line endings same format is no-op")
    func tabManagerConvertSameLineEndings() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.swift")
        try? "hello\nworld\n".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        let originalContent = manager.activeTab?.content

        manager.convertActiveTabLineEndings(to: .lf)
        #expect(manager.activeTab?.content == originalContent)
        #expect(manager.activeTab?.isDirty == false)
    }

    // MARK: - Indentation detection

    @Test("Detect spaces indentation")
    func detectSpaces() {
        let content = "func foo() {\n    let x = 1\n    let y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .spaces(4))
    }

    @Test("Detect tab indentation")
    func detectTabs() {
        let content = "func foo() {\n\tlet x = 1\n\tlet y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .tabs)
    }

    @Test("Detect 2-space indentation")
    func detectTwoSpaces() {
        let content = "func foo() {\n  let x = 1\n  let y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .spaces(2))
    }

    @Test("Empty content defaults to spaces 4")
    func detectIndentationEmpty() {
        let indent = IndentationStyle.detect(in: "")
        #expect(indent == .spaces(4))
    }

    @Test("No indentation defaults to spaces 4")
    func detectNoIndentation() {
        let indent = IndentationStyle.detect(in: "hello\nworld")
        #expect(indent == .spaces(4))
    }

    @Test("IndentationStyle display names")
    func indentationDisplayName() {
        #expect(IndentationStyle.spaces(4).displayName == "Spaces: 4")
        #expect(IndentationStyle.spaces(2).displayName == "Spaces: 2")
        #expect(IndentationStyle.tabs.displayName == "Tabs")
    }

    // MARK: - File size formatting

    @Test("Format bytes")
    func formatBytes() {
        #expect(FileSizeFormatter.format(500) == "500 B")
    }

    @Test("Format kilobytes")
    func formatKB() {
        #expect(FileSizeFormatter.format(1_536) == "1.5 KB")
    }

    @Test("Format megabytes")
    func formatMB() {
        #expect(FileSizeFormatter.format(2_621_440) == "2.5 MB")
    }

    @Test("Format zero bytes")
    func formatZero() {
        #expect(FileSizeFormatter.format(0) == "0 B")
    }

    @Test("Format exactly 1 KB")
    func formatExactKB() {
        #expect(FileSizeFormatter.format(1_024) == "1.0 KB")
    }

    // MARK: - EditorTab cached values

    @Test("EditorTab caches indentation and line ending after recompute")
    func editorTabCaching() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "func foo() {\n    let x = 1\n}\n",
            savedContent: ""
        )
        tab.recomputeContentCaches()
        #expect(tab.cachedIndentation == .spaces(4))
        #expect(tab.cachedLineEnding == .lf)
    }

    @Test("EditorTab recomputes cache on content change")
    func editorTabCacheInvalidation() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.swift"),
            content: "func foo() {\n    let x = 1\n}\n",
            savedContent: ""
        )
        tab.recomputeContentCaches()
        #expect(tab.cachedIndentation == .spaces(4))
        // Change content to use tabs and recompute
        tab.content = "func foo() {\n\tlet x = 1\n}\n"
        tab.recomputeContentCaches()
        #expect(tab.cachedIndentation == .tabs)
    }

    @Test("TabManager.updateEditorState computes line and column")
    func tabManagerCursorUpdate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.swift")
        try? "hello\nworld".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        // Position 8 = "wo" on second line → Ln 2, Col 3
        manager.updateEditorState(cursorPosition: 8, scrollOffset: 0)
        #expect(manager.activeTab?.cursorLine == 2)
        #expect(manager.activeTab?.cursorColumn == 3)
    }
}
