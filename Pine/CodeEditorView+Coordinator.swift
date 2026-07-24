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

        // MARK: - Completion (Phase 3, #1012)

        /// State object driving the completion popup. Owned by the coordinator
        /// so it survives SwiftUI re-renders and is shared with the AppKit
        /// popup container.
        let completionController = CompletionController()

        // MARK: - LSP UI Integration (Phase 5, milestone #1088, item 1)

        /// Hover popover manager. Lazily created on first hover request.
        private(set) var hoverPopoverManager: HoverPopoverManager?

        /// Definition quick-pick controller for multiple-definition results.
        /// Set from the parent view so the overlay and coordinator share the
        /// same observable instance.
        var definitionQuickPickController = DefinitionQuickPickController()

        /// Rename popover manager.
        private(set) var renamePopoverManager: RenamePopoverManager?

        /// Monotonic generation token for cancelling stale hover requests.
        /// Bumped before scheduling a new hover request.
        private var hoverGeneration: Int = 0

        /// The hover request task. Cancelled on every new hover or mouseExit.
        private var hoverTask: Task<Void, Never>?

        /// The AppKit popup container, lazily added to the editor container
        /// view on first presentation. Reused across presentations.
        private(set) var completionPopup: CompletionPopupContainer?

        /// Debounced completion request task. Cancelled on every new keystroke
        /// and when the popup is dismissed, so only the latest idle pause fires
        /// a request (generation-token pattern, matching highlight scheduling).
        private var completionTask: Task<Void, Never>?

        /// Monotonic generation token for cancelling stale completion
        /// requests. Bumped before scheduling a new request and checked after
        /// the async gap so a late server reply cannot show a stale popup.
        private var completionGeneration: Int = 0

        /// Whether the last character inserted was a completion trigger
        /// character for the current language. When `true`, the completion
        /// request fires immediately (no debounce) to feel responsive.
        private var lastInsertWasTrigger: Bool = false

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
        private let highlightDelay: TimeInterval = UITimings.Debounce.edit

        /// True while `updateContentIfNeeded` is replacing text programmatically.
        /// Prevents `textDidChange` from scheduling a competing debounced highlight
        /// that would invalidate the full highlight started by `updateContentIfNeeded`.
        private var isProgrammaticTextChange = false

        /// Диапазон символов, уже подсвеченных viewport-based подсветкой.
        /// Internal access — записывается из `applyViewportHighlighting` и `highlightOnScrollIfNeeded`.
        var highlightedCharRange: NSRange?
        /// Pending state change — coalesces multiple selection/scroll
        /// notifications within the same runloop so only the latest
        /// cursor/scroll wins, and breaks the synchronous reentrancy that
        /// caused the macOS 27 exclusivity abort (issue #1032).
        ///
        /// `onStateChange` mutates @Observable fields
        /// (cursorPosition/scrollOffset) on the active tab, which forces a
        /// synchronous SwiftUI re-render. When this happens inside an AppKit
        /// text-storage / selection-notification callstack (programmatic
        /// `setSelectedRange` after `replaceCharacters` — external reload,
        /// toggle comment, auto-indent, tab switch), the re-render collides
        /// with the outer callstack's exclusive access to `EnvironmentValues`
        /// and triggers `_swift_reportExclusivityConflict` → `abort()` on
        /// macOS 27 beta 1 where notification delivery became synchronous.
        ///
        /// Deferring to the next runloop breaks the reentrancy: the AppKit
        /// callstack unwinds first, THEN the @Observable mutation runs, so
        /// there is no overlap.
        private var deferredStateChange: (cursor: Int, scroll: CGFloat)?
        private var deferredStateChangeScheduled = false

        /// Дебаунс для подсветки при скролле.
        private var scrollHighlightWorkItem: DispatchWorkItem?
        /// Задержка дебаунсинга скролла (~3 кадра при 120fps ProMotion)
        private let scrollHighlightDelay: TimeInterval = UITimings.Debounce.scroll
        /// Задержка дебаунсинга пересчёта фолдинга (тяжелее подсветки)
        private let foldRecalcDelay: TimeInterval = UITimings.Debounce.foldRecalc

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

        // Cancel all outstanding async syntax-highlighting and debounced
        // recalculation work so an in-flight `Task` or `DispatchWorkItem`
        // cannot fire against a now-detached `NSTextView`. The generation
        // token (`HighlightGeneration`) already discards stale results, but
        // cancelling at deinit is cheaper and closes the race window
        // entirely (issue #1007).
        //
        // Undo/highlight race window (issue #650 family):
        // Even with this cancellation, a residual window remains between the
        // moment a highlight `Task`'s background regex work finishes and the
        // moment it checks the generation token on the main actor. If an
        // undo/redo is in flight on the main thread at that exact instant,
        // the apply path relies on `isUndoRedoInProgress` /
        // `undoManager.isUndoing` guards (see `scheduleDeferredHighlight`
        // and `SyntaxHighlightEngine.applyMatches`) rather than on
        // cancellation. The deinit cancellation shrinks — but does not
        // eliminate — that window, because the `Task` may already be past
        // its cancellation point by the time deinit runs. Documented here so
        // future work does not re-discover it.
        deinit {
            NotificationCenter.default.removeObserver(self)
            // Coordinator is a UI coordinator owned by SwiftUI's
            // NSViewRepresentable lifecycle and AppKit delegate roles — it is
            // always torn down on the main thread, so assuming MainActor
            // isolation here is safe and lets us cancel the non-Sendable
            // DispatchWorkItem / Task properties directly.
            MainActor.assumeIsolated {
                highlightWorkItem?.cancel()
                highlightWorkItem = nil
                scrollHighlightWorkItem?.cancel()
                scrollHighlightWorkItem = nil
                foldWorkItem?.cancel()
                foldWorkItem = nil
                highlightTask?.cancel()
                highlightTask = nil
                // Bump the generation so any async highlight that already
                // passed its cancellation point discards its result instead
                // of applying attributes to the coordinator's
                // soon-to-be-detached text view.
                highlightGeneration.increment()
            }
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
            //
            // Optimization (#863): for files below the viewport threshold,
            // apply a synchronous incremental highlight immediately. This
            // eliminates the 100ms debounce gap that caused visible flicker
            // on Enter — the new line gets syntax colors in the same display
            // cycle as the text change. The debounced async path is still
            // scheduled as a fallback to catch any edge cases the sync pass
            // missed (e.g., multiline token boundary changes that expand
            // beyond the incremental context window).
            if let storage = textView.textStorage,
               let range = editedRange,
               range.location + range.length <= storage.length,
               storage.length <= CodeEditorView.viewportHighlightThreshold {
                SyntaxHighlighter.shared.highlightEdited(
                    textStorage: storage,
                    editedRange: range,
                    language: parent.language,
                    fileName: parent.fileName,
                    font: parent.editorFont
                )
            }
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
            PerformanceSignposts.trace("scroll.frame") {
                reportStateChange()
                highlightOnScrollIfNeeded()
                // Dismiss the hover popover on scroll — the position is stale.
                hideHoverPopover()
                if let textView = scrollView?.documentView as? GutterTextView {
                    textView.lspDismissHoverOnScroll()
                }
            }
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
        ///
        /// The fold mutation is deferred to the next runloop to break the
        /// reentrancy that causes the macOS 26 exclusivity abort. The menu
        /// command (Cmd+Opt+arrows / Cmd+Opt+Shift+arrows) posts `.foldCode`
        /// synchronously inside the `ButtonAction` callstack, which holds
        /// SwiftUI's exclusive transaction access. Mutating `parent.foldState`
        /// — a `@Binding` to a value-type `FoldState` — synchronously here
        /// forces a SwiftUI body re-evaluation that collides with that access
        /// and triggers `_swift_reportExclusivityConflict` → `abort()`.
        ///
        /// This is the same class of bug as #1051 (which closed the SwiftUI
        /// `.onReceive` path) and #1047 (which closed the AppKit
        /// `reportStateChange` path), on the one AppKit-observer path that
        /// #1051 did not audit: the keyboard-driven `.foldCode` observer.
        /// `applyFoldState()` is deferred alongside the mutation because it
        /// reads `parent.foldState` and must observe the just-applied change.
        ///
        /// The defer lives in ``scheduleFoldAction`` (not inline here) so the
        /// deferral contract is unit-testable — see
        /// `FoldObserverReentrancyTests`. Do not inline it back: the
        /// `isKeyWindow` guard above cannot be satisfied by a background
        /// test runner, so inlining would silently drop CI coverage of the
        /// deferral and let the crash regress unnoticed.
        @objc func handleFoldCode(_ notification: Notification) {
            guard let sv = scrollView,
                  let textView = sv.documentView as? GutterTextView,
                  textView.window?.isKeyWindow == true,
                  let action = notification.userInfo?["action"] as? String else { return }

            scheduleFoldAction(action)
        }

        /// Defers `performFoldAction` to the next runloop. Extracted and
        /// internal so the reentrancy deferral contract is unit-testable
        /// directly (without the key-window guard in ``handleFoldCode``, which
        /// a background test runner cannot satisfy and which would otherwise
        /// hide the deferral path from CI).
        func scheduleFoldAction(_ action: String) {
            DispatchQueue.main.async { [weak self] in
                self?.performFoldAction(action)
            }
        }

        /// Applies a fold action to `parent.foldState`. Extracted and internal
        /// so the reentrancy deferral contract in ``handleFoldCode`` is
        /// unit-testable (the deferral lives in the caller, the fold logic
        /// here is the deferred body), and so the fold logic itself can be
        /// exercised without a key window.
        func performFoldAction(_ action: String) {
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

        // MARK: - Completion (Phase 3, #1012)

        /// Called from `textDidChange` after the user types. Schedules a
        /// debounced completion request when the edited character is an
        /// identifier character or a trigger character, and refines the
        /// existing popup live as the user keeps typing.
        ///
        /// - Parameter editedRange: The NSTextStorage edited range captured
        ///   before processEditing reset it (may be nil on the first change).
        func scheduleCompletionIfNeeded(editedRange: NSRange?) {
            // Only auto-trigger on user edits, not programmatic changes.
            guard !isProgrammaticTextChange else { return }
            guard let textView = scrollView?.documentView as? NSTextView else { return }

            // Don't trigger completion when the editor isn't editable.
            guard textView.isEditable else { return }

            let cursor = textView.selectedRange().location
            let source = textView.string as NSString

            // If the popup is already visible, refine it live against the new
            // word prefix rather than issuing a fresh server request. This
            // keeps the UI responsive as the user narrows the selection.
            if completionController.isVisible {
                let prefix = CompletionTrigger.wordPrefix(at: cursor, in: source)
                if prefix.isEmpty {
                    // The user deleted the word or moved past it — dismiss.
                    completionController.dismiss()
                    cancelCompletionRequest()
                } else {
                    completionController.refine(prefix: prefix)
                }
                return
            }

            // Determine the character just typed (if any) to decide whether to
            // trigger immediately (trigger char) or debounce (identifier char).
            let triggerInfo = CompletionTrigger.evaluate(
                editedRange: editedRange,
                cursor: cursor,
                source: source
            )

            guard triggerInfo.shouldTrigger else {
                cancelCompletionRequest()
                return
            }

            // Schedule a (possibly immediate) request. Use the generation
            // token so stale replies from a previous idle pause are dropped.
            let debounceMillis = triggerInfo.fireImmediately
                ? 0
                : LSPManager.completionDebounceMillis

            let generation = incrementCompletionGeneration()
            let prefix = triggerInfo.prefix
            let fileURL = parent.fileURL
            let text = textView.string

            completionTask?.cancel()
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if debounceMillis > 0 {
                    try? await Task.sleep(for: .milliseconds(debounceMillis))
                    if Task.isCancelled { return }
                }
                guard self.completionGeneration == generation else { return }
                await self.requestCompletion(fileURL: fileURL, offset: cursor, text: text, prefix: prefix)
            }
        }

        /// Fires the actual `textDocument/completion` request and presents the
        /// popup with the results. Runs on the main actor; the await suspends
        /// without blocking the UI.
        private func requestCompletion(
            fileURL: URL?, offset: Int, text: String, prefix: String
        ) async {
            guard let url = fileURL else { return }
            let list = await CompletionEndpoint.shared.completion(
                url: url, offset: offset, text: text
            )
            // Drop stale replies: the user may have kept typing or dismissed.
            guard !Task.isCancelled else { return }
            guard completionController.isVisible || !list.isEmpty else { return }

            // Configure the accept callback the first time we present.
            ensureCompletionCallbacks()

            completionController.present(items: list.items, prefix: prefix)

            if completionController.isVisible {
                positionCompletionPopup()
            }
        }

        /// Positions the popup container just below the caret.
        private func positionCompletionPopup() {
            guard let container = scrollView?.superview,
                  let textView = scrollView?.documentView as? NSTextView,
                  completionController.isVisible else { return }

            // Lazily create + attach the popup container.
            if completionPopup == nil {
                let popup = CompletionPopupContainer(controller: completionController)
                container.addSubview(popup)
                completionPopup = popup
            }
            guard let popup = completionPopup else { return }

            // Get the caret rect in text-view coordinates, convert to the
            // container's coordinate space.
            let caretRange = textView.selectedRange()
            guard caretRange.location != NSNotFound,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: caretRange, actualCharacterRange: nil)
            let caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                       in: textContainer)
            let rectInContainer = container.convert(caretRect, from: textView)
            popup.position(below: rectInContainer, in: container.bounds.width)
        }

        /// Wires the controller's accept/dismiss callbacks to the editor.
        /// Idempotent — safe to call before every present.
        private func ensureCompletionCallbacks() {
            completionController.onAccept = { [weak self] item in
                self?.acceptCompletion(item)
            }
            completionController.onDismiss = { [weak self] in
                self?.hideCompletionPopup()
            }
        }

        /// Accepts `item`: replaces the current word with the item's insert
        /// text, expanding LSP snippets into plain text + tab stops.
        private func acceptCompletion(_ item: LSPCompletionItem) {
            guard let textView = scrollView?.documentView as? NSTextView else {
                hideCompletionPopup()
                return
            }
            let source = textView.string as NSString
            let cursor = textView.selectedRange().location

            // Compute the word range to replace. Scan backwards from the cursor
            // over identifier characters (letters, digits, underscore) so the
            // server's insertText fully replaces the partially-typed token.
            let wordRange = CompletionInsertion.wordRange(
                endingAt: cursor, in: source
            )

            // Expand the insert text (snippet or plain).
            let expansion: CompletionInsertion
            switch item.insertTextFormat {
            case .snippet:
                let snippet = LSPSnippet(item.insertText)
                expansion = CompletionInsertion.fromSnippet(snippet)
            case .plain:
                expansion = CompletionInsertion(text: item.insertText, finalCursorOffset: item.insertText.count)
            }

            // Replace the word with the expanded text as a single undo step.
            if textView.shouldChangeText(in: wordRange, replacementString: expansion.text) {
                textView.undoManager?.beginUndoGrouping()
                textView.replaceCharacters(in: wordRange, with: expansion.text)
                // Position the cursor at the first tab stop (or end of text).
                let newCursor = wordRange.location + expansion.finalCursorOffset
                textView.setSelectedRange(NSRange(location: newCursor, length: 0))
                textView.undoManager?.endUndoGrouping()
                textView.didChangeText()
            }

            hideCompletionPopup()
        }

        /// Cancels any pending debounced completion request.
        private func cancelCompletionRequest() {
            completionTask?.cancel()
            completionTask = nil
        }

        /// Bumps the generation token and returns the new value.
        @discardableResult
        private func incrementCompletionGeneration() -> Int {
            completionGeneration += 1
            return completionGeneration
        }

        /// Hides the popup and cancels pending requests. Does NOT invoke
        /// `onDismiss` (this is the dismissal path itself).
        func hideCompletionPopup() {
            cancelCompletionRequest()
            completionPopup?.isHidden = true
            completionController.dismiss()
        }

        /// Handles Escape for the completion popup. Returns `true` if the
        /// popup consumed the key (so the caller should NOT forward it to the
        /// text view's collapse-inline-diff handler).
        func handleCompletionEscape() -> Bool {
            guard completionController.isVisible else { return false }
            hideCompletionPopup()
            return true
        }

        /// Routes Up/Down/Enter/Tab to the popup when it is visible. Returns
        /// `true` when the popup consumed the event.
        ///
        /// - Parameters:
        ///   - selector: The `doCommandBy:` selector the text view is about to
        ///     invoke.
        func interceptCommandForCompletion(_ selector: Selector) -> Bool {
            guard completionController.isVisible else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                completionController.move(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completionController.move(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                completionController.acceptSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideCompletionPopup()
                return true
            default:
                return false
            }
        }

        private func reportStateChange() {
            guard let sv = scrollView,
                  let textView = sv.documentView as? NSTextView else { return }
            let cursor = textView.selectedRange().location
            let scroll = sv.contentView.bounds.origin.y

            // Defer the @Observable mutation to the next runloop to break the
            // reentrancy that caused the macOS 27 exclusivity abort (#1032).
            // Coalesce: only schedule one async drain per runloop; the latest
            // cursor/scroll overwrites any pending value so the final state is
            // always correct. On macOS ≤ 26 this is a no-op semantically — the
            // same values are delivered ~1 frame later (imperceptible at
            // 120 Hz); on macOS 27 beta 1 it removes the synchronous overlap
            // that triggered `_swift_reportExclusivityConflict`.
            deferredStateChange = (cursor, scroll)
            guard !deferredStateChangeScheduled else { return }
            deferredStateChangeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deferredStateChangeScheduled = false
                guard let pending = self.deferredStateChange else { return }
                self.deferredStateChange = nil
                self.parent.onStateChange?(pending.cursor, pending.scroll)
            }
        }

        // MARK: - LSP UI Integration (Phase 5, milestone #1088, item 1)

        /// Wires the coordinator as the `lspMouseHandler` on the GutterTextView.
        /// Called from `makeNSView` after the text view is created.
        func installLSPMouseHandler() {
            guard let textView = scrollView?.documentView as? GutterTextView else { return }
            textView.lspMouseHandler = self
        }

        // MARK: - Hover

        /// Hides the hover popover if visible.
        func hideHoverPopover() {
            hoverPopoverManager?.hide()
        }

        // MARK: - LSPMouseHandling conformance

        func lspHover(at offset: Int) {
            hoverGeneration += 1
            let generation = hoverGeneration
            hoverTask?.cancel()

            guard let textView = scrollView?.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let url = parent.fileURL else { return }

            // Compute the screen rect of the hovered character for popover
            // positioning.
            let charRange = NSRange(location: offset, length: 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange, actualCharacterRange: nil
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textContainer
            )
            // Convert to the text view's superview coordinate space (screen).
            let rectInView = textView.convert(glyphRect, to: nil)

            let text = textView.string
            let fileURL = url

            hoverTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let hover = await LSPUIEndpoint.shared.hover(
                    url: fileURL, offset: offset, text: text
                )
                guard !Task.isCancelled else { return }
                guard self.hoverGeneration == generation else { return }
                guard let hover else { return }

                // Show the popover.
                self.ensureHoverPopover()
                self.hoverPopoverManager?.show(
                    content: hover.markup.value,
                    isMarkdown: hover.markup.isMarkdown,
                    anchorRect: rectInView,
                    positioningView: textView
                )
            }
        }

        func lspHoverEnded() {
            hoverTask?.cancel()
            hoverTask = nil
            hideHoverPopover()
        }

        // MARK: - Go-to-Definition

        func lspGoToDefinition(at offset: Int) -> Bool {
            guard let textView = scrollView?.documentView as? NSTextView,
                  let url = parent.fileURL else { return false }

            let text = textView.string
            let fileURL = url
            let currentURL = url

            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await LSPUIEndpoint.shared.definition(
                    url: fileURL, offset: offset, text: text
                )
                guard !Task.isCancelled else { return }
                guard !response.isEmpty else { return }

                switch response {
                case .empty:
                    return

                case .locations(let locations):
                    if locations.count == 1 {
                        self.navigateToLocation(locations[0], currentURL: currentURL)
                    } else {
                        self.showDefinitionQuickPick(
                            locations: locations, currentURL: currentURL
                        )
                    }

                case .locationLinks(let links):
                    if links.count == 1 {
                        self.navigateToLocationLink(links[0], currentURL: currentURL)
                    } else {
                        self.showDefinitionQuickPick(
                            links: links, currentURL: currentURL
                        )
                    }
                }
            }
            return true
        }

        // MARK: - Code Actions

        func lspRequestCodeActions(at offset: Int, menuLocation: NSPoint) {
            guard let textView = scrollView?.documentView as? NSTextView,
                  let url = parent.fileURL else { return }

            let text = textView.string
            let fileURL = url

            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await LSPUIEndpoint.shared.codeAction(
                    url: fileURL, offset: offset, text: text
                )
                guard !Task.isCancelled else { return }
                guard !response.isEmpty else { return }

                self.showCodeActionMenu(
                    response: response,
                    menuLocation: menuLocation,
                    textView: textView
                )
            }
        }

        // MARK: - Rename

        func lspRequestRename(at offset: Int) {
            guard let textView = scrollView?.documentView as? NSTextView,
                  let url = parent.fileURL else { return }

            // Extract the current word at offset for prefill.
            let source = textView.string as NSString
            let wordRange = CompletionInsertion.wordRange(endingAt: offset, in: source)
            let currentName: String
            if wordRange.length > 0 {
                currentName = source.substring(with: wordRange)
            } else {
                currentName = ""
            }

            // Compute the screen rect for popover positioning.
            let charRange = NSRange(location: wordRange.location, length: max(wordRange.length, 1))
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange, actualCharacterRange: nil
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textContainer
            )
            let rectInView = textView.convert(glyphRect, to: nil)

            // Capture the rename offset for the confirm callback.
            let renameOffset = wordRange.location
            let fileText = textView.string
            let fileURL = url

            ensureRenamePopover()

            renamePopoverManager?.show(
                currentName: currentName,
                anchorRect: rectInView,
                positioningView: textView,
                onConfirm: { [weak self] newName in
                    guard let self else { return }
                    self.performRename(
                        url: fileURL, offset: renameOffset,
                        text: fileText, newName: newName
                    )
                },
                onCancel: { }
            )
        }

        // MARK: - LSP helper methods

        private func ensureHoverPopover() {
            if hoverPopoverManager == nil {
                hoverPopoverManager = HoverPopoverManager()
            }
        }

        private func ensureRenamePopover() {
            if renamePopoverManager == nil {
                renamePopoverManager = RenamePopoverManager()
            }
        }

        // MARK: - Navigation

        /// Navigates to a single LSP Location. If it's in the current file,
        /// moves the cursor; if in another file, opens it and navigates.
        private func navigateToLocation(_ location: LSPLocation, currentURL: URL) {
            guard let targetURL = location.url else { return }
            if targetURL == currentURL {
                moveCursorToLocation(location)
            } else {
                LSPUIEndpoint.shared.openFileAtLine(
                    url: targetURL,
                    line: location.range.start.line,
                    character: location.range.start.character
                )
            }
        }

        /// Navigates to a single LSP LocationLink.
        private func navigateToLocationLink(_ link: LSPLocationLink, currentURL: URL) {
            guard let targetURL = link.url else { return }
            if targetURL == currentURL {
                moveCursorToLSPRange(link.targetSelectionRange)
            } else {
                LSPUIEndpoint.shared.openFileAtLine(
                    url: targetURL,
                    line: link.targetSelectionRange.start.line,
                    character: link.targetSelectionRange.start.character
                )
            }
        }

        /// Moves the cursor in the current text view to the start of an LSP
        /// Location's range (0-based positions).
        private func moveCursorToLocation(_ location: LSPLocation) {
            moveCursorToLSPRange(location.range)
        }

        /// Moves the cursor in the current text view to the start of an LSP
        /// Range (0-based positions).
        private func moveCursorToLSPRange(_ range: LSPRange) {
            guard let textView = scrollView?.documentView as? NSTextView else { return }
            let text = textView.string
            let offset = LSPPositionConverter.utf16Offset(
                line: range.start.line,
                character: range.start.character,
                in: text
            )
            let clamped = min(max(0, offset), (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
        }

        // MARK: - Definition quick-pick

        /// Shows the quick-pick for multiple locations.
        private func showDefinitionQuickPick(
            locations: [LSPLocation], currentURL: URL
        ) {
            let items = locations.compactMap { location -> DefinitionQuickPickItem? in
                guard let url = location.url else { return nil }
                let label = url.lastPathComponent
                let detail = "\(location.range.start.line + 1):\(location.range.start.character + 1)"
                return DefinitionQuickPickItem(
                    label: label, detail: detail, url: url,
                    line: location.range.start.line,
                    character: location.range.start.character
                )
            }
            definitionQuickPickController.onSelect = { [weak self] item in
                guard let self else { return }
                if item.url == currentURL {
                    self.moveCursorToLSPRange(LSPRange(
                        start: LSPPosition(line: item.line, character: item.character),
                        end: LSPPosition(line: item.line, character: item.character)
                    ))
                } else {
                    LSPUIEndpoint.shared.openFileAtLine(
                        url: item.url, line: item.line, character: item.character
                    )
                }
            }
            definitionQuickPickController.present(items: items)
        }

        /// Shows the quick-pick for multiple location links.
        private func showDefinitionQuickPick(
            links: [LSPLocationLink], currentURL: URL
        ) {
            let items = links.compactMap { link -> DefinitionQuickPickItem? in
                guard let url = link.url else { return nil }
                let label = url.lastPathComponent
                let detail = "\(link.targetSelectionRange.start.line + 1):\(link.targetSelectionRange.start.character + 1)"
                return DefinitionQuickPickItem(
                    label: label, detail: detail, url: url,
                    line: link.targetSelectionRange.start.line,
                    character: link.targetSelectionRange.start.character
                )
            }
            definitionQuickPickController.onSelect = { [weak self] item in
                guard let self else { return }
                if item.url == currentURL {
                    self.moveCursorToLSPRange(LSPRange(
                        start: LSPPosition(line: item.line, character: item.character),
                        end: LSPPosition(line: item.line, character: item.character)
                    ))
                } else {
                    LSPUIEndpoint.shared.openFileAtLine(
                        url: item.url, line: item.line, character: item.character
                    )
                }
            }
            definitionQuickPickController.present(items: items)
        }

        // MARK: - Code action menu

        /// Builds and shows an NSMenu with the available code actions at the
        /// given location.
        private func showCodeActionMenu(
            response: LSPCodeActionResponse,
            menuLocation: NSPoint,
            textView: NSTextView
        ) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            // Add code actions.
            for action in response.actions {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(handleCodeActionSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = CodeActionPayload(action: action)
                if let kind = action.kind {
                    item.image = NSImage(
                        systemSymbolName: kind.symbolName,
                        accessibilityDescription: nil
                    )
                }
                if !action.isExecutable {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }

            // Add bare commands.
            for command in response.commands {
                let item = NSMenuItem(
                    title: command.title,
                    action: #selector(handleCodeCommandSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = command
                menu.addItem(item)
            }

            // Add rename option.
            menu.addItem(.separator())
            let renameItem = NSMenuItem(
                title: Strings.contextRenameTitle,
                action: #selector(handleRenameFromMenu(_:)),
                keyEquivalent: "r"
            )
            renameItem.target = self
            renameItem.keyEquivalentModifierMask = [.command]
            menu.addItem(renameItem)

            guard !menu.items.isEmpty else { return }

            menu.popUp(
                positioning: nil,
                at: menuLocation,
                in: textView
            )
        }

        /// Payload wrapping an LSPCodeAction for menu selection.
        private final class CodeActionPayload: @unchecked Sendable {
            let action: LSPCodeAction
            init(action: LSPCodeAction) { self.action = action }
        }

        @objc private func handleCodeActionSelection(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? CodeActionPayload else { return }
            let action = payload.action
            // Apply the edit if present.
            if let edit = action.edit {
                _ = LSPUIEndpoint.shared.applyWorkspaceEdit(edit)
            }
            // TODO: Execute the command via workspace/executeCommand when
            // the command is present but no edit. Deferred — the server
            // command infrastructure is not yet wired for executeCommand.
        }

        @objc private func handleCodeCommandSelection(_ sender: NSMenuItem) {
            // Commands without an edit — would need workspace/executeCommand.
            // Deferred for now.
        }

        @objc private func handleRenameFromMenu(_ sender: NSMenuItem) {
            guard let textView = scrollView?.documentView as? NSTextView else { return }
            let offset = textView.selectedRange().location
            lspRequestRename(at: offset)
        }

        // MARK: - Rename execution

        /// Performs the rename request and applies the resulting WorkspaceEdit.
        private func performRename(
            url: URL, offset: Int, text: String, newName: String
        ) {
            Task { @MainActor in
                let edit = await LSPUIEndpoint.shared.rename(
                    url: url, offset: offset, text: text, newName: newName
                )
                guard !Task.isCancelled else { return }
                guard !edit.isEmpty else { return }

                _ = LSPUIEndpoint.shared.applyWorkspaceEdit(edit)
            }
        }
    }
}

// MARK: - LSPMouseHandling conformance

extension CodeEditorView.Coordinator: LSPMouseHandling {}
