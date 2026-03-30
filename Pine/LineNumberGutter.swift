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

    /// Validation diagnostics for the current file (error/warning/info icons).
    var validationDiagnostics: [ValidationDiagnostic] = [] {
        didSet {
            rebuildDiagnosticMap()
            needsDisplay = true
        }
    }

    /// Diff hunks for the current file (for accept/revert buttons).
    var diffHunks: [DiffHunk] = [] {
        didSet {
            rebuildHunkStartMap()
            needsDisplay = true
        }
    }

    /// The ID of the currently expanded hunk (shows inline diff). Nil = all collapsed.
    var expandedHunkID: UUID? {
        didSet { needsDisplay = true }
    }

    /// Callback when a diff marker in the gutter is clicked (to toggle inline diff).
    var onDiffMarkerClick: ((DiffHunk) -> Void)?

    /// Callback for accepting (staging) a hunk at the given line.
    var onAcceptHunk: ((DiffHunk) -> Void)?

    /// Callback for reverting a hunk at the given line.
    var onRevertHunk: ((DiffHunk) -> Void)?

    /// Pre-indexed hunk lookup: first line of hunk → DiffHunk.
    private var hunkStartMap: [Int: DiffHunk] = [:]

    private func rebuildHunkStartMap() {
        hunkStartMap = Dictionary(diffHunks.map { ($0.newStart, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Pre-indexed diff lookup: line number → kind (cached, rebuilt when lineDiffs changes)
    private var diffMap: [Int: GitLineDiff.Kind] = [:]

    /// Pre-indexed diagnostic lookup: line number → highest severity diagnostic.
    private var diagnosticMap: [Int: ValidationDiagnostic] = [:]

    /// Whether any diagnostics are present — used to add extra gutter width for icons.
    private var hasDiagnostics: Bool { !diagnosticMap.isEmpty }

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

    /// Rebuilds the diagnostic map, keeping only the highest-severity diagnostic per line.
    private func rebuildDiagnosticMap() {
        diagnosticMap = [:]
        for diag in validationDiagnostics {
            if let existing = diagnosticMap[diag.line] {
                if Self.severityRank(diag.severity) > Self.severityRank(existing.severity) {
                    diagnosticMap[diag.line] = diag
                }
            } else {
                diagnosticMap[diag.line] = diag
            }
        }
    }

    /// Returns a numeric rank for severity (higher = more severe).
    static func severityRank(_ severity: ValidationSeverity) -> Int {
        switch severity {
        case .error: return 3
        case .warning: return 2
        case .info: return 1
        }
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

        // Check for hunk action button clicks first (only when hunk is expanded)
        if let lineNum = lineNumber(at: point),
           let hunk = hunkStartMap[lineNum],
           expandedHunkID == hunk.id,
           let action = hunkButtonHitTest(at: point, lineNumber: lineNum) {
            switch action {
            case .accept:
                onAcceptHunk?(hunk)
            case .revert:
                onRevertHunk?(hunk)
            default:
                break
            }
            return
        }

        // Check for diff marker click (right edge of gutter)
        let diffBarWidth: CGFloat = 3
        if point.x >= gutterWidth - diffBarWidth - 4 {
            if let lineNum = lineNumber(at: point),
               let hunk = hunkForLine(lineNum) {
                onDiffMarkerClick?(hunk)
                return
            }
        }

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

    /// Returns the hunk that covers the given line number, if any.
    private func hunkForLine(_ line: Int) -> DiffHunk? {
        // Check if line has a diff marker
        guard diffMap[line] != nil else { return nil }
        return InlineDiffProvider.hunk(atLine: line, in: diffHunks)
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

                // ── Validation diagnostic icon ──
                if let diag = self.diagnosticMap[lineNumber] {
                    self.drawDiagnosticIcon(
                        at: y, lineHeight: lineRect.height,
                        severity: diag.severity
                    )
                }

                // ── Accept/Revert buttons on hunk start lines (only when hunk is expanded) ──
                if self.isMouseInside,
                   let hunk = self.hunkStartMap[lineNumber],
                   self.expandedHunkID == hunk.id {
                    self.drawHunkActionButtons(at: y, lineHeight: lineRect.height)
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
        let diagnosticExtra: CGFloat = hasDiagnostics ? Self.diagnosticIconDrawSize + 4 : 0
        let newWidth = CGFloat(digits) * cachedDigitWidth + 20 + diagnosticExtra
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

    // MARK: - Diagnostic icon drawing

    /// SF Symbol names for each severity level.
    static let diagnosticSymbolNames: [ValidationSeverity: String] = [
        .error: "xmark.circle.fill",
        .warning: "exclamationmark.triangle.fill",
        .info: "info.circle.fill"
    ]

    /// Colors for each severity level.
    static let diagnosticColors: [ValidationSeverity: NSColor] = [
        .error: .systemRed,
        .warning: .systemYellow,
        .info: .systemBlue
    ]

    /// Fixed draw size for diagnostic icons — used for gutter width calculation and rendering.
    static let diagnosticIconDrawSize: CGFloat = 12

    /// Draws an SF Symbol icon for a validation diagnostic at the given line position.
    /// The icon is placed to the left of the line number, in the extra gutter space
    /// reserved when diagnostics are present.
    func drawDiagnosticIcon(at y: CGFloat, lineHeight: CGFloat, severity: ValidationSeverity) {
        guard let symbolName = Self.diagnosticSymbolNames[severity],
              let color = Self.diagnosticColors[severity] else { return }

        let iconSize: CGFloat = min(lineHeight - 2, Self.diagnosticIconDrawSize)
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let tintedImage = image.tinted(with: color)
        let imageSize = tintedImage.size
        let centerY = y + (lineHeight - imageSize.height) / 2
        // Position to the left of the line number, after the fold indicator area
        let x: CGFloat = 14

        tintedImage.draw(in: NSRect(
            x: x, y: centerY,
            width: imageSize.width, height: imageSize.height
        ))
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

    // MARK: - Accept/Revert button drawing

    /// Width of each hunk action button area, derived from gutter font size.
    private var hunkButtonSize: CGFloat {
        gutterFont.pointSize + 1
    }

    /// X position for the first (accept) button, based on gutter font metrics.
    private var hunkButtonStartX: CGFloat {
        gutterFont.pointSize + 2
    }

    /// Draws accept (checkmark) and revert (arrow) icons at the top of a hunk.
    private func drawHunkActionButtons(at y: CGFloat, lineHeight: CGFloat) {
        let centerY = y + lineHeight / 2
        let checkmarkX = hunkButtonStartX
        let revertX = checkmarkX + hunkButtonSize + 2

        // Accept button (checkmark)
        drawCheckmark(
            at: NSPoint(x: checkmarkX, y: centerY),
            size: hunkButtonSize,
            color: addedColor
        )

        // Revert button (curved arrow)
        drawRevertArrow(
            at: NSPoint(x: revertX, y: centerY),
            size: hunkButtonSize,
            color: NSColor.systemOrange
        )
    }

    /// Draws a small checkmark icon.
    private func drawCheckmark(at center: NSPoint, size: CGFloat, color: NSColor) {
        let half = size / 2
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: center.x - half * 0.4, y: center.y))
        path.line(to: NSPoint(x: center.x - half * 0.1, y: center.y + half * 0.4))
        path.line(to: NSPoint(x: center.x + half * 0.5, y: center.y - half * 0.4))
        color.setStroke()
        path.stroke()
    }

    /// Draws a small revert (undo) arrow icon.
    private func drawRevertArrow(at center: NSPoint, size: CGFloat, color: NSColor) {
        let half = size / 2
        let path = NSBezierPath()
        path.lineWidth = 1.5
        // Curved arrow
        path.appendArc(
            withCenter: NSPoint(x: center.x, y: center.y),
            radius: half * 0.4,
            startAngle: 45,
            endAngle: 270,
            clockwise: false
        )
        // Arrowhead
        let tipX = center.x
        let tipY = center.y - half * 0.4
        let arrowSize: CGFloat = half * 0.3
        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: tipX - arrowSize, y: tipY - arrowSize))
        arrowPath.line(to: NSPoint(x: tipX, y: tipY))
        arrowPath.line(to: NSPoint(x: tipX + arrowSize, y: tipY - arrowSize))
        arrowPath.lineWidth = 1.5
        color.setStroke()
        path.stroke()
        arrowPath.stroke()
    }

    /// Hit test for hunk action buttons. Returns the action if clicked, nil otherwise.
    func hunkButtonHitTest(at point: NSPoint, lineNumber: Int) -> InlineDiffAction? {
        guard hunkStartMap[lineNumber] != nil else { return nil }
        let checkmarkX = hunkButtonStartX
        let revertX = checkmarkX + hunkButtonSize + 2
        let hitWidth = hunkButtonSize + 4

        if point.x >= checkmarkX - 2 && point.x <= checkmarkX + hitWidth - 4 {
            return .accept
        }
        if point.x >= revertX - 2 && point.x <= revertX + hitWidth - 4 {
            return .revert
        }
        return nil
    }
}
