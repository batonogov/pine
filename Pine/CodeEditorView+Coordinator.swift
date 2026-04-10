//
//  CodeEditorView+Coordinator.swift
//  Pine
//
//  Extracted from CodeEditorView.swift on 2026-04-09 (issue #755).
//
//  This file hosts CodeEditorView.Coordinator — the NSTextViewDelegate,
//  NSTextStorageDelegate, and NSLayoutManagerDelegate that drives the
//  editor's runtime behavior:
//    • Content/font synchronization
//    • Debounced syntax highlighting (edit + scroll paths)
//    • Bracket matching highlight
//    • Find & Replace routing
//    • Send-to-terminal
//    • Code folding and layout-manager fold callbacks
//    • External-reload handling
//
//  The class is nested in CodeEditorView via an extension so callers still
//  refer to it as `CodeEditorView.Coordinator` and `makeCoordinator()`
//  continues to work without changes.
//

import SwiftUI
import AppKit

extension CodeEditorView {
    class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
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

        /// Edited range captured from NSTextStorageDelegate before processEditing
        /// resets it to NSNotFound. Used by textDidChange for incremental highlighting.
        var pendingEditedRange: NSRange?

        /// Change in length captured alongside pendingEditedRange from
        /// NSTextStorageDelegate. Used for incremental lineStartsCache update.
        var pendingChangeInLength: Int = 0

        /// Last consumed navigation request ID — prevents re-processing.
        var lastGoToID: UUID?

        /// Generation counter for cancelling stale async highlight requests.
        let highlightGeneration = HighlightGeneration()

        /// Отложенная задача подсветки (дебаунсинг)
        private var highlightWorkItem: DispatchWorkItem?
        /// Active async highlight task (cancelled when new highlight is scheduled)
        private var highlightTask: Task<Void, Never>?

        /// Replaces the current highlight task, cancelling any in-flight one.
        func setHighlightTask(_ task: Task<Void, Never>) {
            highlightTask?.cancel()
            highlightTask = task
        }
        /// Задержка дебаунсинга
        private let highlightDelay: TimeInterval = 0.1

        /// True while `updateContentIfNeeded` is replacing text programmatically.
        /// Prevents `textDidChange` from scheduling a competing debounced highlight
        /// that would invalidate the full highlight started by `updateContentIfNeeded`.
        private var isProgrammaticTextChange = false

        /// Диапазон символов, уже подсвеченных viewport-based подсветкой.
        /// Internal access — записывается из `applyViewportHighlighting` и `highlightOnScrollIfNeeded`.
        var highlightedCharRange: NSRange?
        /// Дебаунс для подсветки при скролле.
        private var scrollHighlightWorkItem: DispatchWorkItem?
        /// Задержка дебаунсинга скролла (~3 кадра при 120fps ProMotion)
        private let scrollHighlightDelay: TimeInterval = 0.050
        /// Задержка дебаунсинга пересчёта фолдинга (тяжелее подсветки)
        private let foldRecalcDelay: TimeInterval = 0.15

        init(parent: CodeEditorView) {
            self.parent = parent
            // Initialize language/fileName to match the initial view,
            // preventing a false languageChanged detection on the first
            // updateNSView call (issue #556).
            self.lastLanguage = parent.language
            self.lastFileName = parent.fileName
            super.init()
            // Listen for external file reload notifications. SwiftUI's
            // @Observable + Binding pipeline does not always reliably
            // re-render an NSViewRepresentable when an array element's
            // inner property mutates (issue #734) — this notification is
            // a robust fallback that directly forces the NSTextView to
            // resync from disk.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTabReloadedFromDisk(_:)),
                name: .tabReloadedFromDisk,
                object: nil
            )
        }

        /// Handles `.tabReloadedFromDisk` notification — if the URL matches
        /// this editor's file, forcibly replaces the NSTextView contents with
        /// the new text from disk and re-applies syntax highlighting.
        ///
        /// Cursor position and scroll offset are preserved on a best-effort
        /// basis (clamped if the new content is shorter).
        @objc func handleTabReloadedFromDisk(_ note: Notification) {
            guard let url = note.userInfo?["url"] as? URL,
                  let newText = note.userInfo?["text"] as? String,
                  let parentURL = parent.fileURL,
                  url == parentURL else { return }
            applyExternalReload(text: newText)
        }

        /// Forcibly replaces NSTextView contents with externally-loaded text.
        /// Preserves cursor and scroll offset (clamped to new bounds).
        /// Re-runs syntax highlighting and fold recalculation.
        func applyExternalReload(text newText: String) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }

            // Skip if content already matches (idempotent against rapid reloads)
            if textView.string == newText { return }

            // Capture cursor and scroll for best-effort restore
            let oldRange = textView.selectedRange()
            let oldVisibleRect = sv.contentView.documentVisibleRect

            cancelPendingHighlight()
            if let storage = textView.textStorage {
                SyntaxHighlighter.shared.invalidateCache(for: storage)
            }
            previousBracketRanges = []

            isProgrammaticTextChange = true
            pendingEditedRange = nil
            pendingChangeInLength = 0
            textView.string = newText
            isProgrammaticTextChange = false

            // Bump version counter so the next updateNSView from SwiftUI
            // (which may carry a stale `text` value) does not re-trigger
            // a redundant replacement.
            lastContentVersion = parent.contentVersion

            // Restore cursor (clamped) and scroll
            let newLength = (newText as NSString).length
            let clampedLoc = min(oldRange.location, newLength)
            let clampedLen = min(oldRange.length, newLength - clampedLoc)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            textView.scroll(oldVisibleRect.origin)

            // Re-run syntax highlighting and fold calculation
            if !parent.syntaxHighlightingDisabled, let storage = textView.textStorage {
                if storage.length > CodeEditorView.viewportHighlightThreshold {
                    scheduleViewportHighlightingPublic(textView: textView)
                } else {
                    let result = SyntaxHighlighter.shared.highlight(
                        textStorage: storage,
                        language: parent.language,
                        fileName: parent.fileName,
                        font: NSFont.monospacedSystemFont(
                            ofSize: parent.fontSize, weight: .regular
                        )
                    )
                    if let result {
                        parent.onHighlightCacheUpdate?(result)
                    }
                }
            }

            lineStartsCache = LineStartsCache(text: newText)
            scheduleFoldRecalculation()
            reportStateChange()
        }

        /// Public wrapper around `scheduleViewportHighlighting` for use from
        /// `applyExternalReload`. Internal access for testability.
        func scheduleViewportHighlightingPublic(textView: NSTextView) {
            scheduleViewportHighlighting(textView: textView)
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

            cancelPendingHighlight()
            if let storage = textView.textStorage {
                SyntaxHighlighter.shared.invalidateCache(for: storage)
            }

            // Only replace NSTextView text when content actually differs.
            // contentVersion can be bumped even for identical text (e.g., by
            // updateContent with the same string), and textView.string = text
            // strips all attributes (isRichText = false), destroying syntax
            // highlighting (issue #556).
            if textChanged && textView.string != text {
                isProgrammaticTextChange = true
                pendingEditedRange = nil
                pendingChangeInLength = 0
                textView.string = text
                isProgrammaticTextChange = false
            }

            if !parent.syntaxHighlightingDisabled, let storage = textView.textStorage {
                if storage.length > CodeEditorView.viewportHighlightThreshold {
                    scheduleViewportHighlighting(textView: textView)
                } else if let cached = parent.cachedHighlightResult, !languageChanged {
                    // Apply cached highlights synchronously to avoid flash on tab switch.
                    // Skip cache when language changed — the cached result has old grammar matches.
                    SyntaxHighlighter.shared.applyMatches(cached, to: storage, font: font)
                } else {
                    // No cache — apply synchronous highlight for instant display.
                    if let result = SyntaxHighlighter.shared.highlight(
                        textStorage: storage,
                        language: language,
                        fileName: fileName,
                        font: font
                    ) {
                        parent.onHighlightCacheUpdate?(result)
                    }
                }
            }

            lastLanguage = language
            lastFileName = fileName

            // Restore cursor position and scroll offset on tab switch.
            // When text changed externally (not from user typing), restore
            // the saved per-tab cursor/scroll state and recalculate foldable ranges.
            if textChanged && !fromTextView {
                // Rebuild line starts cache for the new content
                lineStartsCache = LineStartsCache(text: text)

                let cursorPos = parent.initialCursorPosition
                let scrollOffset = parent.initialScrollOffset
                let safePosition = min(cursorPos, (textView.string as NSString).length)
                if safePosition > 0 {
                    textView.setSelectedRange(NSRange(location: safePosition, length: 0))
                }
                // Force layout synchronously so scroll restoration happens in
                // the same frame, eliminating the visible jump (issue #595).
                if let lm = textView.layoutManager, let tc = textView.textContainer {
                    lm.ensureLayout(for: tc)
                }
                if scrollOffset > 0 {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
                    sv.reflectScrolledClipView(sv.contentView)
                } else if safePosition > 0 {
                    textView.scrollRangeToVisible(NSRange(location: safePosition, length: 0))
                }
                minimapView?.needsDisplay = true
                recalculateFoldableRanges()
            }
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
                    highlightTask = Task { @MainActor [weak self] in
                        let result = await SyntaxHighlighter.shared.highlightAsync(
                            textStorage: storage,
                            language: lang,
                            fileName: name,
                            font: font,
                            generation: gen
                        )
                        if let result {
                            self?.parent.onHighlightCacheUpdate?(result)
                        }
                    }
                }
            }

            // Update gutter font
            lineNumberView?.gutterFont = gutterFont
            lineNumberView?.editorFont = font
            lineNumberView?.needsDisplay = true
        }

        // MARK: - NSTextStorageDelegate

        /// Captures editedRange before NSTextStorage.processEditing() resets it
        /// to NSNotFound. This range is consumed by textDidChange for incremental
        /// highlighting — without it, every edit falls back to a full re-highlight.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            if editedMask.contains(.editedCharacters), !isProgrammaticTextChange {
                pendingEditedRange = editedRange
                pendingChangeInLength = delta
            }
        }

        /// True while undo/redo is in progress. Prevents syntax highlighting
        /// from modifying NSTextStorage attributes concurrently with the undo
        /// manager's grouped operations, which causes EXC_BAD_ACCESS (#650).
        private(set) var isUndoRedoInProgress = false

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            // Always reset at the start of every textDidChange — prevents the flag
            // from "sticking" if a previous deferred highlightWorkItem was cancelled
            // before it could clear the flag (#650 review).
            isUndoRedoInProgress = false

            // When text was replaced programmatically by updateContentIfNeeded,
            // skip highlight scheduling — updateContentIfNeeded handles its own
            // full highlight. Only update caches that it doesn't handle.
            if isProgrammaticTextChange {
                pendingEditedRange = nil
                pendingChangeInLength = 0
                previousBracketRanges = []
                highlightedCharRange = nil
                reportStateChange()
                lineStartsCache = LineStartsCache(text: textView.string)
                scheduleFoldRecalculation()
                return
            }

            // Detect undo/redo in progress. When the undo manager is unwinding
            // grouped operations, modifying NSTextStorage attributes (via syntax
            // highlighting beginEditing/endEditing) can cause a race condition
            // leading to EXC_BAD_ACCESS. We defer highlighting until the undo
            // manager finishes its current operation (#650).
            let undoing = textView.undoManager?.isUndoing == true
            let redoing = textView.undoManager?.isRedoing == true
            isUndoRedoInProgress = undoing || redoing

            // Mark that this change originated from the user typing,
            // so the upcoming updateNSView won't overwrite the text and reset the cursor.
            didChangeFromTextView = true
            parent.text = textView.string

            // Подсветка синтаксиса сбросит backgroundColor —
            // считаем bracket highlight невалидным
            previousBracketRanges = []

            // Report state change
            reportStateChange()

            // Update line starts cache incrementally if possible, otherwise full rebuild.
            // We use pendingEditedRange / pendingChangeInLength captured by the
            // NSTextStorageDelegate — by the time textDidChange fires,
            // storage.editedRange is already reset to NSNotFound.
            if var cache = lineStartsCache,
               let editRange = pendingEditedRange {
                cache.update(
                    editedRange: editRange,
                    changeInLength: pendingChangeInLength,
                    in: textView.string as NSString
                )
                lineStartsCache = cache
            } else {
                lineStartsCache = LineStartsCache(text: textView.string)
            }

            // Recalculate foldable ranges (debounced — expensive operation)
            scheduleFoldRecalculation()

            // Consume the edited range captured by NSTextStorageDelegate.
            // NSTextStorage.editedRange is already reset to NSNotFound by the
            // time textDidChange fires, so we rely on pendingEditedRange instead.
            let editedRange = pendingEditedRange
            pendingEditedRange = nil
            pendingChangeInLength = 0

            // Skip highlighting for large files opened without syntax highlighting
            guard !parent.syntaxHighlightingDisabled else { return }

            // Инвалидируем highlightedCharRange — вставка/удаление текста
            // сдвигает символьные смещения, старый диапазон некорректен
            highlightedCharRange = nil

            // During undo/redo, cancel any pending highlight and schedule a
            // deferred full re-highlight. The undo manager may still be processing
            // grouped operations — modifying textStorage attributes now would cause
            // EXC_BAD_ACCESS (#650).
            if isUndoRedoInProgress {
                scheduleDeferredHighlight(editedRange: nil)
                return
            }

            // Дебаунсинг: откладываем подсветку до паузы в вводе.
            // Не накапливаем диапазоны — каждый textDidChange работает
            // в своих координатах; union между версиями некорректен.
            // При быстром вводе последовательные правки обычно смежны,
            // и 20-строчный контекст в highlightEdited покрывает их.
            scheduleDeferredHighlight(editedRange: editedRange)
        }

        /// Cancels any in-flight highlight work and schedules a new debounced
        /// highlight pass. When `editedRange` is non-nil, an incremental
        /// `highlightEditedAsync` is attempted first; otherwise a full
        /// re-highlight runs.
        ///
        /// Called from both normal edits and undo/redo paths to avoid
        /// duplicating the scheduling logic.
        private func scheduleDeferredHighlight(editedRange: NSRange?) {
            highlightWorkItem?.cancel()
            highlightTask?.cancel()

            // Two-phase generation increment (#659):
            //
            // 1) Immediate increment (here): invalidates any in-flight Task spawned
            //    by a prior edit. If that Task's background work finishes during the
            //    debounce window, it will compare its captured generation against the
            //    (now-bumped) current value, see a mismatch, and discard its stale
            //    results instead of applying outdated colors.
            //
            // 2) Second increment (inside the workItem, line ~1186): captures a fresh
            //    generation for the NEW Task that is about to be created. Without this,
            //    the new Task would reuse the generation from step 1, which could
            //    already be stale if yet another edit arrives before the Task checks.
            //
            // Both are required: without (1) stale Tasks aren't rejected; without (2)
            // new Tasks use a generation that a subsequent edit has already invalidated.
            highlightGeneration.increment()

            let isUndoRedo = isUndoRedoInProgress

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }

                // Clear the undo/redo flag now that we're past the danger zone.
                if isUndoRedo {
                    self.isUndoRedoInProgress = false
                }

                guard let sv = self.scrollView,
                      let tv = sv.documentView as? NSTextView,
                      let storage = tv.textStorage else { return }

                // Double-check: if an undo/redo started between scheduling and
                // execution, bail out to avoid the same race condition.
                if tv.undoManager?.isUndoing == true || tv.undoManager?.isRedoing == true {
                    return
                }

                self.highlightGeneration.increment()
                let gen = self.highlightGeneration
                let lang = self.parent.language
                let name = self.parent.fileName
                let font = self.parent.editorFont
                let isLargeFile = storage.length > CodeEditorView.viewportHighlightThreshold

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
                    self.highlightTask = Task { @MainActor [weak self] in
                        let result = await SyntaxHighlighter.shared.highlightAsync(
                            textStorage: storage,
                            language: lang,
                            fileName: name,
                            font: font,
                            generation: gen
                        )
                        if let result {
                            self?.parent.onHighlightCacheUpdate?(result)
                        }
                    }
                }
            }
            highlightWorkItem = workItem
            // During undo/redo, dispatch on next run loop iteration so the undo
            // manager finishes its grouped operations before we touch textStorage.
            // Normal edits use the standard debounce delay.
            let delay: TimeInterval = isUndoRedo ? 0 : highlightDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportStateChange()
            updateBracketHighlight()
        }

        /// Предыдущие позиции подсвеченных скобок (для очистки).
        private var previousBracketRanges: [NSRange] = []

        /// Цвет подсветки парных скобок (matched).
        private let bracketHighlightColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.15)
            } else {
                return NSColor.black.withAlphaComponent(0.12)
            }
        }

        /// Цвет подсветки orphan-скобки (unmatched).
        private let unmatchedBracketColor = NSColor.systemRed.withAlphaComponent(0.20)

        private func updateBracketHighlight() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager else { return }

            // Снимаем предыдущую подсветку (temporary attributes на layout manager)
            let fullLength = textView.textStorage?.length ?? 0
            for range in previousBracketRanges where range.location + range.length <= fullLength {
                layoutManager.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: range
                )
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
                let bracketSearchRadius = EditorConstants.bracketSearchRadius
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

                if let result = bracketHighlightInRange(
                    nsFullText, searchRange: searchRange,
                    cursorLocation: cursorRange.location, layoutManager: layoutManager
                ) {
                    previousBracketRanges = result
                } else if !isFullRange {
                    // Fallback: full-file scan when the match is beyond the window
                    let fullRange = NSRange(location: 0, length: nsFullText.length)
                    if let result = bracketHighlightInRange(
                        nsFullText, searchRange: fullRange,
                        cursorLocation: cursorRange.location, layoutManager: layoutManager
                    ) {
                        previousBracketRanges = result
                    }
                }
            }
        }

        /// Searches for a bracket at cursor within the given range and applies
        /// temporary highlight attributes on the layout manager.
        /// Returns the highlighted ranges on success, nil if no bracket near cursor.
        private func bracketHighlightInRange(
            _ source: NSString,
            searchRange: NSRange,
            cursorLocation: Int,
            layoutManager: NSLayoutManager
        ) -> [NSRange]? {
            let substring = source.substring(with: searchRange)
            let localCursor = cursorLocation - searchRange.location

            let skipRanges = SyntaxHighlighter.shared.commentAndStringRanges(
                in: substring,
                language: parent.language,
                fileName: parent.fileName
            )

            guard let highlight = BracketMatcher.findHighlight(
                in: substring,
                cursorPosition: localCursor,
                skipRanges: skipRanges
            ) else { return nil }

            switch highlight {
            case .matched(let match):
                let openerRange = NSRange(location: match.opener + searchRange.location, length: 1)
                let closerRange = NSRange(location: match.closer + searchRange.location, length: 1)

                for range in [openerRange, closerRange] {
                    layoutManager.addTemporaryAttribute(
                        .backgroundColor, value: bracketHighlightColor,
                        forCharacterRange: range
                    )
                }
                return [openerRange, closerRange]

            case .unmatched(let position):
                let range = NSRange(location: position + searchRange.location, length: 1)
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: unmatchedBracketColor,
                    forCharacterRange: range
                )
                return [range]
            }
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

        // MARK: - Send to Terminal (issue #311)

        /// Extracts selected text (or current line if no selection) and posts
        /// `.sendTextToTerminal` notification with the text in userInfo.
        @objc func handleSendToTerminal() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? GutterTextView,
                  textView.window?.isKeyWindow == true else { return }

            let text = extractTextForTerminal(from: textView)
            guard !text.isEmpty else { return }

            // Flash highlight the sent text range for visual feedback
            flashSentTextHighlight(in: textView)

            NotificationCenter.default.post(
                name: .sendTextToTerminal,
                object: nil,
                userInfo: ["text": text]
            )
        }

        /// Returns selected text or the current line if nothing is selected.
        /// Internal access for testability.
        func extractTextForTerminal(from textView: NSTextView) -> String {
            let selectedRange = textView.selectedRange()
            let source = textView.string as NSString

            if selectedRange.length > 0 {
                // Has selection — return selected text
                guard selectedRange.location + selectedRange.length <= source.length else { return "" }
                return source.substring(with: selectedRange)
            } else {
                // No selection — return current line
                let lineRange = source.lineRange(for: NSRange(location: selectedRange.location, length: 0))
                var lineText = source.substring(with: lineRange)
                // Strip trailing newline
                if lineText.hasSuffix("\n") {
                    lineText = String(lineText.dropLast())
                }
                if lineText.hasSuffix("\r") {
                    lineText = String(lineText.dropLast())
                }
                return lineText
            }
        }

        /// Briefly highlights the sent text with a flash effect.
        private func flashSentTextHighlight(in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let source = textView.string as NSString
            let rangeToFlash: NSRange

            if selectedRange.length > 0 {
                rangeToFlash = selectedRange
            } else {
                rangeToFlash = source.lineRange(
                    for: NSRange(location: selectedRange.location, length: 0)
                )
            }

            guard rangeToFlash.location + rangeToFlash.length <= source.length else { return }

            let flashColor = NSColor.controlAccentColor.withAlphaComponent(0.3)
            textView.layoutManager?.addTemporaryAttribute(
                .backgroundColor,
                value: flashColor,
                forCharacterRange: rangeToFlash
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                textView.layoutManager?.removeTemporaryAttribute(
                    .backgroundColor,
                    forCharacterRange: rangeToFlash
                )
            }
        }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + foldRecalcDelay, execute: workItem)
        }

        /// Handles fold toggle from gutter click.
        func handleFoldToggle(_ foldable: FoldableRange) {
            parent.foldState.toggle(foldable)
            applyFoldState()
        }

        /// Toggles inline diff expansion for a hunk when user clicks a gutter diff marker.
        func handleDiffMarkerClick(_ hunk: DiffHunk) {
            guard let sv = scrollView,
                  let gutterView = sv.documentView as? GutterTextView else { return }

            let newID: UUID? = (gutterView.expandedHunkID == hunk.id) ? nil : hunk.id
            gutterView.expandedHunkID = newID
            lineNumberView?.expandedHunkID = newID
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
}
