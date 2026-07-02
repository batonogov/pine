//
//  HoverMarkdownRenderer.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  Converts LSP hover content (Markdown or plain text) into an
//  NSAttributedString for display in the hover popover.
//
//  Uses a lightweight Markdown parser that handles the common cases in LSP
//  hover responses: code blocks (```...```), inline code (`code`), bold
//  (**text**), headings (# Title), and plain text lines. Full Markdown AST
//  rendering (via swift-markdown) is available but deliberately not used
//  here to keep the popover rendering synchronous and dependency-free — LSP
//  hover responses are typically short and structured.
//
//  `nonisolated` because the rendering is pure data work — no actor surface.
//

import AppKit

/// Pure rendering of LSP hover content into NSAttributedString.
///
/// `nonisolated` because it is pure data work invoked from the main-actor UI
/// path; it holds no state.
nonisolated enum HoverMarkdownRenderer {

    /// Font/color configuration for rendering hover content.
    private struct Style {
        let font: NSFont
        let boldFont: NSFont
        let codeFont: NSFont
        let headingFont: NSFont
        let textColor: NSColor
        let secondaryTextColor: NSColor
        let codeBackgroundColor: NSColor
    }

    /// Renders `content` into an attributed string for the hover popover.
    ///
    /// - Parameters:
    ///   - content: The hover text from the LSP server.
    ///   - isMarkdown: Whether the content is Markdown (parsed) or plain
    ///     text (shown verbatim in monospaced font).
    static func render(_ content: String, isMarkdown: Bool) -> NSAttributedString {
        let style = Style(
            font: NSFont.systemFont(ofSize: 12),
            boldFont: NSFont.boldSystemFont(ofSize: 12),
            codeFont: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            headingFont: NSFont.boldSystemFont(ofSize: 13),
            textColor: NSColor.labelColor,
            secondaryTextColor: NSColor.secondaryLabelColor,
            codeBackgroundColor: NSColor.textBackgroundColor
        )

        if isMarkdown {
            return parseMarkdown(content, style: style)
        } else {
            // Plain text — show verbatim in monospaced font.
            let attr = NSMutableAttributedString(string: content)
            let fullRange = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.font, value: style.codeFont, range: fullRange)
            attr.addAttribute(.foregroundColor, value: style.textColor, range: fullRange)
            return attr
        }
    }

    // MARK: - Markdown parsing

    /// A lightweight Markdown parser handling the subset commonly seen in
    /// LSP hover responses.
    ///
    /// Supports:
    ///   - Fenced code blocks: ```lang\ncode\n```
    ///   - Headings: # H1, ## H2, ### H3
    ///   - Bold: **text**
    ///   - Inline code: `code`
    ///   - Separator lines: ---
    private static func parseMarkdown(
        _ markdown: String,
        style: Style
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let blockLine = lines[i]
                    if blockLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(blockLine)
                    i += 1
                }
                if !codeLines.isEmpty {
                    let code = codeLines.joined(separator: "\n") + "\n"
                    let attr = NSMutableAttributedString(string: code)
                    let fullRange = NSRange(location: 0, length: attr.length)
                    attr.addAttribute(.font, value: style.codeFont, range: fullRange)
                    attr.addAttribute(.foregroundColor, value: style.textColor, range: fullRange)
                    attr.addAttribute(.backgroundColor, value: style.codeBackgroundColor, range: fullRange)
                    result.append(attr)
                }
                continue
            }

            // Heading.
            if let headingLevel = parseHeadingLevel(line) {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    let attr = NSMutableAttributedString(string: title + "\n")
                    let fullRange = NSRange(location: 0, length: attr.length)
                    attr.addAttribute(.font, value: style.headingFont, range: fullRange)
                    attr.addAttribute(.foregroundColor, value: style.textColor, range: fullRange)
                    result.append(attr)
                }
                i += 1
                _ = headingLevel // accepted
                continue
            }

            // Horizontal rule.
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let sep = String(repeating: "\u{2014}", count: 40) + "\n"
                let attr = NSMutableAttributedString(string: sep)
                let fullRange = NSRange(location: 0, length: attr.length)
                attr.addAttribute(.font, value: style.font, range: fullRange)
                attr.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: fullRange)
                result.append(attr)
                i += 1
                continue
            }

            // Regular line — parse inline formatting.
            let lineAttr = parseInlineFormatting(
                line + "\n",
                style: style
            )
            result.append(lineAttr)
            i += 1
        }

        return result
    }

    /// Parses the heading level from a line (1–6), or `nil` when it's not a
    /// heading.
    private static func parseHeadingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" {
                count += 1
            } else if ch.isWhitespace {
                break
            } else {
                return nil
            }
        }
        return (1...6).contains(count) ? count : nil
    }

    /// Parses inline formatting: **bold** and `code`.
    private static func parseInlineFormatting(
        _ text: String,
        style: Style
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var current = ""
        let chars = Array(text)

        var i = 0
        while i < chars.count {
            // Inline code: `...`
            if chars[i] == "`" {
                // Flush current text first.
                flush(
                    current,
                    into: result,
                    font: style.font,
                    color: style.textColor
                )
                current = ""

                // Find closing backtick.
                var j = i + 1
                var codeContent = ""
                while j < chars.count && chars[j] != "`" {
                    codeContent.append(chars[j])
                    j += 1
                }
                if j < chars.count {
                    // Found closing backtick.
                    let attr = NSAttributedString(string: codeContent, attributes: [
                        .font: style.codeFont,
                        .foregroundColor: style.textColor,
                        .backgroundColor: style.codeBackgroundColor
                    ])
                    result.append(attr)
                    i = j + 1
                    continue
                } else {
                    // No closing backtick — treat as literal.
                    current.append("`")
                    current.append(contentsOf: codeContent)
                    i = j
                    continue
                }
            }

            // Bold: **...**
            if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                // Find closing **.
                var j = i + 2
                var boldContent = ""
                while j < chars.count {
                    if chars[j] == "*" && j + 1 < chars.count && chars[j + 1] == "*" {
                        break
                    }
                    boldContent.append(chars[j])
                    j += 1
                }
                if j < chars.count {
                    // Flush current text first.
                    flush(current, into: result, font: style.font, color: style.textColor)
                    current = ""

                    // Found closing **.
                    let attr = NSAttributedString(string: boldContent, attributes: [
                        .font: style.boldFont,
                        .foregroundColor: style.textColor
                    ])
                    result.append(attr)
                    i = j + 2
                    continue
                }
            }

            current.append(chars[i])
            i += 1
        }

        flush(current, into: result, font: style.font, color: style.textColor)
        return result
    }

    /// Appends `text` to `result` with `font` and `color` if non-empty.
    private static func flush(
        _ text: String,
        into result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor
    ) {
        guard !text.isEmpty else { return }
        result.append(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ]))
    }
}
