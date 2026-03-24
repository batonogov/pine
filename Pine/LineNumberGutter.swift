//
//  LineNumberGutter.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import AppKit
import os

/// Отдельный NSView, который рисует номера строк.
/// Добавляется как subview NSScrollView и остаётся на месте при скролле.
final class LineNumberView: NSView {
    weak var textView: NSTextView?
    /// The clip view this gutter observes for scroll notifications.
    /// Stored explicitly to avoid relying on enclosingScrollView at notification time.
    private weak var observedClipView: NSClipView?

    var gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Vertical offset to align gutter number baseline with editor text baseline.
    var baselineOffset: CGFloat {
        editorFont.ascender - gutterFont.ascender
    }
    private let gutterTextColor = NSColor.secondaryLabelColor
    private let gutterBgColor = NSColor.controlBackgroundColor
    private let separatorColor = NSColor.separatorColor

    var gutterWidth: CGFloat = 40
    var lineDiffs: [GitLineDiff] = [] {
        didSet {
            rebuildDiffMap()
            needsDisplay = true
        }
    }

    /// Складываемые регионы для отрисовки disclosure triangles.
    var foldableRanges: [FoldableRange] = [] {
        didSet {
            rebuildFoldStartMap()
            needsDisplay = true
        }
    }

    /// Текущее состояние свёрнутых регионов.
    var foldState: FoldState = FoldState() {
        didSet { needsDisplay = true }
    }

    /// Callback при клике по fold indicator.
    var onFoldToggle: ((FoldableRange) -> Void)?

    /// Pre-indexed diff lookup: line number → kind (cached, rebuilt when lineDiffs changes)
    private var diffMap: [Int: GitLineDiff.Kind] = [:]

    /// Pre-indexed fold lookup: start line → FoldableRange.
    private var foldStartMap: [Int: FoldableRange] = [:]

    /// Whether the mouse is currently inside the gutter (for showing fold indicators).
    private var isMouseInside = false

    private func rebuildDiffMap() {
        diffMap = Dictionary(lineDiffs.map { ($0.line, $0.kind) }, uniquingKeysWith: { _, last in last })
    }

    private func rebuildFoldStartMap() {
        foldStartMap = Dictionary(foldableRanges.map { ($0.startLine, $0) }, uniquingKeysWith: { _, last in last })
    }

    #if DEBUG
    /// Counter for bounds-change notifications received — debug-only, for testability.
    var boundsChangeCount = 0
    #endif

    /// Cached total line count — updated on text change, not on every draw.
    private var cachedTotalLines = 1

    /// Cached digit width for gutter sizing — avoids measuring on every draw().
    private var cachedDigitWidth: CGFloat = 0
    /// The font used when cachedDigitWidth was measured.
    private var cachedDigitWidthFont: NSFont?

    // Diff marker colors
    private let addedColor = NSColor.systemGreen
    private let modifiedColor = NSColor.systemBlue
    private let deletedColor = NSColor.systemRed

    // Fold indicator colors
    private let foldIndicatorColor = NSColor.secondaryLabelColor

    override var isFlipped: Bool { true }

    init(textView: NSTextView, clipView: NSClipView? = nil) {
        self.textView = textView
        let resolvedClipView = clipView ?? textView.enclosingScrollView?.contentView
        self.observedClipView = resolvedClipView
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityIdentifier(AccessibilityID.lineNumberGutter)

        // Скролл — подписываемся на конкретный clipView (#465)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBoundsChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: resolvedClipView
        )
        // Изменение текста/фрейма
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )

        #if DEBUG
        if resolvedClipView == nil {
            Logger.editor.warning("LineNumberView: clipView is nil at init — scroll observer will not fire. Pass clipView explicitly.")
        }
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Гарантируем что clipView шлёт уведомления о скролле
        textView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        // Initialize cached line count from the current text
        recountTotalLines()
        // Tracking area for hover — fold indicators appear on hover
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Mouse tracking for fold indicators

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only handle clicks on the fold indicator area (left portion of gutter)
        let foldIndicatorWidth: CGFloat = 14
        guard point.x < foldIndicatorWidth else {
            super.mouseDown(with: event)
            return
        }

        // Find which line was clicked
        if let lineNumber = lineNumber(at: point),
           let foldable = foldStartMap[lineNumber] {
            onFoldToggle?(foldable)
        }
    }

    /// Cached line starts for O(log n) line number lookups in click handling.
    var lineStartsCache: LineStartsCache?

    /// Returns the line number (1-based) at the given point in view coordinates.
    private func lineNumber(at point: NSPoint) -> Int? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return nil }

        let visibleRect = scrollView.contentView.bounds
        let originY = textView.textContainerOrigin.y

        // Convert point to text container coordinates
        let textY = point.y - originY + visibleRect.origin.y
        let glyphIndex = layoutManager.glyphIndex(for: NSPoint(x: 0, y: textY), in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        if let cache = lineStartsCache {
            return cache.lineNumber(at: charIndex)
        }

        // Fallback: linear scan if cache not available
        let source = textView.string as NSString
        var line = 1
        for i in 0..<min(charIndex, source.length) where source.character(at: i) == ASCII.newline {
            line += 1
        }
        return line
    }

    @objc private func handleBoundsChange(_ notification: Notification) {
        // Safety: if clipView was nil at init, subscription is unscoped — filter here
        guard observedClipView == nil || notification.object as AnyObject? === observedClipView else { return }
        #if DEBUG
        boundsChangeCount += 1
        #endif
        needsDisplay = true
    }

    @objc private func contentDidChange() {
        recountTotalLines()
        needsDisplay = true
    }

    private func recountTotalLines() {
        if let cache = lineStartsCache {
            cachedTotalLines = cache.lineCount
            return
        }
        guard let source = textView?.string as NSString? else {
            cachedTotalLines = 1
            return
        }
        var count = 1
        for i in 0..<source.length where source.character(at: i) == ASCII.newline {
            count += 1
        }
        cachedTotalLines = count
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView
        else { return }

        // ── Фон ──
        gutterBgColor.setFill()
        bounds.fill()

        // ── Разделитель ──
        separatorColor.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        sep.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        sep.lineWidth = 1
        sep.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: gutterTextColor
        ]

        let visibleRect = scrollView.contentView.bounds
        // textContainerOrigin — реальный сдвиг текста (из GutterTextView)
        let originY = textView.textContainerOrigin.y
        let source = textView.string as NSString

        if source.length == 0 {
            let numStr = "1" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = gutterWidth - size.width - 8
            numStr.draw(at: NSPoint(x: x, y: originY + baselineOffset), withAttributes: attrs)
            return
        }

        // ── Находим видимый диапазон глифов ──
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        if visibleGlyphRange.location == NSNotFound { return }

        // ── Считаем номер первой видимой строки ──
        let firstVisibleCharIndex = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )
        var lineNumber: Int
        if let cache = lineStartsCache {
            lineNumber = cache.lineNumber(at: firstVisibleCharIndex)
        } else {
            lineNumber = 1
            if firstVisibleCharIndex > 0 {
                var count = 0
                for i in 0..<firstVisibleCharIndex where source.character(at: i) == ASCII.newline {
                    count += 1
                }
                lineNumber = count + 1
            }
        }

        // ── Рисуем номера видимых строк через enumerateLineFragments ──
        // Этот метод проходит только по видимым фрагментам строк — быстро.
        var previousLineCharIndex = -1
        let diffBarWidth: CGFloat = 3
        let showFoldIndicators = isMouseInside && !foldStartMap.isEmpty
        let hasFolds = !foldState.foldedRanges.isEmpty

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { lineRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

            // Определяем: новая логическая строка или soft-wrap (перенос длинной строки)?
            let isNewLogicalLine: Bool
            if previousLineCharIndex < 0 {
                // Первый видимый фрагмент — всегда рисуем номер
                isNewLogicalLine = true
            } else if charIndex > previousLineCharIndex {
                // Проверяем, есть ли \n между предыдущим и текущим фрагментом
                let range = NSRange(location: previousLineCharIndex,
                                    length: charIndex - previousLineCharIndex)
                isNewLogicalLine = source.substring(with: range).contains("\n")
            } else {
                isNewLogicalLine = false
            }

            if isNewLogicalLine {
                // Skip hidden lines (inside folded regions) — only increment counter
                if hasFolds && self.foldState.isLineHidden(lineNumber) {
                    lineNumber += 1
                    previousLineCharIndex = charIndex
                    return
                }

                // Y: позиция фрагмента в textContainer + сдвиг контейнера − скролл
                let y = lineRect.origin.y + originY - visibleRect.origin.y

                let numStr = "\(lineNumber)" as NSString
                let size = numStr.size(withAttributes: attrs)
                let x = self.gutterWidth - size.width - 8
                numStr.draw(at: NSPoint(x: x, y: y + self.baselineOffset), withAttributes: attrs)

                // ── Fold disclosure triangle ──
                if showFoldIndicators || self.foldState.foldedRanges.contains(where: { $0.startLine == lineNumber }) {
                    if let foldable = self.foldStartMap[lineNumber] {
                        let isFolded = self.foldState.isFolded(foldable)
                        self.drawFoldIndicator(
                            at: y, lineHeight: lineRect.height,
                            isFolded: isFolded
                        )
                    }
                }

                // ── Git diff marker ──
                if let diffKind = self.diffMap[lineNumber] {
                    let markerColor: NSColor
                    switch diffKind {
                    case .added:    markerColor = self.addedColor
                    case .modified: markerColor = self.modifiedColor
                    case .deleted:  markerColor = self.deletedColor
                    }

                    if diffKind == .deleted {
                        // Deleted: small red triangle at the gutter edge
                        let triangleSize: CGFloat = 5
                        let triX = self.gutterWidth - diffBarWidth
                        let triY = y
                        let path = NSBezierPath()
                        path.move(to: NSPoint(x: triX, y: triY))
                        path.line(to: NSPoint(x: triX + triangleSize, y: triY + triangleSize / 2))
                        path.line(to: NSPoint(x: triX, y: triY + triangleSize))
                        path.close()
                        markerColor.setFill()
                        path.fill()
                    } else {
                        // Added/Modified: colored bar at the right edge of gutter
                        let barRect = NSRect(
                            x: self.gutterWidth - diffBarWidth,
                            y: y,
                            width: diffBarWidth,
                            height: lineRect.height
                        )
                        markerColor.setFill()
                        barRect.fill()
                    }
                }

                lineNumber += 1
            }

            previousLineCharIndex = charIndex
        }

        // ── Номер для завершающей пустой строки (после последнего \n) ──
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0 && source.hasSuffix("\n") {
            let y = extraRect.origin.y + originY - visibleRect.origin.y
            if y >= -extraRect.height && y <= bounds.height {
                let numStr = "\(lineNumber)" as NSString
                let size = numStr.size(withAttributes: attrs)
                let x = gutterWidth - size.width - 8
                numStr.draw(at: NSPoint(x: x, y: y + baselineOffset), withAttributes: attrs)
            }
        }

        // ── Обновляем ширину гуттера если изменилось количество цифр ──
        let digits = max(String(cachedTotalLines).count, 2)
        if cachedDigitWidthFont != gutterFont {
            cachedDigitWidth = "0".size(withAttributes: [.font: gutterFont]).width
            cachedDigitWidthFont = gutterFont
        }
        let newWidth = CGFloat(digits) * cachedDigitWidth + 20
        if abs(gutterWidth - newWidth) > 1 {
            gutterWidth = newWidth
            frame.size.width = newWidth
            if let gutterTextView = textView as? GutterTextView {
                gutterTextView.gutterInset = newWidth + 4
                gutterTextView.needsLayout = true
                gutterTextView.needsDisplay = true
            }
        }
    }

    // MARK: - Fold indicator drawing

    /// Draws a disclosure triangle for fold indicators.
    private func drawFoldIndicator(at y: CGFloat, lineHeight: CGFloat, isFolded: Bool) {
        let size: CGFloat = 8
        let centerY = y + lineHeight / 2
        let x: CGFloat = 3

        let path = NSBezierPath()
        if isFolded {
            // ▶ (pointing right — folded)
            path.move(to: NSPoint(x: x, y: centerY - size / 2))
            path.line(to: NSPoint(x: x + size * 0.75, y: centerY))
            path.line(to: NSPoint(x: x, y: centerY + size / 2))
        } else {
            // ▼ (pointing down — expanded)
            path.move(to: NSPoint(x: x, y: centerY - size / 4))
            path.line(to: NSPoint(x: x + size, y: centerY - size / 4))
            path.line(to: NSPoint(x: x + size / 2, y: centerY + size / 2))
        }
        path.close()
        foldIndicatorColor.setFill()
        path.fill()
    }
}
