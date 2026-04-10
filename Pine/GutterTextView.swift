//
//  GutterTextView.swift
//  Pine
//
//  Extracted from CodeEditorView.swift on 2026-04-09 as part of the
//  refactor that split the 2186-LOC monolith into focused files (issue #755).
//
//  This file owns the NSTextView subclass used by the code editor:
//    • Left gutter inset for the line-number view
//    • Current-line highlight
//    • Indent guides
//    • Inline diff overlay (added/deleted line rendering)
//    • Inline blame annotation
//    • Auto-indent on newline
//    • Escape-to-collapse for expanded diff hunks
//    • Comment toggling
//
//  All rendering and behavior is byte-for-byte identical to the previous
//  implementation — only the enclosing file changed.
//

import SwiftUI
import AppKit

// MARK: - NSTextView с отступом слева для номеров строк

/// Подкласс NSTextView, который сдвигает текстовый контейнер вправо,
/// освобождая место для гуттера с номерами строк.
/// textContainerOrigin смещает текст только слева, не затрагивая правый край.
final class GutterTextView: NSTextView {
    /// Ширина гуттера — задаётся извне.
    var gutterInset: CGFloat = 44

    /// Indentation style for indent guide rendering.
    var indentStyle: IndentationStyle = .spaces(4)

    /// Bottom padding so the last line is not clipped (issue #258).
    static let defaultBottomInset: CGFloat = 5

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        textContainerInset = NSSize(width: 0, height: Self.defaultBottomInset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var textContainerOrigin: NSPoint {
        // Сдвигаем текст вправо на ширину гуттера, вниз на 8pt для отступа сверху
        NSPoint(x: gutterInset, y: 8)
    }

    // MARK: - Inline diff highlight

    /// Set of 1-based line numbers that are added in the current diff (green background).
    var addedLineNumbers: Set<Int> = []

    /// Blocks of deleted lines to render as phantom text above the anchor line (red background).
    var deletedLineBlocks: [DeletedLinesBlock] = []

    /// The diff hunks for the current file — used to filter highlights to the expanded hunk only.
    var diffHunksForHighlight: [DiffHunk] = []

    /// The ID of the currently expanded hunk (shows inline diff). Nil = all collapsed.
    var expandedHunkID: UUID? {
        didSet { needsDisplay = true }
    }

    /// Subtle green tint for added lines.
    private static let addedLineColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.systemGreen.withAlphaComponent(0.08)
        } else {
            return NSColor.systemGreen.withAlphaComponent(0.10)
        }
    }

    /// Red tint for deleted lines (phantom blocks) — more visible for clarity.
    private static let deletedLineColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.systemRed.withAlphaComponent(0.12)
        } else {
            return NSColor.systemRed.withAlphaComponent(0.14)
        }
    }

    /// Font for rendering deleted (phantom) lines — derived from the editor's current font size.
    private var deletedLineFont: NSFont {
        let size = font?.pointSize ?? 12
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Text color for deleted phantom lines (dimmed, readable on red background).
    private static let deletedLineTextColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.55)
        } else {
            return NSColor.black.withAlphaComponent(0.50)
        }
    }

    /// Separator line between deleted phantom block and editor content (adaptive).
    private static let deletedSeparatorColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.systemRed.withAlphaComponent(0.3)
        } else {
            return NSColor.systemRed.withAlphaComponent(0.25)
        }
    }

    // MARK: - Highlight current line

    private let currentLineColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.06)
        } else {
            return NSColor.black.withAlphaComponent(0.06)
        }
    }

    /// Blame lookup: line number → GitBlameLine (O(1) access).
    private(set) var blameLookup: [Int: GitBlameLine] = [:]
    /// Previous blame data count — avoids rebuilding the dictionary on every updateNSView.
    private(set) var blameLineCount: Int = -1
    var isBlameVisible: Bool = false

    /// Sets blame data and rebuilds O(1) lookup dictionary.
    func setBlameLines(_ lines: [GitBlameLine]) {
        guard lines.count != blameLineCount || lines.first != blameLookup[lines.first?.finalLine ?? 0] else {
            return
        }
        blameLineCount = lines.count
        blameLookup = Dictionary(lines.map { ($0.finalLine, $0) }, uniquingKeysWith: { _, last in last })
        if isBlameVisible { display() }
    }

    private static let blameFont: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: 12, weight: .regular)
            .fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 12) ?? NSFont.systemFont(ofSize: 12)
    }()
    private static let blameColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.3)
        } else {
            return NSColor.black.withAlphaComponent(0.3)
        }
    }

    private static let blameIcon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .light)
        return NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?
            .pine_tinted(with: blameColor)
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        // ── Indent guides (behind everything else) ──
        IndentGuideRenderer.draw(in: self, dirtyRect: rect, indentStyle: indentStyle)

        // ── Inline diff: only shown when a hunk is expanded via gutter click ──
        if let expandedID = expandedHunkID,
           let expandedHunk = diffHunksForHighlight.first(where: { $0.id == expandedID }) {
            drawInlineDiffHighlights(
                in: rect,
                layoutManager: layoutManager,
                textContainer: textContainer,
                expandedHunk: expandedHunk
            )
        }

        let cursorRange = selectedRange()
        guard cursorRange.length == 0 else { return }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: cursorRange.location)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y

        currentLineColor.setFill()
        lineRect.fill()

        // ── Inline blame annotation ──
        if isBlameVisible, !blameLookup.isEmpty {
            drawInlineBlame(lineRect: lineRect, layoutManager: layoutManager)
        }
    }

    // MARK: - Inline diff drawing

    /// Draws green background highlights on added lines and red phantom blocks for deleted lines.
    /// Only draws highlights for the given expanded hunk.
    private func drawInlineDiffHighlights(
        in rect: NSRect,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        expandedHunk: DiffHunk
    ) {
        guard let scrollView = enclosingScrollView else { return }
        let visibleRect = scrollView.contentView.bounds
        let source = string as NSString
        guard source.length > 0 else { return }

        let originY = textContainerOrigin.y

        // Get visible glyph range
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        guard visibleGlyphRange.location != NSNotFound else { return }

        // Count the line number of the first visible character
        let firstVisibleCharIndex = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )
        var lineNumber = 1
        for i in 0..<firstVisibleCharIndex where source.character(at: i) == ASCII.newline {
            lineNumber += 1
        }

        // Filter to only the expanded hunk's added lines and deleted blocks
        let hunkAddedLines = InlineDiffProvider.addedLineNumbers(from: [expandedHunk])
        let hunkDeletedBlocks = InlineDiffProvider.deletedLineBlocks(from: [expandedHunk])

        // Build lookup: anchor line → array of deleted blocks
        let deletedAnchorSet = Set(hunkDeletedBlocks.map(\.anchorLine))
        var deletedAnchorMap: [Int: [DeletedLinesBlock]] = [:]
        for block in hunkDeletedBlocks {
            deletedAnchorMap[block.anchorLine, default: []].append(block)
        }

        // Enumerate visible line fragments to draw highlights
        var previousLineCharIndex = -1

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { [self] lineRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

            // Determine if this is a new logical line
            let isNewLogicalLine: Bool
            if previousLineCharIndex < 0 {
                isNewLogicalLine = true
            } else if charIndex > previousLineCharIndex {
                let range = NSRange(location: previousLineCharIndex,
                                    length: charIndex - previousLineCharIndex)
                isNewLogicalLine = source.substring(with: range).contains("\n")
            } else {
                isNewLogicalLine = false
            }

            if isNewLogicalLine {
                let y = lineRect.origin.y + originY - visibleRect.origin.y

                // Draw deleted phantom blocks above this line if it's an anchor
                if deletedAnchorSet.contains(lineNumber), let blocks = deletedAnchorMap[lineNumber] {
                    var currentY = y
                    for block in blocks {
                        let blockHeight = CGFloat(block.lines.count) * lineRect.height
                        currentY -= blockHeight
                    }
                    // Draw blocks top-down so they stack correctly
                    var drawY = currentY
                    for block in blocks {
                        let blockHeight = CGFloat(block.lines.count) * lineRect.height
                        self.drawDeletedPhantomBlock(block, at: drawY + blockHeight, lineHeight: lineRect.height)
                        drawY += blockHeight
                    }
                }

                // Draw green background on added lines (only for expanded hunk)
                if hunkAddedLines.contains(lineNumber) {
                    var highlightRect = lineRect
                    highlightRect.origin.x = 0
                    highlightRect.size.width = self.bounds.width
                    highlightRect.origin.y = y
                    Self.addedLineColor.setFill()
                    highlightRect.fill()
                }

                lineNumber += 1
            }
            previousLineCharIndex = charIndex
        }
    }

    /// Draws a block of deleted phantom lines above the given Y position.
    /// Each deleted line is rendered with red background and dimmed red text.
    private func drawDeletedPhantomBlock(_ block: DeletedLinesBlock, at anchorY: CGFloat, lineHeight: CGFloat) {
        guard !block.lines.isEmpty else { return }

        let font = deletedLineFont
        let textColor = Self.deletedLineTextColor
        let bgColor = Self.deletedLineColor

        let lineCount = CGFloat(block.lines.count)
        let blockHeight = lineCount * lineHeight
        let blockY = anchorY - blockHeight

        // Draw background for the entire deleted block
        let bgRect = NSRect(x: 0, y: blockY, width: bounds.width, height: blockHeight)
        bgColor.setFill()
        bgRect.fill()

        // Draw each deleted line with text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        for (index, line) in block.lines.enumerated() {
            let lineY = blockY + CGFloat(index) * lineHeight
            let text = line as NSString
            let drawPoint = NSPoint(x: textContainerOrigin.x, y: lineY)
            text.draw(at: drawPoint, withAttributes: attrs)
        }

        // Draw a subtle separator line between deleted block and editor content
        let separatorY = anchorY
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: 0, y: separatorY))
        separatorPath.line(to: NSPoint(x: bounds.width, y: separatorY))
        separatorPath.lineWidth = 0.5
        Self.deletedSeparatorColor.setStroke()
        separatorPath.stroke()
    }

    /// Draws inline blame annotation after the line content on the cursor line.
    /// Computes line number directly from selectedRange() to stay in sync with
    /// the actual selection state during each draw call (no caching — drawBackground
    /// can be called multiple times per display cycle with different selection states).
    private func drawInlineBlame(lineRect: NSRect, layoutManager: NSLayoutManager) {
        let source = string as NSString
        guard source.length > 0, let container = textContainer else { return }

        let cursorLocation = min(selectedRange().location, source.length)

        // Compute 1-based line number from cursor position
        var lineNumber = 1
        for i in 0..<cursorLocation where source.character(at: i) == ASCII.newline {
            lineNumber += 1
        }

        guard let blame = blameLookup[lineNumber] else { return }

        // Find end of line content
        let lineRange = source.lineRange(for: NSRange(location: cursorLocation, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location && lineEnd <= source.length
            && source.character(at: lineEnd - 1) == ASCII.newline {
            lineEnd -= 1
        }

        // Get x position after the last character
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(lineEnd, lineRange.location))
        let lineEndX: CGFloat
        if lineEnd > lineRange.location {
            let charRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 0),
                in: container
            )
            lineEndX = charRect.maxX + textContainerOrigin.x
        } else {
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineEndX = usedRect.origin.x + textContainerOrigin.x
        }

        let text: String
        if blame.isUncommitted {
            text = "Uncommitted"
        } else {
            let relativeDate = Self.relativeDateFormatter.localizedString(
                for: blame.authorTime, relativeTo: Date()
            )
            text = "\(blame.author), \(relativeDate)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.blameFont,
            .foregroundColor: Self.blameColor
        ]

        let minBlameX = textContainerOrigin.x + gutterInset + 250
        var drawX = max(lineEndX + 24, minBlameX)
        let drawY = lineRect.origin.y + (lineRect.height - Self.blameFont.pointSize) / 2

        // Git branch icon (cached to avoid copy+tint on every draw)
        if let icon = Self.blameIcon {
            let iconY = lineRect.origin.y + (lineRect.height - icon.size.height) / 2
            icon.draw(
                in: NSRect(x: drawX, y: iconY, width: icon.size.width, height: icon.size.height),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil
            )
            drawX += icon.size.width + 4
        }

        (text as NSString).draw(at: NSPoint(x: drawX, y: drawY), withAttributes: attrs)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Mark full bounds dirty BEFORE super so its drawing pass erases the
        // old blame annotation in a single frame (no flicker).
        if isBlameVisible { setNeedsDisplay(bounds) }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    // MARK: - Toggle comment

    /// File extension for looking up the line comment prefix.
    var fileExtension: String?
    /// File name for looking up the line comment prefix (e.g. "Dockerfile").
    var exactFileName: String?

    func toggleComment() {
        guard let style = SyntaxHighlighter.shared.commentStyle(
            forExtension: fileExtension,
            fileName: exactFileName
        ) else { return }

        let currentRange = selectedRange()
        let result: CommentToggler.Result

        switch style {
        case .line(let prefix):
            result = CommentToggler.toggle(
                text: string,
                selectedRange: currentRange,
                lineComment: prefix
            )
        case .block(let open, let close):
            result = CommentToggler.toggleBlock(
                text: string,
                selectedRange: currentRange,
                open: open,
                close: close
            )
        }

        // Apply via replaceCharacters to support undo
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: fullRange, replacementString: result.newText) {
            replaceCharacters(in: fullRange, with: result.newText)
            didChangeText()
            setSelectedRange(result.newRange)
        }
    }

    // MARK: - Auto-indent

    /// Символы, после которых увеличиваем отступ
    private static let indentOpeners: Set<Character> = ["{", "(", ":"]
    /// Символы, перед которыми уменьшаем отступ
    private static let indentClosers: Set<Character> = ["}", ")"]

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let cursorLocation = selectedRange().location

        // Находим текущую строку
        let lineRange = source.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let currentLine = source.substring(with: lineRange)

        // Извлекаем ведущие пробелы/табы
        let leadingWhitespace = String(currentLine.prefix(while: { $0 == " " || $0 == "\t" }))

        // Проверяем последний непробельный символ перед курсором в текущей строке
        let textBeforeCursor = source.substring(with: NSRange(
            location: lineRange.location,
            length: cursorLocation - lineRange.location
        ))
        let lastNonSpace = textBeforeCursor.last(where: { !$0.isWhitespace })

        // Проверяем первый непробельный символ после курсора в текущей строке
        let textAfterCursor = source.substring(with: NSRange(
            location: cursorLocation,
            length: NSMaxRange(lineRange) - cursorLocation
        ))
        let firstNonSpaceAfter = textAfterCursor.first(where: { !$0.isWhitespace && $0 != "\n" })

        var indent = leadingWhitespace

        // Увеличиваем отступ после { ( :
        if let last = lastNonSpace, Self.indentOpeners.contains(last) {
            indent += "    "
        }

        // Если курсор между { и } — добавляем дополнительную строку с уменьшенным отступом
        if let last = lastNonSpace, let first = firstNonSpaceAfter,
           Self.indentOpeners.contains(last) && Self.indentClosers.contains(first) {
            let closingIndent = leadingWhitespace
            insertText("\n\(indent)\n\(closingIndent)", replacementRange: selectedRange())
            // Ставим курсор на среднюю строку (с увеличенным отступом)
            let newCursorPos = cursorLocation + 1 + indent.count
            setSelectedRange(NSRange(location: newCursorPos, length: 0))
            return
        }

        insertText("\n\(indent)", replacementRange: selectedRange())
    }

    // MARK: - Escape key collapses expanded inline diff

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, expandedHunkID != nil {
            // Escape key (keyCode 53) collapses expanded inline diff
            expandedHunkID = nil
            // Also collapse in the sibling LineNumberView
            if let container = enclosingScrollView?.superview as? EditorContainerView {
                for subview in container.subviews {
                    if let lineNumberView = subview as? LineNumberView {
                        lineNumberView.expandedHunkID = nil
                        break
                    }
                }
            }
            return
        }
        super.keyDown(with: event)
    }
}
