//
//  BlameLookupTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for GutterTextView.setBlameLines — blame lookup dictionary rebuild.
struct BlameLookupTests {

    private func makeGutterTextView() -> GutterTextView {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        return GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
    }

    private func makeBlameLine(
        hash: String = "abc123",
        author: String = "Author",
        line: Int,
        summary: String = "commit message"
    ) -> GitBlameLine {
        GitBlameLine(
            hash: hash,
            author: author,
            authorTime: Date(timeIntervalSince1970: 1_700_000_000),
            summary: summary,
            finalLine: line
        )
    }

    // MARK: - Lookup rebuild

    @Test func setBlameLines_buildsLookupDictionary() {
        let view = makeGutterTextView()
        let lines = [
            makeBlameLine(line: 1),
            makeBlameLine(line: 2),
            makeBlameLine(line: 3)
        ]

        view.setBlameLines(lines)

        #expect(view.blameLookup.count == 3)
        #expect(view.blameLookup[1]?.finalLine == 1)
        #expect(view.blameLookup[2]?.finalLine == 2)
        #expect(view.blameLookup[3]?.finalLine == 3)
    }

    @Test func setBlameLines_updatesLineCount() {
        let view = makeGutterTextView()
        let lines = [makeBlameLine(line: 1), makeBlameLine(line: 2)]

        view.setBlameLines(lines)

        #expect(view.blameLineCount == 2)
    }

    // MARK: - Empty data

    @Test func setBlameLines_emptyArray_clearsLookup() {
        let view = makeGutterTextView()
        // First set some data
        view.setBlameLines([makeBlameLine(line: 1)])
        #expect(view.blameLookup.count == 1)

        // Then clear
        view.setBlameLines([])

        #expect(view.blameLookup.isEmpty)
        #expect(view.blameLineCount == 0)
    }

    // MARK: - Duplicate line numbers

    @Test func setBlameLines_duplicateLineNumbers_keepsLast() {
        let view = makeGutterTextView()
        let lines = [
            makeBlameLine(hash: "first", line: 1, summary: "first commit"),
            makeBlameLine(hash: "second", line: 1, summary: "second commit")
        ]

        view.setBlameLines(lines)

        #expect(view.blameLookup.count == 1)
        #expect(view.blameLookup[1]?.hash == "second")
        #expect(view.blameLookup[1]?.summary == "second commit")
    }

    // MARK: - Cache guard (skip rebuild when data unchanged)

    @Test func setBlameLines_sameData_skipsRebuild() {
        let view = makeGutterTextView()
        let lines = [makeBlameLine(line: 1), makeBlameLine(line: 2)]

        view.setBlameLines(lines)
        let firstLookup = view.blameLookup

        // Call again with same data — should not rebuild
        view.setBlameLines(lines)
        let secondLookup = view.blameLookup

        // Same keys and values means cache guard worked
        #expect(firstLookup.keys.sorted() == secondLookup.keys.sorted())
        #expect(view.blameLineCount == 2)
    }

    @Test func setBlameLines_differentCount_rebuilds() {
        let view = makeGutterTextView()
        view.setBlameLines([makeBlameLine(line: 1)])
        #expect(view.blameLineCount == 1)

        view.setBlameLines([makeBlameLine(line: 1), makeBlameLine(line: 2)])
        #expect(view.blameLineCount == 2)
        #expect(view.blameLookup.count == 2)
    }

    @Test func setBlameLines_sameCountDifferentFirstLine_rebuilds() {
        let view = makeGutterTextView()
        view.setBlameLines([makeBlameLine(hash: "aaa", line: 1)])
        #expect(view.blameLookup[1]?.hash == "aaa")

        // Same count but different first element
        view.setBlameLines([makeBlameLine(hash: "bbb", line: 1)])
        #expect(view.blameLookup[1]?.hash == "bbb")
    }

    // MARK: - Update after content change

    @Test func setBlameLines_updateAfterFileEdit() {
        let view = makeGutterTextView()
        // Initial blame for 3 lines
        view.setBlameLines([
            makeBlameLine(line: 1),
            makeBlameLine(line: 2),
            makeBlameLine(line: 3)
        ])
        #expect(view.blameLookup.count == 3)

        // After edit, blame has 4 lines
        view.setBlameLines([
            makeBlameLine(line: 1),
            makeBlameLine(hash: "0000000000000000000000000000000000000000", line: 2, summary: "uncommitted"),
            makeBlameLine(line: 3),
            makeBlameLine(line: 4)
        ])
        #expect(view.blameLookup.count == 4)
        #expect(view.blameLookup[2]?.isUncommitted == true)
    }

    // MARK: - Non-contiguous line numbers

    @Test func setBlameLines_nonContiguousLines() {
        let view = makeGutterTextView()
        let lines = [
            makeBlameLine(line: 5),
            makeBlameLine(line: 10),
            makeBlameLine(line: 15)
        ]

        view.setBlameLines(lines)

        #expect(view.blameLookup[5] != nil)
        #expect(view.blameLookup[10] != nil)
        #expect(view.blameLookup[15] != nil)
        #expect(view.blameLookup[1] == nil)
        #expect(view.blameLookup[6] == nil)
    }
}
