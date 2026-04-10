//
//  CodeEditorView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//
//  This file now hosts only the SwiftUI `NSViewRepresentable` wrapper and
//  the initial view/viewport setup. Related responsibilities live in:
//
//    • GutterTextView.swift — NSTextView subclass (gutter inset, current line
//      highlight, inline diff, inline blame, auto-indent, comment toggling).
//    • EditorContainerViews.swift — EditorScrollView, EditorContainerView,
//      GoToRequest.
//    • CodeEditorView+Coordinator.swift — the Coordinator class driving
//      highlighting, folding, find, and every NS*Delegate callback.
//    • NSImage+Tinted.swift — shared NSImage tint helper used by gutter blame.
//
//  Split performed on 2026-04-09 as part of issue #755 — strictly mechanical,
//  no behavior change, no public API change.
//

import SwiftUI
import AppKit

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Monotonic version counter from EditorTab — O(1) change detection.
    var contentVersion: UInt64 = 0
    var language: String
    var fileName: String?
    /// Full file URL — used by the coordinator to match notifications targeting
    /// this specific tab (e.g., external file reloads).
    var fileURL: URL?
    var lineDiffs: [GitLineDiff] = []
    /// Monotonic counter bumped after every `refreshLineDiffs` completion.
    /// Forces SwiftUI to call `updateNSView` even when the `[GitLineDiff]`
    /// array comparison is optimized away (issue #809).
    var diffVersion: UInt64 = 0
    /// Diff hunks for inline diff expansion in the gutter.
    var diffHunks: [DiffHunk] = []
    /// Validation diagnostics for gutter icons (error/warning/info).
    var validationDiagnostics: [ValidationDiagnostic] = []
    /// Whether inline blame annotation is visible on the cursor line.
    var isBlameVisible: Bool = false
    /// Blame data for the current file.
    var blameLines: [GitBlameLine] = []
    /// Binding to the fold state for the active tab.
    @Binding var foldState: FoldState
    /// Whether the minimap panel is visible.
    var isMinimapVisible: Bool = true
    /// Whether word wrap is enabled (wrap at window edge vs. horizontal scroll).
    var isWordWrapEnabled: Bool = true
    /// Whether syntax highlighting is disabled for this tab (e.g. large files).
    var syntaxHighlightingDisabled: Bool = false
    /// Cursor position to restore when the view is created (tab switch).
    var initialCursorPosition: Int = 0
    /// Scroll offset to restore when the view is created (tab switch).
    var initialScrollOffset: CGFloat = 0
    /// Called when cursor position or scroll offset changes, so the caller can persist them.
    var onStateChange: ((Int, CGFloat) -> Void)?
    /// Called when a new syntax highlight result is computed, so the caller can cache it in the tab.
    var onHighlightCacheUpdate: ((HighlightMatchResult) -> Void)?
    /// Cached highlight result from the previous session of this tab.
    /// Applied synchronously on tab switch to eliminate the flash of unhighlighted text.
    var cachedHighlightResult: HighlightMatchResult?
    /// When non-nil, the editor scrolls to this offset. The `id` ensures each request is unique.
    var goToOffset: GoToRequest?
    /// Indentation style detected for the current file, used for indent guide rendering.
    var indentStyle: IndentationStyle = .spaces(4)

    /// Порог (в символах) для переключения на viewport-based подсветку.
    /// Lowered from 100KB to 50KB to be more aggressive about lazy highlighting (#637).
    static let viewportHighlightThreshold = 50_000

    /// Файл достаточно большой для viewport-based подсветки?
    private var useViewportHighlighting: Bool {
        (text as NSString).length > Self.viewportHighlightThreshold && !syntaxHighlightingDisabled
    }

    var fontSize: CGFloat = FontSizeSettings.shared.fontSize

    /// Editor font — internal access so Coordinator (in a separate file) can
    /// capture the current font when dispatching async highlight work.
    var editorFont: NSFont {
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
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !isWordWrapEnabled
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
        textContainer.widthTracksTextView = isWordWrapEnabled
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
        textView.isHorizontallyResizable = !isWordWrapEnabled
        textView.autoresizingMask = isWordWrapEnabled ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)

        textView.fileExtension = language
        textView.exactFileName = fileName
        textView.setBlameLines(blameLines)
        textView.isBlameVisible = isBlameVisible
        textView.indentStyle = indentStyle
        textView.addedLineNumbers = InlineDiffProvider.addedLineNumbers(from: diffHunks)
        textView.deletedLineBlocks = InlineDiffProvider.deletedLineBlocks(from: diffHunks)
        textView.diffHunksForHighlight = diffHunks
        // Delegate set AFTER text/highlight setup to prevent textDidChange from firing
        // during makeNSView and causing a spurious updateContent → cachedHighlightResult = nil
        // → contentVersion bump → updateNSView re-sets text → stripping highlight attributes.
        scrollView.documentView = textView

        container.addSubview(scrollView)

        // ── NSLayoutManager delegate for code folding ──
        layoutManager.delegate = context.coordinator

        // ── Номера строк — поверх scroll view, как отдельный сиблинг ──
        let lineNumberView = LineNumberView(textView: textView, clipView: scrollView.contentView)
        lineNumberView.gutterWidth = gutterWidth
        lineNumberView.gutterFont = gutterFont
        lineNumberView.editorFont = editorFont
        lineNumberView.foldState = foldState
        let coordinator = context.coordinator
        lineNumberView.onFoldToggle = { [weak coordinator] foldable in
            coordinator?.handleFoldToggle(foldable)
        }
        lineNumberView.diffHunks = diffHunks
        lineNumberView.validationDiagnostics = validationDiagnostics
        lineNumberView.onDiffMarkerClick = { [weak coordinator] hunk in
            coordinator?.handleDiffMarkerClick(hunk)
        }
        container.addSubview(lineNumberView)

        // ── Minimap — справа от scroll view ──
        let minimapView = MinimapView(textView: textView, clipView: scrollView.contentView)
        minimapView.isHidden = !isMinimapVisible
        container.addSubview(minimapView)

        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberView = lineNumberView
        context.coordinator.minimapView = minimapView
        context.coordinator.lastFontSize = editorFont.pointSize
        context.coordinator.syncContentVersion()

        textView.string = text
        if useViewportHighlighting {
            // Layout not yet complete — highlight first screenful asynchronously
            // to avoid blocking the main thread on tab open.
            let initialRange = Self.estimateInitialRange(
                text: text, scrollOffset: initialScrollOffset,
                cursorPosition: initialCursorPosition, fontSize: fontSize
            )
            let lang = language
            let file = fileName
            let font = editorFont
            context.coordinator.setHighlightTask(Task { @MainActor [weak coordinator = context.coordinator] in
                await SyntaxHighlighter.shared.highlightVisibleRangeAsync(
                    textStorage: textStorage,
                    visibleCharRange: initialRange,
                    language: lang,
                    fileName: file,
                    font: font
                )
                coordinator?.highlightedCharRange = initialRange
            })
        } else if let cached = cachedHighlightResult {
            // Apply cached highlights synchronously to avoid flash on tab switch.
            SyntaxHighlighter.shared.applyMatches(cached, to: textStorage, font: editorFont)
        } else {
            // No cache — apply synchronous highlight for instant display on tab switch.
            if !syntaxHighlightingDisabled {
                if let result = SyntaxHighlighter.shared.highlight(
                    textStorage: textStorage,
                    language: language,
                    fileName: fileName,
                    font: editorFont
                ) {
                    onHighlightCacheUpdate?(result)
                }
            }
        }

        // Set delegates now — after text and highlighting are configured,
        // so textDidChange won't fire during initial setup and cause a
        // re-highlight cycle that strips syntax colors (issue #556).
        textView.delegate = context.coordinator
        textStorage.delegate = context.coordinator

        // Restore cursor and scroll from saved per-tab state.
        // initialCursorPosition is stored as NSRange.location (UTF-16 offset),
        // so clamp against NSString.length, not Swift Character count.
        let safePosition = min(initialCursorPosition, (text as NSString).length)
        if safePosition > 0 {
            textView.setSelectedRange(NSRange(location: safePosition, length: 0))
        }

        // Force layout so scroll restoration can happen synchronously,
        // eliminating the visual jump from position 0 to the saved offset.
        let savedOffset = initialScrollOffset
        layoutManager.ensureLayout(for: textContainer)

        if savedOffset > 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: savedOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if safePosition > 0 {
            textView.scrollRangeToVisible(NSRange(location: safePosition, length: 0))
        }

        // Minimap redraw and first responder need the view to be in the window
        // hierarchy, so defer only those non-visual operations.
        DispatchQueue.main.async {
            minimapView.needsDisplay = true
            textView.window?.makeFirstResponder(textView)
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

        // Observe fold code notifications (Cmd+Option+arrows)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleFoldCode(_:)),
            name: .foldCode,
            object: nil
        )

        // Observe send to terminal notification (Cmd+Shift+Enter)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSendToTerminal),
            name: .sendToTerminal,
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

        // Word wrap toggle — update text container and scroll view
        if let sv = context.coordinator.scrollView,
           let gutterView = sv.documentView as? GutterTextView,
           let tc = gutterView.textContainer {
            let wrapChanged = tc.widthTracksTextView != isWordWrapEnabled
            if wrapChanged {
                tc.widthTracksTextView = isWordWrapEnabled
                gutterView.isHorizontallyResizable = !isWordWrapEnabled
                gutterView.autoresizingMask = isWordWrapEnabled ? [.width] : []
                sv.hasHorizontalScroller = !isWordWrapEnabled

                if isWordWrapEnabled {
                    // Reset width to scroll view content width so wrapping kicks in
                    let contentWidth = sv.contentSize.width
                    tc.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                    gutterView.frame.size.width = contentWidth
                } else {
                    tc.containerSize = NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                }

                gutterView.needsLayout = true
                gutterView.needsDisplay = true
                // Recalculate line numbers after wrap change
                context.coordinator.lineNumberView?.needsDisplay = true
            }
        }

        // Keep GutterTextView's language info and blame data in sync
        if let sv = context.coordinator.scrollView,
           let gutterView = sv.documentView as? GutterTextView {
            gutterView.fileExtension = language
            gutterView.exactFileName = fileName
            gutterView.indentStyle = indentStyle
            gutterView.setBlameLines(blameLines)
            if gutterView.isBlameVisible != isBlameVisible {
                gutterView.isBlameVisible = isBlameVisible
                gutterView.display()
            }
            // Update inline diff highlight data
            let newAddedLines = InlineDiffProvider.addedLineNumbers(from: diffHunks)
            let newDeletedBlocks = InlineDiffProvider.deletedLineBlocks(from: diffHunks)
            if gutterView.addedLineNumbers != newAddedLines
                || gutterView.deletedLineBlocks != newDeletedBlocks {
                gutterView.addedLineNumbers = newAddedLines
                gutterView.deletedLineBlocks = newDeletedBlocks
                gutterView.diffHunksForHighlight = diffHunks
                // Collapse expanded hunk when diff data changes (hunks may have shifted)
                if gutterView.expandedHunkID != nil {
                    gutterView.expandedHunkID = nil
                    context.coordinator.lineNumberView?.expandedHunkID = nil
                }
                gutterView.needsDisplay = true
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
            lineNumberView.diffHunks = diffHunks
            lineNumberView.validationDiagnostics = validationDiagnostics
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

    // MARK: - Initial viewport estimation

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
            if source.character(at: end) == ASCII.newline { linesFound += 1 }
            end += 1
        }

        return NSRange(location: startChar, length: end - startChar)
    }

    private static func charOffsetForLine(_ line: Int, in source: NSString, totalLength: Int) -> Int {
        var currentLine = 0
        for i in 0..<totalLength {
            if currentLine >= line { return i }
            if source.character(at: i) == ASCII.newline { currentLine += 1 }
        }
        return totalLength
    }

    private static func lineNumber(at charOffset: Int, in source: NSString) -> Int {
        var line = 0
        for i in 0..<min(charOffset, source.length) where source.character(at: i) == ASCII.newline {
            line += 1
        }
        return line
    }

    // MARK: - Viewport highlighting

    /// Применяет viewport-based подсветку: подсвечивает только видимую область.
    /// Internal access so Coordinator (in a separate file) can invoke it from
    /// its scheduleViewportHighlighting path.
    func applyViewportHighlighting(
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
}
