//
//  EditorTabTests.swift
//  PineTests
//
//  Tests for EditorTab model properties and behavior.
//

import Foundation
import Testing

@testable import Pine

@Suite("EditorTab Tests")
@MainActor
struct EditorTabTests {

    // MARK: - contentVersion

    @Test("contentVersion starts at zero for new tab")
    func contentVersionInitialValue() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "hello")
        // didSet is not called during init in Swift structs
        #expect(tab.contentVersion == 0)
    }

    @Test("contentVersion increments on every content mutation")
    func contentVersionIncrementsOnMutation() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "")
        #expect(tab.contentVersion == 0)

        tab.content = "first"
        #expect(tab.contentVersion == 1)

        tab.content = "second"
        #expect(tab.contentVersion == 2)

        tab.content = "third"
        #expect(tab.contentVersion == 3)
    }

    @Test("contentVersion increments even when setting same content")
    func contentVersionIncrementsForSameContent() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "same")

        tab.content = "same"
        #expect(tab.contentVersion == 1)

        tab.content = "same"
        #expect(tab.contentVersion == 2)
    }

    @Test("contentVersion uses wrapping addition and does not overflow")
    func contentVersionWrappingAddition() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "")
        for i in 0..<100 {
            tab.content = "iteration \(i)"
        }
        #expect(tab.contentVersion == 100)
    }

    // MARK: - Basic properties

    @Test("isDirty returns true when content differs from savedContent")
    func isDirtyWhenContentDiffers() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "original", savedContent: "original")
        #expect(tab.isDirty == false)

        tab.content = "modified"
        #expect(tab.isDirty == true)
    }

    @Test("isDirty returns false for preview tabs even with different content")
    func isDirtyFalseForPreview() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            content: "content",
            savedContent: "different",
            kind: .preview
        )
        #expect(tab.isDirty == false)

        tab.content = "modified"
        #expect(tab.isDirty == false)
    }

    @Test("fileName returns last path component")
    func fileName() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/path/to/file.swift"))
        #expect(tab.fileName == "file.swift")
    }

    @Test("language returns file extension lowercased")
    func language() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/path/to/File.Swift"))
        #expect(tab.language == "swift")
    }

    @Test("isMarkdownFile returns true for .md and .markdown extensions")
    func isMarkdownFile() {
        let mdTab = EditorTab(url: URL(fileURLWithPath: "/path/README.md"))
        let markdownTab = EditorTab(url: URL(fileURLWithPath: "/path/notes.markdown"))
        let swiftTab = EditorTab(url: URL(fileURLWithPath: "/path/code.swift"))

        #expect(mdTab.isMarkdownFile == true)
        #expect(markdownTab.isMarkdownFile == true)
        #expect(swiftTab.isMarkdownFile == false)
    }

    @Test("Equality is based on id only")
    func equalityById() {
        let tab1 = EditorTab(url: URL(fileURLWithPath: "/tmp/a.txt"), content: "hello")
        var tab2 = tab1
        tab2.content = "different"

        #expect(tab1 == tab2) // Same id despite different content
    }
}
