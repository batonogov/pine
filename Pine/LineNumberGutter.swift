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
    ///
    /// `ValidationDiagnostic` already provides a manual `Equatable` that
    /// excludes the synthesized `id` UUID (see `ConfigValidator.swift`), so
    /// the short-circuit below uses `==` directly. Without this guard every
    /// `updateNSView` pass would look like a change and instantly dismiss
    /// any open popover, breaking the click-to-explain affordance (#781).
    var validationDiagnostics: [ValidationDiagnostic] = [] {
        didSet {
            guard oldValue != validationDiagnostics else { return }
            rebuildDiagnosticMap()
            // Diagnostics actually changed — dismiss any open popover,
            // its anchor line may no longer carry an icon.
            diagnosticPopover?.close()
            diagnosticPopover = nil
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

    /// Pre-indexed hunk lookup: first line of hunk → DiffHunk.
    private var hunkStartMap: [Int: DiffHunk] = [:]

    private func rebuildHunkStartMap() {
        hunkStartMap = Dictionary(diffHunks.map { ($0.newStart, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Pre-indexed diff lookup: line number → kind (cached, rebuilt when lineDiffs changes)
    private var diffMap: [Int: GitLineDiff.Kind] = [:]

    /// Pre-indexed diagnostic lookup: line number → highest severity diagnostic.
    private var diagnosticMap: [Int: ValidationDiagnostic] = [:]

    /// Pre-indexed fold lookup: start line → FoldableRange.
    private var foldStartMap: [Int: FoldableRange] = [:]

    /// Whether the mouse is currently inside the gutter (for showing fold indicators).
    private var isMouseInside = false

    /// Cached last-resolved line number used by `mouseMoved` to skip the
    /// per-pixel diagnostic lookup when the cursor is still hovering over
    /// the same line. Reset to `nil` whenever the cursor leaves the gutter.
    private var lastHoveredLine: Int?

    /// Whether `mouseMoved` last set the pointing-hand cursor. Used so we only reset
    /// the cursor back to the default when leaving the icon zone, avoiding fighting
    /// other cursor sources (e.g. NSTextView's iBeam).
    private var didSetPointingCursor = false

    /// Diagnostic icon hit-test zone (x range): `[0, diagnosticIconHitZoneWidth)`.
    /// Sized to match the fold-indicator area so the icon (drawn at x=1..1+iconSize)
    /// is fully covered.
    static let diagnosticIconHitZoneWidth: CGFloat = 14

    /// Horizontal space reserved on the left edge of the gutter for the
    /// diagnostic icon when diagnostics are present. Line numbers never enter
    /// this zone — this guarantees the icon and line number never overlap,
    /// regardless of how many digits the line number has (#781).
    static let diagnosticReservedWidth: CGFloat = 14

    /// Right-side padding between the line number and the diff bar / gutter
    /// edge. Exposed so tests can reproduce the draw-path math exactly.
    static let lineNumberRightPadding: CGFloat = 8

    /// Test-only snapshot of the x-coordinates used when drawing a line number.
    /// Returned by `lineNumberDrawLayout(forDigits:)` so tests can verify the
    /// icon zone and the line number zone never overlap.
    struct LineNumberDrawLayout: Equatable {
        /// Left edge of the drawn line number (x of the first digit).
        let lineNumberX: CGFloat
        /// Right edge of the drawn line number string.
        let lineNumberRightEdge: CGFloat
        /// Right edge of the reserved diagnostic icon zone (i.e. the first x
        /// coordinate that line numbers are allowed to touch).
        let diagnosticZoneRightEdge: CGFloat
        /// Current gutter width when the layout was computed.
        let gutterWidth: CGFloat
    }

    /// Computes the exact draw coordinates the paint path would use for a line
    /// number with the given digit count. Mirrors the formula inside
    /// `draw(_:)` so tests can assert non-overlap without touching drawing.
    func lineNumberDrawLayout(forDigits digits: Int) -> LineNumberDrawLayout {
        let attrs: [NSAttributedString.Key: Any] = [.font: gutterFont]
        let digitString = String(repeating: "0", count: max(digits, 1)) as NSString
        let textWidth = digitString.size(withAttributes: attrs).width
        let rightEdge = gutterWidth - Self.lineNumberRightPadding
        let leftEdge = rightEdge - textWidth
        return LineNumberDrawLayout(
            lineNumberX: leftEdge,
            lineNumberRightEdge: rightEdge,
            diagnosticZoneRightEdge: Self.diagnosticReservedWidth,
            gutterWidth: gutterWidth
        )
    }

    private func rebuildDiffMap() {
        diffMap = Dictionary(lineDiffs.map { ($0.line, $0.kind) }, uniquingKeysWith: { _, last in last })
    }

    private func rebuildFoldStartMap() {
        foldStartMap = Dictionary(foldableRanges.map { ($0.startLine, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Rebuilds the diagnostic map, keeping only the highest-severity diagnostic per line.
    /// Also registers/removes the tooltip rect for dynamic tooltip resolution.
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
        // No tooltip rect is registered — diagnostic explanations are shown
        // only by explicit click, never by hover (#781).
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
    private let modifiedColor = NSColor.systemYellow
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
        // NOTE: We cannot touch `diagnosticPopover` here because it is MainActor-isolated
        // and `deinit` is non-isolated in Swift 6. Cleanup happens in the
        // `validationDiagnostics.didSet` hook (popover is dismissed when diagnostics
        // are cleared) and via the `.transient` popover behavior, which causes the
        // popover to dismiss itself on any outside event.
    }

    // MARK: - Mouse tracking for fold indicators

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // .mouseMoved is required so we can update the dynamic `toolTip` string
        // as the cursor moves between diagnostic icons (#679). Without it, AppKit
        // never asks us for a per-line tooltip and the user sees nothing.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
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
        // Clear dynamic tooltip when leaving the gutter so a stale message
        // doesn't linger after the cursor moves into the editor.
        toolTip = nil
        lastHoveredLine = nil
        // Restore the default cursor when leaving the gutter so the
        // pointing-hand we set in `mouseMoved` does not stick (#679 regression).
        if didSetPointingCursor {
            NSCursor.arrow.set()
            didSetPointingCursor = false
        }
    }

    /// Updates the dynamic `toolTip` property based on the cursor position.
    ///
    /// We can't rely on the `addToolTip(_:owner:userData:)` rect mechanism alone
    /// because AppKit only asks the owner for tooltip text after a fixed hover
    /// delay AND only when the rect was registered with non-zero bounds at the
    /// right time. Setting `toolTip` directly on every mouse move guarantees that
    /// the standard NSView tooltip surface always reflects the current line.
    /// (#679)
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Track the hovered line purely for cursor state — we deliberately do
        // NOT set `toolTip` on hover. Diagnostic explanations are only revealed
        // via an explicit click (#781). Hover tooltips were noisy and stole
        // focus from the editor content.
        let line = lineNumber(at: point)
        lastHoveredLine = line

        // Cursor handling: pointing-hand only inside the icon hit zone AND only when
        // there is actually a diagnostic on this line. Reset to arrow as soon as the
        // cursor leaves the icon zone, otherwise the pointing-hand sticks (#679).
        let inIconZone = point.x < Self.diagnosticIconHitZoneWidth
        let hasDiagnostic = (line.flatMap { diagnosticMap[$0] }) != nil
        if inIconZone && hasDiagnostic {
            if !didSetPointingCursor {
                NSCursor.pointingHand.set()
                didSetPointingCursor = true
            }
        } else if didSetPointingCursor {
            NSCursor.arrow.set()
            didSetPointingCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

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

        // Diagnostic icon click → show popover with full message (#679).
        // Diagnostic icons are drawn at x=1..1+diagnosticIconDrawSize.
        if let lineNum = lineNumber(at: point),
           let diag = diagnosticMap[lineNum] {
            showDiagnosticPopover(for: diag, at: point)
            return
        }

        // Find which line was clicked for fold toggle
        if let lineNumber = lineNumber(at: point),
           let foldable = foldStartMap[lineNumber] {
            onFoldToggle?(foldable)
        }
    }

    /// Currently displayed diagnostic popover, if any. Kept as a property so we can
    /// dismiss it on subsequent clicks and prevent multiple popovers.
    private var diagnosticPopover: NSPopover?

    /// Test-only accessor for the retained diagnostic popover. Allows the test
    /// suite to verify that the popover is created with the expected controller
    /// and torn down when diagnostics are replaced.
    var diagnosticPopoverForTesting: NSPopover? { diagnosticPopover }

    /// Test-only accessor for the cursor-state flag tracked in `mouseMoved`/`mouseExited`.
    var didSetPointingCursorForTesting: Bool { didSetPointingCursor }

    /// Test-only entry point that performs the same line/cursor logic as
    /// `mouseMoved(with:)` but without needing to fabricate a full NSEvent.
    /// Mirrors the production path so tests cover the real cursor state machine.
    func simulateMouseMovedForTesting(at point: NSPoint) {
        let line = lineNumber(at: point)
        lastHoveredLine = line
        // Hover must NOT set toolTip on diagnostic icons (#781).
        let inIconZone = point.x < Self.diagnosticIconHitZoneWidth
        let hasDiagnostic = (line.flatMap { diagnosticMap[$0] }) != nil
        if inIconZone && hasDiagnostic {
            if !didSetPointingCursor {
                NSCursor.pointingHand.set()
                didSetPointingCursor = true
            }
        } else if didSetPointingCursor {
            NSCursor.arrow.set()
            didSetPointingCursor = false
        }
    }

    /// Shows an NSPopover anchored to the diagnostic icon for the given diagnostic.
    /// The popover lists the severity, source, and full message — providing the
    /// "click to see what is wrong" affordance requested in #679.
    func showDiagnosticPopover(for diag: ValidationDiagnostic, at point: NSPoint) {
        // Dismiss any existing popover first and clear the stored reference
        // immediately, so a subsequent `show` failure leaves no stale handle.
        diagnosticPopover?.close()
        diagnosticPopover = nil

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DiagnosticPopoverController(diagnostic: diag)

        // Anchor to the fixed icon rect (x = 1, width = diagnosticIconDrawSize),
        // not to the click point. Earlier code placed the anchor at
        // `point.x ± 4`, which meant a click at x=12 in the 14pt hit zone
        // pointed the popover's arrow mid-air, not at the glyph.
        let iconRect = NSRect(
            x: 1,
            y: max(0, point.y - Self.diagnosticIconDrawSize / 2),
            width: Self.diagnosticIconDrawSize,
            height: Self.diagnosticIconDrawSize
        )
        popover.show(relativeTo: iconRect, of: self, preferredEdge: .maxX)
        diagnosticPopover = popover
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
    func lineNumber(at point: NSPoint) -> Int? {
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

    func recountTotalLines() {
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
        recomputeGutterWidth()
    }

    /// Recomputes `gutterWidth` based on the current digit count and whether
    /// diagnostics are present. Splits the gutter into three zones, left→right:
    ///
    ///   [0, diagnosticReservedWidth)  — diagnostic icon (when diagnostics present)
    ///   [diagnosticReservedWidth + ε, gutterWidth - rightPadding) — line numbers
    ///   [gutterWidth - diffBarWidth, gutterWidth) — git diff bar
    ///
    /// The icon zone and the line-number zone can never overlap regardless of
    /// how many digits the line number has (#781).
    func recomputeGutterWidth() {
        let digits = max(String(cachedTotalLines).count, 2)
        if cachedDigitWidthFont != gutterFont {
            cachedDigitWidth = "0".size(withAttributes: [.font: gutterFont]).width
            cachedDigitWidthFont = gutterFont
        }
        // The diagnostic icon zone is reserved unconditionally. Earlier this
        // value depended on `!diagnosticMap.isEmpty`, which caused the gutter
        // (and the editor text) to jump by 14pt the instant the first error
        // appeared during an edit → validate loop — visible flicker for the
        // user. Always reserving the zone trades a tiny constant amount of
        // gutter space for a stable editor layout.
        let newWidth = Self.diagnosticReservedWidth + CGFloat(digits) * cachedDigitWidth + 20
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

    /// Fixed draw size for diagnostic icons — sized so the right edge (x=1 + 12 = 13px)
    /// stays clear of two-digit line numbers that start around x≈18 (#679).
    /// Increased from 8px to improve readability of error/warning glyphs.
    static let diagnosticIconDrawSize: CGFloat = 12

    /// Draws an SF Symbol icon for a validation diagnostic at the given line position.
    /// The icon is drawn inside the fold indicator area (leftmost ~14px of the gutter),
    /// keeping it clear of line number text.
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
        // Position at the left edge of the gutter, within the fold indicator area (0–14px).
        // x=1 + iconSize=8 → right edge at 9px, well clear of two-digit line numbers (~18px).
        let x: CGFloat = 1

        tintedImage.draw(in: NSRect(
            x: x, y: centerY,
            width: imageSize.width, height: imageSize.height
        ))
    }

    // MARK: - Diagnostic lookup (test helper)

    /// Returns the diagnostic message for the given line number, or nil if
    /// none. Kept because `ValidationGutterTests` uses it to assert the
    /// severity-priority behavior of `rebuildDiagnosticMap()` without
    /// touching drawing or mouse handling. Not used in production — the
    /// hover tooltip path was removed in #781, diagnostics now surface via
    /// the click-to-show popover (`showDiagnosticPopover(for:at:)`).
    func diagnosticTooltip(forLine line: Int) -> String? {
        diagnosticMap[line]?.message
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
