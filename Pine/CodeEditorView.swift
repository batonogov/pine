//
//  CodeEditorView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import AppKit

/// NSViewRepresentable-обёртка для редактора кода.
/// Использует NSTextView + SyntaxHighlighter для подсветки из JSON-грамматик.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String   // Расширение файла ("swift", "py", "go")
    var fileName: String?  // Полное имя файла ("Dockerfile") — для грамматик по имени

    /// Шрифт редактора — вынесен в константу, чтобы не создавать каждый раз.
    private let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Настройка NSTextView
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

        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 8)

        textView.delegate = context.coordinator

        textView.string = text
        applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            applyHighlighting(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.applyHighlighting(to: textView)
        }
    }

    // MARK: - Подсветка

    /// Делегирует подсветку в SyntaxHighlighter.
    /// Вся логика (загрузка грамматик, компиляция regex, применение цветов) — там.
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
