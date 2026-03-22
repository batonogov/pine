//
//  CodeEditorView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
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

    // MARK: - Multi-cursor state

    /// Whether multi-cursor mode is active (2+ cursors).
    var isMultiCursorActive: Bool { multiCursors.count > 1 }

    /// Current set of cursors. Empty means single-cursor mode (use NSTextView default).
    private(set) var multiCursors: [MultiCursorLogic.Cursor] = []

    /// Flag to distinguish multi-cursor edits from external text changes.
    private(set) var isApplyingMultiCursorEdit = false

    /// Applies multi-cursor edit result using per-cursor targeted replacements (preserves attributes).
    /// Replacements are applied in reverse order so earlier offsets remain valid.
    private func applyMultiCursorResult(_ result: MultiCursorLogic.Result) {
        isApplyingMultiCursorEdit = true
        defer { isApplyingMultiCursorEdit = false }

        // Group all replacements into a single undo step
        undoManager?.beginUndoGrouping()

        // Apply replacements in reverse order (from end to start) to preserve offsets
        for replacement in result.replacements.reversed()
            where shouldChangeText(in: replacement.range, replacementString: replacement.string) {
            replaceCharacters(in: replacement.range, with: replacement.string)
            didChangeText()
        }

        undoManager?.endUndoGrouping()

        multiCursors = result.newCursors
        syncSelectionsFromCursors()
    }

    /// Resets multi-cursor state. Called when text changes externally (not from multi-cursor edit).
    func invalidateMultiCursors() {
        multiCursors = []
        stopCaretBlink()
    }

    /// Syncs NSTextView selections from multiCursors using setSelectedRanges (Apple API).
    private func syncSelectionsFromCursors() {
        guard !multiCursors.isEmpty else { return }
        let textLength = (string as NSString).length
        let ranges = multiCursors.map { cursor -> NSValue in
            let range = cursor.range
            let loc = min(range.location, textLength)
            let len = min(range.length, textLength - loc)
            return NSValue(range: NSRange(location: loc, length: len))
        }
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
        if isMultiCursorActive { startCaretBlink() } else { stopCaretBlink() }
    }

    // MARK: - Multi-cursor caret drawing

    private var caretBlinkTimer: Timer?
    private var extraCaretsVisible = true

    private func startCaretBlink() {
        guard caretBlinkTimer == nil else { return }
        extraCaretsVisible = true
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isMultiCursorActive else { return }
            self.extraCaretsVisible.toggle()
            // Invalidate only the extra caret rects (not the whole view)
            for cursor in self.multiCursors.dropFirst() where !cursor.hasSelection {
                if let rect = self.extraCaretRect(for: cursor) {
                    self.setNeedsDisplay(rect)
                }
            }
        }
    }

    private func stopCaretBlink() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        // Clear any remaining extra carets
        if !multiCursors.isEmpty {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isMultiCursorActive, extraCaretsVisible,
              let layoutManager, let textContainer else { return }

        let origin = textContainerOrigin
        (insertionPointColor ?? .textColor).setFill()

        for cursor in multiCursors.dropFirst() where !cursor.hasSelection {
            guard let caretRect = extraCaretRect(for: cursor),
                  dirtyRect.intersects(caretRect) else { continue }
            caretRect.fill()
        }
    }

    private func extraCaretRect(for cursor: MultiCursorLogic.Cursor) -> NSRect? {
        guard let layoutManager else { return nil }
        let origin = textContainerOrigin
        let charIndex = min(cursor.location, (string as NSString).length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let loc = layoutManager.location(forGlyphAt: glyphIndex)
        return NSRect(
            x: lineRect.origin.x + loc.x + origin.x,
            y: lineRect.origin.y + origin.y,
            width: 2,
            height: lineRect.height
        )
    }

    /// Activates multi-cursor mode from the current single selection.
    private func ensureMultiCursorsFromSelection() {
        if multiCursors.isEmpty {
            let sel = selectedRange()
            if sel.length > 0 {
                multiCursors = [MultiCursorLogic.Cursor(
                    location: NSMaxRange(sel),
                    selection: sel
                )]
            } else {
                multiCursors = [MultiCursorLogic.Cursor(location: sel.location)]
            }
        }
    }

    /// Collapses multi-cursor mode to a single cursor.
    func collapseToSingleCursor() {
        guard isMultiCursorActive else { return }
        let first = multiCursors[0]
        multiCursors = []
        setSelectedRange(NSRange(location: first.location, length: 0))
        stopCaretBlink()
    }

    // MARK: - Multi-cursor text input overrides

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isMultiCursorActive, let str = string as? String else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let result = MultiCursorLogic.insert(
            in: self.string, cursors: multiCursors, string: str
        )
        applyMultiCursorResult(result)
    }

    override func deleteBackward(_ sender: Any?) {
        guard isMultiCursorActive else {
            super.deleteBackward(sender)
            return
        }
        let result = MultiCursorLogic.deleteBackward(in: string, cursors: multiCursors)
        applyMultiCursorResult(result)
    }

    override func deleteForward(_ sender: Any?) {
        guard isMultiCursorActive else {
            super.deleteForward(sender)
            return
        }
        let result = MultiCursorLogic.deleteForward(in: string, cursors: multiCursors)
        applyMultiCursorResult(result)
    }

    override func cancelOperation(_ sender: Any?) {
        if isMultiCursorActive {
            collapseToSingleCursor()
            return
        }
        super.cancelOperation(sender)
    }

    // MARK: - Multi-cursor arrow key movement

    override func moveLeft(_ sender: Any?) {
        guard isMultiCursorActive else { super.moveLeft(sender); return }
        multiCursors = MultiCursorLogic.moveLeft(in: string, cursors: multiCursors)
        syncSelectionsFromCursors()
    }

    override func moveRight(_ sender: Any?) {
        guard isMultiCursorActive else { super.moveRight(sender); return }
        multiCursors = MultiCursorLogic.moveRight(in: string, cursors: multiCursors)
        syncSelectionsFromCursors()
    }

    override func moveUp(_ sender: Any?) {
        guard isMultiCursorActive else { super.moveUp(sender); return }
        multiCursors = MultiCursorLogic.moveUp(in: string, cursors: multiCursors)
        syncSelectionsFromCursors()
    }

    override func moveDown(_ sender: Any?) {
        guard isMultiCursorActive else { super.moveDown(sender); return }
        multiCursors = MultiCursorLogic.moveDown(in: string, cursors: multiCursors)
        syncSelectionsFromCursors()
    }

    // MARK: - Option+Click for multi-cursor
    // Note: This overrides NSTextView's default Option+Click behavior (rectangular/column selection).
    // Multi-cursor editing (like Xcode/VS Code) is more useful in a code editor context.

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.shift) {
            let point = convert(event.locationInWindow, from: nil)
            let adjustedPoint = NSPoint(
                x: point.x - textContainerOrigin.x,
                y: point.y - textContainerOrigin.y
            )
            guard let layoutManager, let textContainer else {
                super.mouseDown(with: event)
                return
            }
            let charIndex = layoutManager.characterIndex(
                for: adjustedPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            ensureMultiCursorsFromSelection()
            multiCursors = MultiCursorLogic.addCursor(to: multiCursors, at: charIndex)
            syncSelectionsFromCursors()
            return
        }
        // Regular click collapses multi-cursors
        if isMultiCursorActive {
            multiCursors = []
        }
        super.mouseDown(with: event)
    }

    // MARK: - Key equivalents for multi-cursor shortcuts
    // SwiftUI menu shortcuts may not reach NSTextView when it's first responder.
    // Intercept Cmd+D and Cmd+Shift+L directly for reliable handling.

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "d" {
            selectNextOccurrence()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Cmd+D: select next occurrence

    func selectNextOccurrence() {
        ensureMultiCursorsFromSelection()
        multiCursors = MultiCursorLogic.selectNextOccurrence(in: string, cursors: multiCursors)
        syncSelectionsFromCursors()
    }

    // MARK: - Cmd+Shift+L: split selection into lines

    func splitSelectionIntoLines() {
        ensureMultiCursorsFromSelection()
        let result = MultiCursorLogic.splitSelectionIntoLines(in: string, cursors: multiCursors)
        if result.count > 1 {
            multiCursors = result
            syncSelectionsFromCursors()
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
    private var blameLookup: [Int: GitBlameLine] = [:]
    /// Previous blame data count — avoids rebuilding the dictionary on every updateNSView.
    private var blameLineCount: Int = -1
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
            .tinted(with: blameColor)
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = layoutManager,
              textContainer != nil else { return }

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
        for i in 0..<cursorLocation where source.character(at: i) == 0x0A {
            lineNumber += 1
        }

        guard let blame = blameLookup[lineNumber] else { return }

        // Find end of line content
        let lineRange = source.lineRange(for: NSRange(location: cursorLocation, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location && lineEnd <= source.length
            && source.character(at: lineEnd - 1) == 0x0A {
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
        if isMultiCursorActive {
            // In multi-cursor mode, insert newline at each cursor (no auto-indent for simplicity)
            let result = MultiCursorLogic.insert(in: string, cursors: multiCursors, string: "\n")
            applyMultiCursorResult(result)
            return
        }

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
}

// MARK: - Editor container that manages scroll view + minimap layout

/// Custom container view that lays out the scroll view and minimap side by side.
/// Replaces autoresizingMask with explicit layout so the minimap width is
/// always accounted for.
final class EditorContainerView: NSView {
    var minimapWidth: CGFloat = 0

    private weak var managedScrollView: NSScrollView?
    private var findBarObservation: NSKeyValueObservation?
    private var contentViewFrameObserver: Any?

    /// Registers the scroll view so the container can observe find bar visibility changes
    /// and clip the LineNumberView frame accordingly.
    func setScrollView(_ scrollView: NSScrollView) {
        managedScrollView = scrollView
        findBarObservation = scrollView.observe(\.isFindBarVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.needsLayout = true }
        }
        scrollView.contentView.postsFrameChangedNotifications = true
        contentViewFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsLayout = true
        }
    }

    deinit {
        if let obs = contentViewFrameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    override func layout() {
        super.layout()
        let lineNumberArea = lineNumberViewArea()
        for sub in subviews {
            if let minimap = sub as? MinimapView {
                if minimap.isHidden {
                    continue
                }
                minimap.frame = NSRect(
                    x: bounds.width - minimapWidth,
                    y: 0,
                    width: minimapWidth,
                    height: bounds.height
                )
                minimap.needsDisplay = true
            } else if sub is NSScrollView {
                sub.frame = NSRect(
                    x: 0, y: 0,
                    width: bounds.width - minimapWidth,
                    height: bounds.height
                )
            } else {
                // LineNumberView — match the scroll view's content area so it does not
                // paint over the native NSTextFinder find bar when Cmd+F is open.
                sub.frame = NSRect(
                    x: 0, y: lineNumberArea.minY,
                    width: sub.frame.width,
                    height: lineNumberArea.height
                )
            }
        }
    }

    /// Returns the rect (in container coordinates) that the LineNumberView should occupy.
    /// When the find bar is visible this matches scrollView.contentView.frame so the
    /// gutter is clipped to the text area only.
    private func lineNumberViewArea() -> CGRect {
        guard let sv = managedScrollView, sv.isFindBarVisible else {
            return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        }
        return sv.contentView.frame
    }
}

/// A unique navigation request so each "go to" action is processed exactly once.
/// Each instance gets a unique `id`, so two requests to the same offset are distinct.
struct GoToRequest {
    let offset: Int
    let id: UUID = UUID()
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Monotonic version counter from EditorTab — O(1) change detection.
    var contentVersion: UInt64 = 0
    var language: String
    var fileName: String?
    var lineDiffs: [GitLineDiff] = []
    /// Whether inline blame annotation is visible on the cursor line.
    var isBlameVisible: Bool = false
    /// Blame data for the current file.
    var blameLines: [GitBlameLine] = []
    /// Binding to the fold state for the active tab.
    @Binding var foldState: FoldState
    /// Whether the minimap panel is visible.
    var isMinimapVisible: Bool = true
    /// Whether syntax highlighting is disabled for this tab (e.g. large files).
    var syntaxHighlightingDisabled: Bool = false
    /// Cursor position to restore when the view is created (tab switch).
    var initialCursorPosition: Int = 0
    /// Scroll offset to restore when the view is created (tab switch).
    var initialScrollOffset: CGFloat = 0
    /// Called when cursor position or scroll offset changes, so the caller can persist them.
    var onStateChange: ((Int, CGFloat) -> Void)?
    /// When non-nil, the editor scrolls to this offset. The `id` ensures each request is unique.
    var goToOffset: GoToRequest?

    /// Пользовательский ключ атрибута для подсветки парных скобок.
    static let bracketHighlightKey = NSAttributedString.Key("PineBracketHighlight")

    /// Порог (в символах) для переключения на viewport-based подсветку.
    static let viewportHighlightThreshold = 100_000

    /// Файл достаточно большой для viewport-based подсветки?
    private var useViewportHighlighting: Bool {
        (text as NSString).length > Self.viewportHighlightThreshold && !syntaxHighlightingDisabled
    }

    var fontSize: CGFloat = FontSizeSettings.shared.fontSize

    private var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private var gutterFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(fontSize - 2, FontSizeSettings.minSize), weight: .regular)
    }

    func makeNSView(context: Context) -> NSView {
        let gutterWidth: CGFloat = 40

        // ── Контейнер — держит scroll view, line number view и minimap ──
        let container = EditorContainerView()
        container.wantsLayer = true
        container.minimapWidth = isMinimapVisible ? MinimapView.defaultWidth : 0

        // ── ScrollView ──
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // Layout managed by EditorContainerView.layout()
        scrollView.autoresizingMask = []

        // ── Текстовый стек: Storage → LayoutManager → Container → TextView ──
        // Создаём вручную, чтобы всё было корректно инициализировано
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 5
        layoutManager.addTextContainer(textContainer)

        let textView = GutterTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.gutterInset = gutterWidth + 4

        textView.setAccessibilityIdentifier(AccessibilityID.codeEditor)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false

        textView.font = editorFont
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)

        textView.fileExtension = language
        textView.exactFileName = fileName
        textView.setBlameLines(blameLines)
        textView.isBlameVisible = isBlameVisible
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        container.addSubview(scrollView)
        container.setScrollView(scrollView)

        // ── NSLayoutManager delegate for code folding ──
        layoutManager.delegate = context.coordinator

        // ── Номера строк — поверх scroll view, как отдельный сиблинг ──
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.gutterWidth = gutterWidth
        lineNumberView.gutterFont = gutterFont
        lineNumberView.foldState = foldState
        let coordinator = context.coordinator
        lineNumberView.onFoldToggle = { [weak coordinator] foldable in
            coordinator?.handleFoldToggle(foldable)
        }
        container.addSubview(lineNumberView)

        // ── Minimap — справа от scroll view ──
        let minimapView = MinimapView(textView: textView)
        minimapView.isHidden = !isMinimapVisible
        container.addSubview(minimapView)

        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberView = lineNumberView
        context.coordinator.minimapView = minimapView
        context.coordinator.lastFontSize = editorFont.pointSize
        context.coordinator.syncContentVersion()

        textView.string = text
        if useViewportHighlighting {
            // Layout not yet complete — highlight first screenful synchronously
            // to avoid a flash of unstyled text, then refine after layout.
            let initialRange = Self.estimateInitialRange(
                text: text, scrollOffset: initialScrollOffset,
                cursorPosition: initialCursorPosition, fontSize: fontSize
            )
            SyntaxHighlighter.shared.highlightVisibleRange(
                textStorage: textStorage,
                visibleCharRange: initialRange,
                language: language,
                fileName: fileName,
                font: editorFont
            )
            context.coordinator.highlightedCharRange = initialRange
        } else {
            applyHighlighting(to: textView)
        }

        // Restore cursor and scroll from saved per-tab state.
        // initialCursorPosition is stored as NSRange.location (UTF-16 offset),
        // so clamp against NSString.length, not Swift Character count.
        let safePosition = min(initialCursorPosition, (text as NSString).length)
        if safePosition > 0 {
            textView.setSelectedRange(NSRange(location: safePosition, length: 0))
        }

        // Scroll restoration needs layout to be complete, so defer it.
        let savedOffset = initialScrollOffset
        DispatchQueue.main.async {
            if savedOffset > 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: savedOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else if safePosition > 0 {
                textView.scrollRangeToVisible(NSRange(location: safePosition, length: 0))
            }
            // Redraw minimap after layout is complete
            minimapView.needsDisplay = true
        }

        // Observe scroll changes to persist scroll offset.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Observe toggle comment notification (Cmd+/)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleToggleComment),
            name: .toggleComment,
            object: nil
        )

        // Observe Find & Replace notifications (Cmd+F, Cmd+Option+F, Cmd+G, Cmd+Shift+G, Cmd+E)
        for (selector, name) in [
            (#selector(Coordinator.handleFindInFile), Notification.Name.findInFile),
            (#selector(Coordinator.handleFindAndReplace), Notification.Name.findAndReplace),
            (#selector(Coordinator.handleFindNext), Notification.Name.findNext),
            (#selector(Coordinator.handleFindPrevious), Notification.Name.findPrevious),
            (#selector(Coordinator.handleUseSelectionForFind), Notification.Name.useSelectionForFind),
        ] {
            NotificationCenter.default.addObserver(
                context.coordinator, selector: selector, name: name, object: nil
            )
        }

        // Observe multi-cursor notifications (Cmd+D, Cmd+Shift+L)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSelectNextOccurrence),
            name: .selectNextOccurrence,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSplitSelectionIntoLines),
            name: .splitSelectionIntoLines,
            object: nil
        )

        // Observe fold code notifications (Cmd+Option+arrows)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleFoldCode(_:)),
            name: .foldCode,
            object: nil
        )

        // Calculate initial foldable ranges
        context.coordinator.recalculateFoldableRanges()

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Обновляем parent, чтобы binding в coordinator был актуальным
        context.coordinator.parent = self

        guard let editorContainer = container as? EditorContainerView else { return }

        // Minimap visibility — triggers relayout via needsLayout
        if let minimapView = context.coordinator.minimapView {
            minimapView.isHidden = !isMinimapVisible
        }
        editorContainer.minimapWidth = isMinimapVisible ? MinimapView.defaultWidth : 0
        editorContainer.needsLayout = true

        // Keep GutterTextView's language info and blame data in sync
        if let sv = context.coordinator.scrollView,
           let gutterView = sv.documentView as? GutterTextView {
            gutterView.fileExtension = language
            gutterView.exactFileName = fileName
            gutterView.setBlameLines(blameLines)
            if gutterView.isBlameVisible != isBlameVisible {
                gutterView.isBlameVisible = isBlameVisible
                gutterView.display()
            }
        }

        context.coordinator.updateContentIfNeeded(
            text: text,
            language: language,
            fileName: fileName,
            font: editorFont
        )

        // Обновляем шрифт при изменении размера (Cmd+Plus/Minus)
        context.coordinator.updateFontIfNeeded(font: editorFont, gutterFont: gutterFont)

        // Обновляем diff-данные LineNumberView и MinimapView
        if let lineNumberView = context.coordinator.lineNumberView {
            lineNumberView.lineDiffs = lineDiffs
            lineNumberView.foldState = foldState
        }
        if let minimapView = context.coordinator.minimapView {
            minimapView.lineDiffs = lineDiffs
        }

        // Navigate to a specific offset (e.g. next/previous change)
        if let request = goToOffset, request.id != context.coordinator.lastGoToID,
           let sv = context.coordinator.scrollView,
           let textView = sv.documentView as? GutterTextView {
            context.coordinator.lastGoToID = request.id
            let safeOffset = min(request.offset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: safeOffset, length: 0))
            textView.scrollRangeToVisible(NSRange(location: safeOffset, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: CodeEditorView
        var scrollView: NSScrollView?
        var lineNumberView: LineNumberView?
        var minimapView: MinimapView?

        /// Cached foldable ranges for the current text.
        var foldableRanges: [FoldableRange] = []

        /// Cached line starts for O(log n) line number lookups.
        var lineStartsCache: LineStartsCache?

        /// Debounced fold recalculation work item.
        private var foldWorkItem: DispatchWorkItem?

        /// Последние язык/имя файла — для обнаружения смены грамматики
        /// при одинаковом содержимом файлов
        var lastLanguage: String = ""
        var lastFileName: String?
        /// Последний размер шрифта — для обнаружения изменений (Cmd+Plus/Minus)
        var lastFontSize: CGFloat = 0

        /// Flag: text was just changed by the user (NSTextView delegate).
        /// Prevents updateContentIfNeeded from overwriting the text
        /// (and resetting the cursor) on the SwiftUI re-render that follows.
        /// Internal access for testability (`@testable import`).
        var didChangeFromTextView = false

        /// Last consumed navigation request ID — prevents re-processing.
        var lastGoToID: UUID?

        /// Generation counter for cancelling stale async highlight requests.
        let highlightGeneration = HighlightGeneration()

        /// Отложенная задача подсветки (дебаунсинг)
        private var highlightWorkItem: DispatchWorkItem?
        /// Active async highlight task (cancelled when new highlight is scheduled)
        private var highlightTask: Task<Void, Never>?
        /// Задержка дебаунсинга
        private let highlightDelay: TimeInterval = 0.05

        /// Диапазон символов, уже подсвеченных viewport-based подсветкой.
        /// Internal access — записывается из `applyViewportHighlighting` и `highlightOnScrollIfNeeded`.
        var highlightedCharRange: NSRange?
        /// Дебаунс для подсветки при скролле.
        private var scrollHighlightWorkItem: DispatchWorkItem?
        /// Задержка дебаунсинга скролла (~1 кадр при 60fps)
        private let scrollHighlightDelay: TimeInterval = 0.016

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Отменяет отложенную подсветку. Вызывается при смене файла
        /// чтобы не применить диапазон старого документа к новому.
        func cancelPendingHighlight() {
            highlightWorkItem?.cancel()
            highlightWorkItem = nil
            highlightTask?.cancel()
            highlightTask = nil
            highlightGeneration.increment()
        }

        /// Запускает viewport-based подсветку видимой области (deferred на следующий run loop).
        /// Сбрасывает `highlightedCharRange` и вызывает `applyViewportHighlighting`.
        private func scheduleViewportHighlighting(textView: NSTextView) {
            highlightedCharRange = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let sv = self.scrollView else { return }
                self.parent.applyViewportHighlighting(
                    textView: textView, scrollView: sv, coordinator: self
                )
            }
        }

        /// Обновляет текст и подсветку при смене файла или языка.
        /// Вызывается из updateNSView. Выделен в отдельный метод
        /// для возможности прямого тестирования.
        /// Последняя версия контента — для O(1) обнаружения изменений
        /// вместо O(n) сравнения строк.
        private(set) var lastContentVersion: UInt64 = 0

        /// Синхронизирует версию контента (вызывается из makeNSView).
        func syncContentVersion() {
            lastContentVersion = parent.contentVersion
        }

        func updateContentIfNeeded(text: String, language: String, fileName: String?, font: NSFont) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }

            let languageChanged = lastLanguage != language || lastFileName != fileName

            // If the text change originated from the user typing (textDidChange),
            // the NSTextView already has the correct text and textDidChange already
            // scheduled its own debounced highlighting. We only need to sync the
            // version counter — overwriting the string would reset the cursor
            // position (the root cause of issue #250).
            let fromTextView = didChangeFromTextView
            didChangeFromTextView = false

            let textChanged = parent.contentVersion != lastContentVersion

            if fromTextView && !languageChanged {
                lastContentVersion = parent.contentVersion
                return
            }

            guard textChanged || languageChanged else { return }
            lastContentVersion = parent.contentVersion

            // External text change (e.g., tab switch, file reload) → invalidate multi-cursors
            if let gutterView = textView as? GutterTextView {
                gutterView.invalidateMultiCursors()
            }

            cancelPendingHighlight()
            if let storage = textView.textStorage {
                SyntaxHighlighter.shared.invalidateCache(for: storage)
            }

            if textChanged {
                textView.string = text
            }

            if !parent.syntaxHighlightingDisabled, let storage = textView.textStorage {
                if storage.length > CodeEditorView.viewportHighlightThreshold {
                    scheduleViewportHighlighting(textView: textView)
                } else {
                    highlightGeneration.increment()
                    let gen = highlightGeneration
                    let lang = language
                    let name = fileName
                    let editorFont = font
                    highlightTask?.cancel()
                    highlightTask = Task { @MainActor in
                        await SyntaxHighlighter.shared.highlightAsync(
                            textStorage: storage,
                            language: lang,
                            fileName: name,
                            font: editorFont,
                            generation: gen
                        )
                    }
                }
            }

            lastLanguage = language
            lastFileName = fileName

            // Note: cursor/scroll restoration on tab switch is handled by makeNSView
            // (since .id(tab.id) recreates the view). This path only fires for
            // in-place content changes from updateNSView, where we should not
            // reset the cursor.
        }

        /// Updates font on both editor and gutter when font size changes.
        func updateFontIfNeeded(font: NSFont, gutterFont: NSFont) {
            guard font.pointSize != lastFontSize else { return }
            lastFontSize = font.pointSize

            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }

            textView.font = font

            // Re-highlight with new font
            if !parent.syntaxHighlightingDisabled, let storage = textView.textStorage {
                if storage.length > CodeEditorView.viewportHighlightThreshold {
                    scheduleViewportHighlighting(textView: textView)
                } else {
                    highlightGeneration.increment()
                    let gen = highlightGeneration
                    let lang = parent.language
                    let name = parent.fileName
                    highlightTask?.cancel()
                    highlightTask = Task { @MainActor in
                        await SyntaxHighlighter.shared.highlightAsync(
                            textStorage: storage,
                            language: lang,
                            fileName: name,
                            font: font,
                            generation: gen
                        )
                    }
                }
            }

            // Update gutter font
            lineNumberView?.gutterFont = gutterFont
            lineNumberView?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Mark that this change originated from the user typing,
            // so the upcoming updateNSView won't overwrite the text and reset the cursor.
            didChangeFromTextView = true
            parent.text = textView.string

            // Invalidate multi-cursor state when text changes externally (not from multi-cursor edit)
            if let gutterView = textView as? GutterTextView, !gutterView.isApplyingMultiCursorEdit {
                gutterView.invalidateMultiCursors()
            }

            // Подсветка синтаксиса сбросит backgroundColor —
            // считаем bracket highlight невалидным
            previousBracketRanges = []

            // Report state change
            reportStateChange()

            // Update line starts cache incrementally if possible, otherwise full rebuild
            if var cache = lineStartsCache,
               let storage = textView.textStorage,
               storage.editedRange.location != NSNotFound {
                cache.update(
                    editedRange: storage.editedRange,
                    changeInLength: storage.changeInLength,
                    in: textView.string as NSString
                )
                lineStartsCache = cache
            } else {
                lineStartsCache = LineStartsCache(text: textView.string)
            }

            // Recalculate foldable ranges (debounced — expensive operation)
            scheduleFoldRecalculation()

            // Захватываем editedRange из textStorage сейчас,
            // пока он валиден в координатах текущей версии текста
            var editedRange: NSRange?
            if let storage = textView.textStorage {
                let edited = storage.editedRange
                if edited.location != NSNotFound {
                    editedRange = edited
                }
            }

            // Skip highlighting for large files opened without syntax highlighting
            guard !parent.syntaxHighlightingDisabled else { return }

            // Инвалидируем highlightedCharRange — вставка/удаление текста
            // сдвигает символьные смещения, старый диапазон некорректен
            highlightedCharRange = nil

            // Дебаунсинг: откладываем подсветку до паузы в вводе.
            // Не накапливаем диапазоны — каждый textDidChange работает
            // в своих координатах; union между версиями некорректен.
            // При быстром вводе последовательные правки обычно смежны,
            // и 20-строчный контекст в highlightEdited покрывает их.
            highlightWorkItem?.cancel()
            highlightTask?.cancel()
            let isLargeFile = (textView.string as NSString).length > CodeEditorView.viewportHighlightThreshold
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let sv = self.scrollView,
                      let tv = sv.documentView as? NSTextView,
                      let storage = tv.textStorage else { return }

                self.highlightGeneration.increment()
                let gen = self.highlightGeneration
                let lang = self.parent.language
                let name = self.parent.fileName
                let font = self.parent.editorFont

                if let range = editedRange, range.location + range.length <= storage.length {
                    self.highlightTask = Task { @MainActor in
                        await SyntaxHighlighter.shared.highlightEditedAsync(
                            textStorage: storage,
                            editedRange: range,
                            language: lang,
                            fileName: name,
                            font: font,
                            generation: gen
                        )
                    }
                } else if isLargeFile {
                    self.scheduleViewportHighlighting(textView: tv)
                } else {
                    self.highlightTask = Task { @MainActor in
                        await SyntaxHighlighter.shared.highlightAsync(
                            textStorage: storage,
                            language: lang,
                            fileName: name,
                            font: font,
                            generation: gen
                        )
                    }
                }
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + highlightDelay, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportStateChange()
            updateBracketHighlight()
        }

        /// Предыдущие позиции подсвеченных скобок (для очистки).
        private var previousBracketRanges: [NSRange] = []

        /// Цвет подсветки парных скобок.
        private let bracketHighlightColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.15)
            } else {
                return NSColor.black.withAlphaComponent(0.12)
            }
        }

        private func updateBracketHighlight() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let storage = textView.textStorage else { return }

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            defer { undoManager?.enableUndoRegistration() }
            storage.beginEditing()

            // Снимаем предыдущую подсветку
            for range in previousBracketRanges where range.location + range.length <= storage.length {
                storage.removeAttribute(CodeEditorView.bracketHighlightKey, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            }
            previousBracketRanges = []

            // Ищем новую пару скобок
            let cursorRange = textView.selectedRange()
            if cursorRange.length == 0 {
                let fullText = textView.string
                let nsFullText = fullText as NSString

                // Try windowed search first (±5000 chars) to avoid scanning the entire
                // file with regex on every cursor move. Window boundaries are aligned to
                // line starts/ends via NSString.lineRange to avoid slicing through
                // comment/string delimiters (e.g. cutting "/*" in half).
                let bracketSearchRadius = 5000
                let rawStart = max(0, cursorRange.location - bracketSearchRadius)
                let rawEnd = min(nsFullText.length, cursorRange.location + bracketSearchRadius)
                let alignedStart = nsFullText.lineRange(
                    for: NSRange(location: rawStart, length: 0)
                ).location
                let alignedEndRange = nsFullText.lineRange(
                    for: NSRange(location: rawEnd, length: 0)
                )
                let alignedEnd = min(NSMaxRange(alignedEndRange), nsFullText.length)
                let searchRange = NSRange(location: alignedStart, length: alignedEnd - alignedStart)
                let isFullRange = alignedStart == 0 && alignedEnd == nsFullText.length

                if let result = bracketMatchInRange(
                    nsFullText, searchRange: searchRange,
                    cursorLocation: cursorRange.location, storage: storage
                ) {
                    previousBracketRanges = result
                } else if !isFullRange {
                    // Fallback: full-file scan when the match is beyond the window
                    let fullRange = NSRange(location: 0, length: nsFullText.length)
                    if let result = bracketMatchInRange(
                        nsFullText, searchRange: fullRange,
                        cursorLocation: cursorRange.location, storage: storage
                    ) {
                        previousBracketRanges = result
                    }
                }
            }

            storage.endEditing()
        }

        /// Searches for a bracket match within the given range and applies highlight attributes.
        /// Returns the highlighted ranges on success, nil if no match found.
        private func bracketMatchInRange(
            _ source: NSString,
            searchRange: NSRange,
            cursorLocation: Int,
            storage: NSTextStorage
        ) -> [NSRange]? {
            let substring = source.substring(with: searchRange)
            let localCursor = cursorLocation - searchRange.location

            let skipRanges = SyntaxHighlighter.shared.commentAndStringRanges(
                in: substring,
                language: parent.language,
                fileName: parent.fileName
            )

            guard let match = BracketMatcher.findMatch(
                in: substring,
                cursorPosition: localCursor,
                skipRanges: skipRanges
            ) else { return nil }

            let openerRange = NSRange(location: match.opener + searchRange.location, length: 1)
            let closerRange = NSRange(location: match.closer + searchRange.location, length: 1)

            for range in [openerRange, closerRange] {
                storage.addAttribute(.backgroundColor, value: bracketHighlightColor, range: range)
                storage.addAttribute(CodeEditorView.bracketHighlightKey, value: true, range: range)
            }

            return [openerRange, closerRange]
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            reportStateChange()
            highlightOnScrollIfNeeded()
        }

        /// Подсвечивает видимую область при скролле (для больших файлов).
        private func highlightOnScrollIfNeeded() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let storage = textView.textStorage,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let textLength = storage.length
            guard textLength > CodeEditorView.viewportHighlightThreshold,
                  !parent.syntaxHighlightingDisabled else { return }

            let visibleRect = sv.contentView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil
            )

            // Skip if visible range is already within highlighted range
            if let highlighted = highlightedCharRange,
               highlighted.location <= charRange.location,
               NSMaxRange(highlighted) >= NSMaxRange(charRange) {
                return
            }

            // Debounce 16ms (1 frame)
            scrollHighlightWorkItem?.cancel()
            highlightTask?.cancel()
            highlightGeneration.increment()
            let gen = highlightGeneration
            let lang = self.parent.language
            let name = self.parent.fileName
            let font = self.parent.editorFont
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      let storage = textView.textStorage else { return }

                self.highlightTask = Task { @MainActor [weak self] in
                    await SyntaxHighlighter.shared.highlightVisibleRangeAsync(
                        textStorage: storage,
                        visibleCharRange: charRange,
                        language: lang,
                        fileName: name,
                        font: font,
                        generation: gen
                    )

                    guard let self else { return }
                    // Union new highlighted range with existing
                    if let existing = self.highlightedCharRange {
                        let newStart = min(existing.location, charRange.location)
                        let newEnd = max(NSMaxRange(existing), NSMaxRange(charRange))
                        self.highlightedCharRange = NSRange(location: newStart, length: newEnd - newStart)
                    } else {
                        self.highlightedCharRange = charRange
                    }
                }
            }
            scrollHighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + scrollHighlightDelay, execute: workItem)
        }

        @objc func handleToggleComment() {
            guard let sv = scrollView,
                  let gutterView = sv.documentView as? GutterTextView,
                  gutterView.window?.isKeyWindow == true else { return }
            gutterView.toggleComment()
        }

        // MARK: - Multi-cursor (Cmd+D, Cmd+Shift+L)

        @objc func handleSelectNextOccurrence() {
            guard let sv = scrollView,
                  let gutterView = sv.documentView as? GutterTextView,
                  gutterView.window?.isKeyWindow == true else { return }
            gutterView.selectNextOccurrence()
        }

        @objc func handleSplitSelectionIntoLines() {
            guard let sv = scrollView,
                  let gutterView = sv.documentView as? GutterTextView,
                  gutterView.window?.isKeyWindow == true else { return }
            gutterView.splitSelectionIntoLines()
        }

        // MARK: - Find & Replace (issue #275)

        /// Sends a `performTextFinderAction` to the text view with the given action tag.
        /// Internal access for testability.
        func performFindAction(_ action: NSTextFinder.Action) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? GutterTextView,
                  textView.window?.isKeyWindow == true else { return }
            let menuItem = NSMenuItem()
            menuItem.tag = action.rawValue
            textView.performTextFinderAction(menuItem)
        }

        @objc func handleFindInFile() { performFindAction(.showFindInterface) }
        @objc func handleFindAndReplace() { performFindAction(.showReplaceInterface) }
        @objc func handleFindNext() { performFindAction(.nextMatch) }
        @objc func handleFindPrevious() { performFindAction(.previousMatch) }
        @objc func handleUseSelectionForFind() { performFindAction(.setSearchString) }

        // MARK: - Code folding

        /// Recalculates foldable ranges from the current text.
        func recalculateFoldableRanges() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }
            let text = textView.string
            // Update cache if not yet initialized (e.g. called from updateNSView on first load)
            if lineStartsCache == nil {
                lineStartsCache = LineStartsCache(text: text)
            }
            let skipRanges = SyntaxHighlighter.shared.commentAndStringRanges(
                in: text,
                language: parent.language,
                fileName: parent.fileName
            )
            foldableRanges = FoldRangeCalculator.calculate(text: text, skipRanges: skipRanges)
            lineNumberView?.foldableRanges = foldableRanges
            lineNumberView?.lineStartsCache = lineStartsCache
        }

        /// Schedules a debounced fold recalculation.
        private func scheduleFoldRecalculation() {
            foldWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.recalculateFoldableRanges()
            }
            foldWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + highlightDelay, execute: workItem)
        }

        /// Handles fold toggle from gutter click.
        func handleFoldToggle(_ foldable: FoldableRange) {
            parent.foldState.toggle(foldable)
            applyFoldState()
        }

        /// Handles fold code notifications from menu/keyboard shortcuts.
        @objc func handleFoldCode(_ notification: Notification) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? GutterTextView,
                  textView.window?.isKeyWindow == true,
                  let action = notification.userInfo?["action"] as? String else { return }

            switch action {
            case "fold":
                foldAtCursor()
            case "unfold":
                unfoldAtCursor()
            case "foldAll":
                parent.foldState.foldAll(foldableRanges)
                applyFoldState()
            case "unfoldAll":
                parent.foldState.unfoldAll()
                applyFoldState()
            default:
                break
            }
        }

        /// Folds the innermost foldable range containing the cursor.
        private func foldAtCursor() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let cache = lineStartsCache else { return }
            let cursorLocation = textView.selectedRange().location

            // Find cursor's line number using cached binary search
            let cursorLine = cache.lineNumber(at: cursorLocation)

            // Find innermost unfoldable range at cursor line
            let candidates = foldableRanges.filter {
                cursorLine >= $0.startLine && cursorLine <= $0.endLine
                    && !parent.foldState.isFolded($0)
            }
            // Pick the innermost (smallest span)
            if let best = candidates.min(by: { ($0.endLine - $0.startLine) < ($1.endLine - $1.startLine) }) {
                parent.foldState.fold(best)
                applyFoldState()
            }
        }

        /// Unfolds the fold at the cursor position.
        private func unfoldAtCursor() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let cache = lineStartsCache else { return }
            let cursorLocation = textView.selectedRange().location

            // Find cursor's line number using cached binary search
            let cursorLine = cache.lineNumber(at: cursorLocation)

            // Find folded range whose startLine matches cursor line
            if let folded = parent.foldState.foldedRanges.first(where: { $0.startLine == cursorLine }) {
                parent.foldState.unfold(folded)
                applyFoldState()
            }
        }

        /// Applies the current fold state to the layout manager and redraws.
        private func applyFoldState() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager else { return }

            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            lineNumberView?.foldState = parent.foldState
            // Invalidate glyphs so shouldGenerateGlyphs re-evaluates hidden lines,
            // then invalidate layout so shouldSetLineFragmentRect collapses heights.
            layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            textView.needsDisplay = true
            lineNumberView?.needsDisplay = true
            minimapView?.needsDisplay = true
        }

        // MARK: - NSLayoutManagerDelegate (code folding)

        // swiftlint:disable:next function_parameter_count
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard !parent.foldState.foldedRanges.isEmpty,
                  let cache = lineStartsCache else { return 0 }

            let count = glyphRange.length
            let modifiedProps = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
            defer { modifiedProps.deallocate() }

            // Single pass: cache hidden state per charIndex to avoid redundant lookups
            // (adjacent glyphs often share the same charIndex or line).
            var hasHidden = false
            var prevCharIndex = -1
            var prevHidden = false

            for i in 0..<count {
                let charIndex = charIndexes[i]
                let isHidden: Bool
                if charIndex == prevCharIndex {
                    isHidden = prevHidden
                } else {
                    let line = cache.lineNumber(at: charIndex)
                    isHidden = parent.foldState.isLineHidden(line)
                    prevCharIndex = charIndex
                    prevHidden = isHidden
                }
                if isHidden {
                    modifiedProps[i] = .null
                    hasHidden = true
                } else {
                    modifiedProps[i] = props[i]
                }
            }

            guard hasHidden else { return 0 }

            layoutManager.setGlyphs(
                glyphs, properties: modifiedProps,
                characterIndexes: charIndexes, font: aFont,
                forGlyphRange: glyphRange
            )
            return count
        }

        // swiftlint:disable:next function_parameter_count
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard !parent.foldState.foldedRanges.isEmpty else { return false }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            // Use cached line starts for O(log n) lookup
            guard let cache = lineStartsCache else { return false }
            let line = cache.lineNumber(at: charRange.location)

            // If this line is hidden (inside a folded region), collapse it to zero height
            if parent.foldState.isLineHidden(line) {
                lineFragmentRect.pointee.size.height = 0
                lineFragmentUsedRect.pointee.size.height = 0
                baselineOffset.pointee = 0
                return true
            }

            return false
        }

        private func reportStateChange() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }
            let cursor = textView.selectedRange().location
            let scroll = sv.contentView.bounds.origin.y
            parent.onStateChange?(cursor, scroll)
        }
    }

    /// Estimates the initial visible char range before layout is complete.
    /// Uses cursor position or scroll offset to guess which part of the file is visible.
    /// Falls back to the first ~200 lines if no saved state.
    private static let estimatedScreenLines = 200

    private static func estimateInitialRange(
        text: String,
        scrollOffset: CGFloat,
        cursorPosition: Int,
        fontSize: CGFloat
    ) -> NSRange {
        let source = text as NSString
        let totalLength = source.length
        guard totalLength > 0 else { return NSRange(location: 0, length: 0) }

        // If restoring scroll position, estimate start from line height
        let startChar: Int
        if scrollOffset > 0 {
            let lineHeight = fontSize * 1.2
            let estimatedLine = Int(scrollOffset / lineHeight)
            startChar = charOffsetForLine(estimatedLine, in: source, totalLength: totalLength)
        } else if cursorPosition > 0 && cursorPosition < totalLength {
            // Center around cursor
            let linesBefore = estimatedScreenLines / 2
            let cursorLine = lineNumber(at: cursorPosition, in: source)
            let startLine = max(0, cursorLine - linesBefore)
            startChar = charOffsetForLine(startLine, in: source, totalLength: totalLength)
        } else {
            startChar = 0
        }

        // Find end: startChar + estimatedScreenLines lines
        var linesFound = 0
        var end = startChar
        while end < totalLength && linesFound < estimatedScreenLines {
            if source.character(at: end) == 0x0A { linesFound += 1 }
            end += 1
        }

        return NSRange(location: startChar, length: end - startChar)
    }

    private static func charOffsetForLine(_ line: Int, in source: NSString, totalLength: Int) -> Int {
        var currentLine = 0
        for i in 0..<totalLength {
            if currentLine >= line { return i }
            if source.character(at: i) == 0x0A { currentLine += 1 }
        }
        return totalLength
    }

    private static func lineNumber(at charOffset: Int, in source: NSString) -> Int {
        var line = 0
        for i in 0..<min(charOffset, source.length) where source.character(at: i) == 0x0A {
            line += 1
        }
        return line
    }

    /// Применяет viewport-based подсветку: подсвечивает только видимую область.
    private func applyViewportHighlighting(
        textView: NSTextView,
        scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        SyntaxHighlighter.shared.highlightVisibleRange(
            textStorage: storage,
            visibleCharRange: charRange,
            language: language,
            fileName: fileName,
            font: editorFont
        )
        coordinator.highlightedCharRange = charRange
    }

    private func applyHighlighting(to textView: NSTextView) {
        guard !syntaxHighlightingDisabled else { return }
        guard let storage = textView.textStorage else { return }
        SyntaxHighlighter.shared.highlight(
            textStorage: storage,
            language: language,
            fileName: fileName,
            font: editorFont
        )
    }
}

// MARK: - NSImage tinting

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = copy() as! NSImage // swiftlint:disable:this force_cast
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
