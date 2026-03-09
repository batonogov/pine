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
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var fileName: String?

    private let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeNSView(context: Context) -> NSView {
        let gutterWidth: CGFloat = 40

        // ── Контейнер — держит scroll view и line number view как сиблингов ──
        let container = NSView()
        container.wantsLayer = true

        // ── ScrollView ──
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        scrollView.autoresizingMask = [.width, .height]

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
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        textView.textColor = NSColor(white: 0.9, alpha: 1.0)
        textView.insertionPointColor = .white

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        scrollView.documentView = textView

        container.addSubview(scrollView)

        // ── Номера строк — поверх scroll view, как отдельный сиблинг ──
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.gutterWidth = gutterWidth
        lineNumberView.autoresizingMask = [.height]
        container.addSubview(lineNumberView)

        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberView = lineNumberView

        textView.string = text
        applyHighlighting(to: textView)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let scrollView = context.coordinator.scrollView,
              let textView = scrollView.documentView as? NSTextView else { return }

        // Scroll view заполняет весь контейнер
        scrollView.frame = container.bounds

        if textView.string != text {
            textView.string = text
            applyHighlighting(to: textView)
            // Сброс скролла и курсора при открытии нового файла
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        // Обновляем размер LineNumberView
        if let lineNumberView = context.coordinator.lineNumberView {
            lineNumberView.frame = NSRect(
                x: 0, y: 0,
                width: lineNumberView.gutterWidth,
                height: container.bounds.height
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var scrollView: NSScrollView?
        var lineNumberView: LineNumberView?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.applyHighlighting(to: textView)
        }
    }

    private func applyHighlighting(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        SyntaxHighlighter.shared.highlight(
            textStorage: storage,
            language: language,
            fileName: fileName,
            font: editorFont
        )
    }
}
