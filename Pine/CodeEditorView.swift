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

    override var textContainerOrigin: NSPoint {
        // Сдвигаем текст вправо на ширину гуттера, вниз на 8pt для отступа сверху
        NSPoint(x: gutterInset, y: 8)
    }

    // MARK: - Highlight current line

    private let currentLineColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.06)
        } else {
            return NSColor.black.withAlphaComponent(0.06)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = layoutManager,
              textContainer != nil else { return }

        let cursorRange = selectedRange()
        // Подсвечиваем только когда нет выделения (просто курсор)
        guard cursorRange.length == 0 else { return }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: cursorRange.location)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        // Растягиваем на всю ширину view
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        // Учитываем textContainerOrigin
        lineRect.origin.y += textContainerOrigin.y

        currentLineColor.setFill()
        lineRect.fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
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
}

// MARK: - Editor container that manages scroll view + minimap layout

/// Custom container view that lays out the scroll view and minimap side by side.
/// Replaces autoresizingMask with explicit layout so the minimap width is
/// always accounted for.
final class EditorContainerView: NSView {
    var minimapWidth: CGFloat = 0

    override func layout() {
        super.layout()
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
                // LineNumberView — keep x=0, full height, its own width
                sub.frame = NSRect(
                    x: 0, y: 0,
                    width: sub.frame.width,
                    height: bounds.height
                )
            }
        }
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var fileName: String?
    var lineDiffs: [GitLineDiff] = []
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

    /// Пользовательский ключ атрибута для подсветки парных скобок.
    static let bracketHighlightKey = NSAttributedString.Key("PineBracketHighlight")

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
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        container.addSubview(scrollView)

        // ── Номера строк — поверх scroll view, как отдельный сиблинг ──
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.gutterWidth = gutterWidth
        lineNumberView.gutterFont = gutterFont
        container.addSubview(lineNumberView)

        // ── Minimap — справа от scroll view ──
        let minimapView = MinimapView(textView: textView)
        minimapView.isHidden = !isMinimapVisible
        container.addSubview(minimapView)

        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberView = lineNumberView
        context.coordinator.minimapView = minimapView
        context.coordinator.lastFontSize = editorFont.pointSize

        textView.string = text
        applyHighlighting(to: textView)

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

        // Keep GutterTextView's language info in sync for toggle comment
        if let sv = context.coordinator.scrollView,
           let gutterView = sv.documentView as? GutterTextView {
            gutterView.fileExtension = language
            gutterView.exactFileName = fileName
        }

        context.coordinator.updateContentIfNeeded(
            text: text,
            language: language,
            fileName: fileName,
            font: editorFont
        )

        // Обновляем шрифт при изменении размера (Cmd+Plus/Minus)
        context.coordinator.updateFontIfNeeded(font: editorFont, gutterFont: gutterFont)

        // Обновляем diff-данные LineNumberView
        if let lineNumberView = context.coordinator.lineNumberView {
            lineNumberView.lineDiffs = lineDiffs
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var scrollView: NSScrollView?
        var lineNumberView: LineNumberView?
        var minimapView: MinimapView?

        /// Последние язык/имя файла — для обнаружения смены грамматики
        /// при одинаковом содержимом файлов
        var lastLanguage: String = ""
        var lastFileName: String?
        /// Последний размер шрифта — для обнаружения изменений (Cmd+Plus/Minus)
        var lastFontSize: CGFloat = 0

        /// Отложенная задача подсветки (дебаунсинг)
        private var highlightWorkItem: DispatchWorkItem?
        /// Задержка дебаунсинга
        private let highlightDelay: TimeInterval = 0.05

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
        }

        /// Обновляет текст и подсветку при смене файла или языка.
        /// Вызывается из updateNSView. Выделен в отдельный метод
        /// для возможности прямого тестирования.
        func updateContentIfNeeded(text: String, language: String, fileName: String?, font: NSFont) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }

            let languageChanged = lastLanguage != language || lastFileName != fileName
            let textChanged = textView.string != text

            guard textChanged || languageChanged else { return }

            cancelPendingHighlight()
            if let storage = textView.textStorage {
                SyntaxHighlighter.shared.invalidateCache(for: storage)
            }

            if textChanged {
                textView.string = text
            }

            if !parent.syntaxHighlightingDisabled, let storage = textView.textStorage {
                SyntaxHighlighter.shared.highlight(
                    textStorage: storage,
                    language: language,
                    fileName: fileName,
                    font: font
                )
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
                SyntaxHighlighter.shared.highlight(
                    textStorage: storage,
                    language: parent.language,
                    fileName: parent.fileName,
                    font: font
                )
            }

            // Update gutter font
            lineNumberView?.gutterFont = gutterFont
            lineNumberView?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string

            // Подсветка синтаксиса сбросит backgroundColor —
            // считаем bracket highlight невалидным
            previousBracketRanges = []

            // Report state change
            reportStateChange()

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

            // Дебаунсинг: откладываем подсветку до паузы в вводе.
            // Не накапливаем диапазоны — каждый textDidChange работает
            // в своих координатах; union между версиями некорректен.
            // При быстром вводе последовательные правки обычно смежны,
            // и 20-строчный контекст в highlightEdited покрывает их.
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let sv = self.scrollView,
                      let tv = sv.documentView as? NSTextView,
                      let storage = tv.textStorage else { return }

                if let range = editedRange, range.location + range.length <= storage.length {
                    SyntaxHighlighter.shared.highlightEdited(
                        textStorage: storage,
                        editedRange: range,
                        language: self.parent.language,
                        fileName: self.parent.fileName,
                        font: self.parent.editorFont
                    )
                } else {
                    // Диапазон не определён или невалиден — полная подсветка
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage,
                        language: self.parent.language,
                        fileName: self.parent.fileName,
                        font: self.parent.editorFont
                    )
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
        }

        @objc func handleToggleComment() {
            guard let sv = scrollView,
                  let gutterView = sv.documentView as? GutterTextView,
                  gutterView.window?.isKeyWindow == true else { return }
            gutterView.toggleComment()
        }

        private func reportStateChange() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }
            let cursor = textView.selectedRange().location
            let scroll = sv.contentView.bounds.origin.y
            parent.onStateChange?(cursor, scroll)
        }
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
