//
//  HoverMarkdownRendererTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@Suite("HoverMarkdownRenderer")
@MainActor
struct HoverMarkdownRendererTests {

    @Test func rendersPlainTextVerbatimWithMonospacedStyle() {
        let content = "func pine() -> Bool"

        let result = HoverMarkdownRenderer.render(content, isMarkdown: false)

        #expect(result.string == content)
        #expect(font(at: 0, in: result) == NSFont.monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        ))
        #expect(foregroundColor(at: 0, in: result) == NSColor.labelColor)
        #expect(backgroundColor(at: 0, in: result) == nil)
    }

    @Test func rendersCommonMarkdownConstructsWithExpectedStyles() {
        let markdown = """
        ## Signature
        ---
          ```swift
        func pine() -> Bool
          ```
        Use **safe** and `fast`.
        """

        let result = HoverMarkdownRenderer.render(markdown, isMarkdown: true)

        let separator = String(repeating: "\u{2014}", count: 40)
        #expect(result.string == """
        Signature
        \(separator)
        func pine() -> Bool
        Use safe and fast.

        """)

        let headingOffset = offset(of: "Signature", in: result)
        #expect(font(at: headingOffset, in: result) == NSFont.boldSystemFont(ofSize: 13))
        #expect(foregroundColor(at: headingOffset, in: result) == NSColor.labelColor)

        let separatorOffset = offset(of: separator, in: result)
        #expect(font(at: separatorOffset, in: result) == NSFont.systemFont(ofSize: 12))
        #expect(foregroundColor(at: separatorOffset, in: result) == NSColor.secondaryLabelColor)

        let blockOffset = offset(of: "func pine", in: result)
        assertCodeStyle(at: blockOffset, in: result)

        let bodyOffset = offset(of: "Use ", in: result)
        #expect(font(at: bodyOffset, in: result) == NSFont.systemFont(ofSize: 12))
        #expect(foregroundColor(at: bodyOffset, in: result) == NSColor.labelColor)

        let boldOffset = offset(of: "safe", in: result)
        #expect(font(at: boldOffset, in: result) == NSFont.boldSystemFont(ofSize: 12))
        #expect(foregroundColor(at: boldOffset, in: result) == NSColor.labelColor)

        let inlineCodeOffset = offset(of: "fast", in: result)
        assertCodeStyle(at: inlineCodeOffset, in: result)
    }

    @Test func handlesEmptyAndUnterminatedFencedCodeBlocks() {
        let empty = HoverMarkdownRenderer.render(
            "  ```swift\n  ```",
            isMarkdown: true
        )
        #expect(empty.length == 0)

        let unterminated = HoverMarkdownRenderer.render(
            "```swift\nlet value = 1\nreturn value",
            isMarkdown: true
        )
        #expect(unterminated.string == "let value = 1\nreturn value\n")
        assertCodeStyle(at: offset(of: "let value", in: unterminated), in: unterminated)
        assertCodeStyle(at: offset(of: "return value", in: unterminated), in: unterminated)
    }

    @Test func preservesUnmatchedInlineMarkupAsLiteralText() {
        let result = HoverMarkdownRenderer.render(
            "`closed` then `open\n**still open",
            isMarkdown: true
        )

        #expect(result.string == "closed then `open\n**still open\n")
        assertCodeStyle(at: offset(of: "closed", in: result), in: result)

        let backtickOffset = offset(of: "`open", in: result)
        #expect(font(at: backtickOffset, in: result) == NSFont.systemFont(ofSize: 12))
        #expect(backgroundColor(at: backtickOffset, in: result) == nil)

        let unmatchedBoldOffset = offset(of: "**still open", in: result)
        #expect(font(at: unmatchedBoldOffset, in: result) == NSFont.systemFont(ofSize: 12))
        #expect(backgroundColor(at: unmatchedBoldOffset, in: result) == nil)
    }

    @Test func acceptsOnlyHeadingLevelsOneThroughSixWithRequiredSpacing() {
        let result = HoverMarkdownRenderer.render(
            "#\n###### Six\n####### Seven\n##NoSpace\n # Indented",
            isMarkdown: true
        )

        #expect(result.string == "Six\n####### Seven\n##NoSpace\n # Indented\n")

        let validHeadingOffset = offset(of: "Six", in: result)
        #expect(font(at: validHeadingOffset, in: result) == NSFont.boldSystemFont(ofSize: 13))

        for literal in ["####### Seven", "##NoSpace", "# Indented"] {
            let literalOffset = offset(of: literal, in: result)
            #expect(font(at: literalOffset, in: result) == NSFont.systemFont(ofSize: 12))
        }
    }

    private func assertCodeStyle(
        at offset: Int,
        in result: NSAttributedString
    ) {
        #expect(font(at: offset, in: result) == NSFont.monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        ))
        #expect(foregroundColor(at: offset, in: result) == NSColor.labelColor)
        #expect(backgroundColor(at: offset, in: result) == NSColor.textBackgroundColor)
    }

    private func offset(
        of substring: String,
        in result: NSAttributedString
    ) -> Int {
        let range = (result.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            Issue.record("Expected rendered output to contain '\(substring)'")
            return 0
        }
        return range.location
    }

    private func font(
        at offset: Int,
        in result: NSAttributedString
    ) -> NSFont? {
        result.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    }

    private func foregroundColor(
        at offset: Int,
        in result: NSAttributedString
    ) -> NSColor? {
        result.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    private func backgroundColor(
        at offset: Int,
        in result: NSAttributedString
    ) -> NSColor? {
        result.attribute(.backgroundColor, at: offset, effectiveRange: nil) as? NSColor
    }
}
