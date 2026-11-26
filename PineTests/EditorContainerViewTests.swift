//
//  EditorContainerViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for EditorContainerView layout behavior.
@Suite("EditorContainerView Layout Tests")
@MainActor
struct EditorContainerViewTests {

    @Test func layoutScrollViewFillsFullWidth() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))

        let scrollView = NSScrollView(frame: .zero)
        container.addSubview(scrollView)

        container.layout()

        #expect(scrollView.frame.width == 1000)
    }

    // MARK: - Layout with line number view

    @Test func layoutPositionsLineNumberView() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))

        let scrollView = NSScrollView(frame: .zero)
        container.addSubview(scrollView)

        let textView = NSTextView(frame: .zero)
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 600)
        container.addSubview(lineNumberView)

        container.layout()

        #expect(lineNumberView.frame.width == 40)
        #expect(lineNumberView.frame.height == 600)
    }
}
