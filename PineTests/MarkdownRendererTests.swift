//
//  MarkdownRendererTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {

    private let renderer = MarkdownRenderer()

    // MARK: - Headings

    @Test func rendersHeading1() {
        let result = renderer.render("# Hello")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 28)
    }

    @Test func rendersHeading2SmallerFont() {
        let result = renderer.render("## Sub")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 24)
    }

    @Test func rendersHeading3() {
        let result = renderer.render("### Sub sub")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 20)
    }

    // MARK: - Inline formatting

    @Test func rendersBold() {
        let result = renderer.render("**bold**")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == MarkdownRenderer.boldFont)
    }

    @Test func rendersItalic() {
        let result = renderer.render("*italic*")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == MarkdownRenderer.italicFont)
    }

    @Test func rendersInlineCode() {
        let result = renderer.render("`code`")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == MarkdownRenderer.codeFont)
        let bgColor = result.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(bgColor != nil)
    }

    // MARK: - Code block

    @Test func rendersCodeBlock() {
        let result = renderer.render("```\nlet x = 1\n```")
        #expect(result.string.contains("let x = 1"))
        guard let range = result.string.range(of: "let") else {
            Issue.record("Expected 'let' in rendered output")
            return
        }
        let offset = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let font = result.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    // MARK: - Lists

    @Test func rendersUnorderedList() {
        let result = renderer.render("- one\n- two")
        #expect(result.string.contains("\u{2022}"))
        #expect(result.string.contains("one"))
        #expect(result.string.contains("two"))
    }

    @Test func rendersOrderedList() {
        let result = renderer.render("1. first\n2. second")
        #expect(result.string.contains("1."))
        #expect(result.string.contains("2."))
        #expect(result.string.contains("first"))
    }

    // MARK: - Link

    @Test func rendersLink() {
        let result = renderer.render("[click](https://example.com)")
        #expect(result.string.contains("click"))
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemBlue)
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    // MARK: - Blockquote

    @Test func rendersBlockquote() {
        let result = renderer.render("> quoted text")
        #expect(result.string.contains("quoted text"))
        guard let range = result.string.range(of: "quoted") else {
            Issue.record("Expected 'quoted' in rendered output")
            return
        }
        let offset = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let color = result.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.secondaryLabelColor)
    }

    // MARK: - Strikethrough

    @Test func rendersStrikethrough() {
        let result = renderer.render("~~deleted~~")
        #expect(result.string.contains("deleted"))
        let strike = result.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        #expect(strike == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Task list

    @Test func rendersTaskList() {
        let result = renderer.render("- [ ] todo\n- [x] done")
        #expect(result.string.contains("\u{2610}")) // unchecked
        #expect(result.string.contains("\u{2611}")) // checked
    }

    // MARK: - Horizontal rule

    @Test func rendersHorizontalRule() {
        let result = renderer.render("---")
        #expect(result.string.contains("\u{2500}"))
    }

    // MARK: - Link scheme safety

    @Test func allowsHttpsLink() {
        let result = renderer.render("[site](https://example.com)")
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    @Test func allowsHttpLink() {
        let result = renderer.render("[site](http://example.com)")
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "http://example.com")
    }

    @Test func allowsMailtoLink() {
        let result = renderer.render("[email](mailto:user@example.com)")
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "mailto:user@example.com")
    }

    @Test func rejectsFileScheme() {
        let result = renderer.render("[hack](file:///etc/passwd)")
        #expect(result.string.contains("hack"))
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link == nil)
    }

    @Test func rejectsJavascriptScheme() {
        let result = renderer.render("[xss](javascript:alert(1))")
        #expect(result.string.contains("xss"))
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link == nil)
    }

    @Test func rejectsCustomScheme() {
        let result = renderer.render("[app](myapp://open)")
        #expect(result.string.contains("app"))
        let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link == nil)
    }

    @Test func rejectedSchemeRendersAsPlainText() {
        let result = renderer.render("[label](file:///tmp)")
        #expect(result.string.contains("label"))
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        // Should use body text color, not link blue
        #expect(color == NSColor.labelColor)
    }

    // MARK: - Edge cases

    @Test func emptyStringProducesEmptyResult() {
        let result = renderer.render("")
        #expect(result.length == 0)
    }

    @Test func plainTextRendersAsParagraph() {
        let result = renderer.render("just text")
        #expect(result.string.contains("just text"))
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == MarkdownRenderer.bodyFont)
    }

    @Test func usesSystemColors() {
        let result = renderer.render("hello")
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.labelColor)
    }
}
