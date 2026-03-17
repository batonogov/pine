//
//  MarkdownRenderer.swift
//  Pine
//

import AppKit
import Markdown

/// Renders Markdown text into an `NSAttributedString` using Apple's swift-markdown parser.
/// Uses system colors for automatic light/dark mode support.
final class MarkdownRenderer {

    // MARK: - Font configuration

    private static let bodySize: CGFloat = 15
    private static let codeSize: CGFloat = 13
    private static let h1Size: CGFloat = 28
    private static let h2Size: CGFloat = 24
    private static let h3Size: CGFloat = 20
    private static let h4Size: CGFloat = 17

    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let boldFont = NSFont.boldSystemFont(ofSize: bodySize)
    static let italicFont = NSFont.systemFont(ofSize: bodySize).withTraits(.italicFontMask)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)

    static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = h1Size
        case 2: size = h2Size
        case 3: size = h3Size
        default: size = h4Size
        }
        return NSFont.boldSystemFont(ofSize: size)
    }

    // MARK: - Render

    func render(_ markdown: String) -> NSAttributedString {
        let document = Document(parsing: markdown)
        var builder = AttributedStringBuilder()
        return builder.visit(document)
    }
}

// MARK: - NSFont helper

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits(rawValue: UInt32(traits.rawValue)))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - AttributedStringBuilder

/// URL schemes allowed in Markdown preview links.
private let allowedLinkSchemes: Set<String> = ["https", "http", "mailto"]

private struct AttributedStringBuilder: MarkupVisitor {
    typealias Result = NSAttributedString

    private var listDepth = 0
    private var orderedListCounters: [Int] = []
    private var isFirstBlock = true

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return [
            .font: MarkdownRenderer.bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
    }

    // MARK: - Default

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    // MARK: - Document

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in document.children {
            result.append(visit(child))
        }
        return result
    }

    // MARK: - Block-level spacing

    private mutating func blockPrefix() -> String {
        if isFirstBlock {
            isFirstBlock = false
            return ""
        }
        return "\n\n"
    }

    // MARK: - Heading

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let prefix = blockPrefix()
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }

        let font = MarkdownRenderer.headingFont(level: heading.level)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacingBefore = 8

        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]

        for child in heading.children {
            let childStr = visitInline(child)
            let mutable = NSMutableAttributedString(attributedString: childStr)
            mutable.addAttributes(headingAttrs, range: NSRange(location: 0, length: mutable.length))
            result.append(mutable)
        }

        return result
    }

    // MARK: - Paragraph

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let prefix = blockPrefix()
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }

        for child in paragraph.children {
            result.append(visitInline(child))
        }

        // Apply paragraph style only — don't override inline fonts/colors
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let contentRange = NSRange(location: prefix.count, length: result.length - prefix.count)
        result.addAttribute(.paragraphStyle, value: style, range: contentRange)

        return result
    }

    // MARK: - Inline visitors

    private mutating func visitInline(_ markup: any Markup) -> NSAttributedString {
        visit(markup)
    }

    // MARK: - Text

    mutating func visitText(_ text: Text) -> NSAttributedString {
        NSAttributedString(string: text.string, attributes: bodyAttributes())
    }

    // MARK: - Strong (bold)

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in strong.children {
            result.append(visitInline(child))
        }
        result.addAttribute(.font, value: MarkdownRenderer.boldFont,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Emphasis (italic)

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in emphasis.children {
            result.append(visitInline(child))
        }
        result.addAttribute(.font, value: MarkdownRenderer.italicFont,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Inline code

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MarkdownRenderer.codeFont,
            .foregroundColor: NSColor.systemPink,
            .backgroundColor: NSColor.quaternaryLabelColor
        ]
        return NSAttributedString(string: inlineCode.code, attributes: attrs)
    }

    // MARK: - Code block

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        let prefix = blockPrefix()
        let code = codeBlock.code.hasSuffix("\n")
            ? String(codeBlock.code.dropLast())
            : codeBlock.code

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.tailIndent = -16

        let attrs: [NSAttributedString.Key: Any] = [
            .font: MarkdownRenderer.codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.quaternaryLabelColor,
            .paragraphStyle: style
        ]

        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }
        result.append(NSAttributedString(string: code, attributes: attrs))
        return result
    }

    // MARK: - Link

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in link.children {
            result.append(visitInline(child))
        }
        let range = NSRange(location: 0, length: result.length)

        if let dest = link.destination,
           let url = URL(string: dest),
           let scheme = url.scheme?.lowercased(),
           allowedLinkSchemes.contains(scheme) {
            result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            result.addAttribute(.link, value: url, range: range)
        }
        return result
    }

    // MARK: - Unordered list

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> NSAttributedString {
        let prefix = listDepth == 0 ? blockPrefix() : ""
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }

        listDepth += 1
        for (index, item) in unorderedList.listItems.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let indent = String(repeating: "    ", count: listDepth - 1)
            let bullet: String
            if let checkbox = item.checkbox {
                bullet = checkbox == .checked ? "\(indent)  \u{2611} " : "\(indent)  \u{2610} "
            } else {
                bullet = "\(indent)  \u{2022} "
            }
            result.append(NSAttributedString(string: bullet, attributes: bodyAttributes()))
            result.append(visitListItemContent(item))
        }
        listDepth -= 1

        return result
    }

    // MARK: - Ordered list

    mutating func visitOrderedList(_ orderedList: OrderedList) -> NSAttributedString {
        let prefix = listDepth == 0 ? blockPrefix() : ""
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }

        listDepth += 1
        for (index, item) in orderedList.listItems.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let indent = String(repeating: "    ", count: listDepth - 1)
            let number = "\(indent)  \(index + 1). "
            result.append(NSAttributedString(string: number, attributes: bodyAttributes()))
            result.append(visitListItemContent(item))
        }
        listDepth -= 1

        return result
    }

    // MARK: - List item content

    private mutating func visitListItemContent(_ item: ListItem) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Save/restore isFirstBlock so list items don't add extra spacing
        let saved = isFirstBlock
        isFirstBlock = true
        for child in item.children {
            if let para = child as? Paragraph {
                // Inline paragraph content without extra newlines
                for inline in para.children {
                    result.append(visitInline(inline))
                }
            } else {
                result.append(visit(child))
            }
        }
        isFirstBlock = saved
        return result
    }

    // MARK: - Blockquote

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let prefix = blockPrefix()
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }

        let saved = isFirstBlock
        isFirstBlock = true
        let inner = NSMutableAttributedString()
        for child in blockQuote.children {
            inner.append(visit(child))
        }
        isFirstBlock = saved

        let range = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)

        let style = NSMutableParagraphStyle()
        style.headIndent = 20
        style.firstLineHeadIndent = 20
        style.lineSpacing = 4
        inner.addAttribute(.paragraphStyle, value: style, range: range)

        result.append(inner)
        return result
    }

    // MARK: - Strikethrough

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in strikethrough.children {
            result.append(visitInline(child))
        }
        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Thematic break (horizontal rule)

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        let prefix = blockPrefix()
        let rule = String(repeating: "\u{2500}", count: 20)
        let line = "\n\(rule)\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.separatorColor,
            .font: MarkdownRenderer.bodyFont
        ]
        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix))
        }
        result.append(NSAttributedString(string: line, attributes: attrs))
        return result
    }

    // MARK: - Soft/hard break

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        NSAttributedString(string: " ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\n")
    }

    // MARK: - Image (show alt text)

    mutating func visitImage(_ image: Image) -> NSAttributedString {
        let altText = image.plainText.isEmpty ? "[image]" : "[\(image.plainText)]"
        return NSAttributedString(string: altText, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: MarkdownRenderer.italicFont
        ])
    }
}
