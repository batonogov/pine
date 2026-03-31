//
//  MarkdownPreviewModeTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("MarkdownPreviewMode")
@MainActor
struct MarkdownPreviewModeTests {

    @Test func defaultIsSource() {
        let mode = MarkdownPreviewMode.source
        #expect(mode == .source)
    }

    @Test func cycleSourceSplitPreviewSource() {
        var mode = MarkdownPreviewMode.source
        mode = mode.next
        #expect(mode == .split)
        mode = mode.next
        #expect(mode == .preview)
        mode = mode.next
        #expect(mode == .source)
    }

    @Test func isCodable() throws {
        let original = MarkdownPreviewMode.preview
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MarkdownPreviewMode.self, from: data)
        #expect(decoded == original)
    }

    @Test func isMarkdownForMd() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/readme.md"))
        #expect(tab.isMarkdownFile == true)
    }

    @Test func isMarkdownForMarkdown() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/notes.markdown"))
        #expect(tab.isMarkdownFile == true)
    }

    @Test func isMarkdownForSwift() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/main.swift"))
        #expect(tab.isMarkdownFile == false)
    }

    @Test func isMarkdownForUppercaseMD() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/README.MD"))
        #expect(tab.isMarkdownFile == true)
    }
}
