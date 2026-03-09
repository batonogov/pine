//
//  CodeEditorView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import AppKit

/// NSViewRepresentable — протокол-мост между SwiftUI и AppKit.
/// Позволяет использовать любой NSView внутри SwiftUI.
/// Здесь оборачиваем NSScrollView с NSTextView для полноценного редактора кода.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String  // Расширение файла для выбора подсветки

    // MARK: - NSViewRepresentable

    /// Создаёт NSView один раз при первом рендере.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Настройка NSTextView
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true                          // Cmd+Z работает
        textView.usesFindBar = true                         // Cmd+F — поиск
        textView.isAutomaticQuoteSubstitutionEnabled = false // Отключаем "умные" кавычки
        textView.isAutomaticDashSubstitutionEnabled = false  // Отключаем замену дефисов на тире
        textView.isAutomaticTextReplacementEnabled = false   // Отключаем автозамену текста
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false                          // Только plain text

        // Моноширинный шрифт размером 13pt
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Цвета
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1.0)  // Тёмный фон
        textView.textColor = NSColor(white: 0.9, alpha: 1.0)          // Светлый текст
        textView.insertionPointColor = .white                          // Белый курсор

        // Текст растягивается по ширине контейнера
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false

        // Отступ слева (для "воздуха" перед кодом)
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Делегат — получает уведомления об изменении текста
        textView.delegate = context.coordinator

        // Устанавливаем начальный текст
        textView.string = text
        applyHighlighting(to: textView)

        return scrollView
    }

    /// Вызывается SwiftUI при изменении @Binding (text изменился снаружи).
    /// Обновляем текст в NSTextView, только если он реально изменился.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Предотвращаем бесконечный цикл: обновляем только если текст пришёл извне
        if textView.string != text {
            // Сохраняем позицию курсора
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            applyHighlighting(to: textView)
        }
    }

    /// Coordinator — паттерн Apple для делегатов в NSViewRepresentable.
    /// NSTextViewDelegate требует class (не struct), поэтому нужен отдельный объект.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator (делегат NSTextView)

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        /// Вызывается каждый раз, когда пользователь меняет текст.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Обновляем binding — изменения уходят обратно в SwiftUI
            parent.text = textView.string
            // Перекрашиваем подсветку
            parent.applyHighlighting(to: textView)
        }
    }

    // MARK: - Подсветка синтаксиса

    /// Применяет цветовую подсветку ко всему тексту через NSTextStorage.
    /// NSTextStorage — подкласс NSMutableAttributedString, управляющий текстом NSTextView.
    private func applyHighlighting(to textView: NSTextView) {
        let storage = textView.textStorage!
        let fullRange = NSRange(location: 0, length: storage.length)
        let source = storage.string

        // Сбрасываем всё на базовый стиль (белый текст, моноширинный шрифт)
        storage.beginEditing()
        storage.addAttributes([
            .foregroundColor: NSColor(white: 0.9, alpha: 1.0),
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ], range: fullRange)

        // Получаем правила подсветки для текущего языка
        let rules = highlightRules(for: language)

        // Применяем каждое правило: ищем совпадения с regex и красим
        for rule in rules {
            let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options)
            regex?.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let matchRange = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: matchRange)
            }
        }

        storage.endEditing()
    }

    /// Правило подсветки: regex-паттерн + цвет.
    private struct HighlightRule {
        let pattern: String
        let color: NSColor
        var options: NSRegularExpression.Options = []
    }

    /// Возвращает набор правил подсветки в зависимости от языка (расширения файла).
    private func highlightRules(for language: String) -> [HighlightRule] {
        switch language {
        case "swift":
            return swiftRules()
        case "js", "ts", "jsx", "tsx":
            return jsRules()
        case "py":
            return pythonRules()
        case "json":
            return jsonRules()
        default:
            return genericRules()
        }
    }

    // MARK: - Swift Rules

    private func swiftRules() -> [HighlightRule] {
        let keywords = [
            "import", "struct", "class", "enum", "protocol", "extension",
            "func", "var", "let", "if", "else", "guard", "return", "switch",
            "case", "default", "for", "in", "while", "repeat", "break",
            "continue", "self", "Self", "super", "init", "deinit", "nil",
            "true", "false", "try", "catch", "throw", "throws", "async",
            "await", "some", "any", "where", "is", "as", "private", "public",
            "internal", "fileprivate", "open", "static", "final", "override",
            "mutating", "nonmutating", "lazy", "weak", "unowned", "inout",
            "typealias", "associatedtype", "do"
        ].joined(separator: "|")

        let attributes = [
            "@State", "@Binding", "@Observable", "@ObservedObject",
            "@Published", "@Environment", "@Bindable", "@main",
            "@StateObject", "@EnvironmentObject", "@AppStorage",
            "@SceneStorage", "@ViewBuilder", "@discardableResult",
            "@escaping", "@available"
        ].map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        return [
            // Однострочные комментарии: // ... (должны быть последними — перекрывают всё)
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: .anchorsMatchLines),
            // Многострочные комментарии: /* ... */
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            // Строки: "..." (с поддержкой escape-символов вроде \")
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: .systemOrange),
            // Ключевые слова
            HighlightRule(pattern: "\\b(\(keywords))\\b", color: .systemPink),
            // Атрибуты (@State, @Binding и т.д.)
            HighlightRule(pattern: "(\(attributes))", color: .systemPurple),
            // Числа (целые и десятичные)
            HighlightRule(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemYellow),
            // Типы (слова с большой буквы — условная эвристика)
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9]+\\b", color: .systemCyan),
        ]
    }

    // MARK: - JavaScript/TypeScript Rules

    private func jsRules() -> [HighlightRule] {
        let keywords = [
            "const", "let", "var", "function", "return", "if", "else",
            "for", "while", "do", "switch", "case", "break", "continue",
            "class", "extends", "new", "this", "super", "import", "export",
            "from", "default", "try", "catch", "finally", "throw", "async",
            "await", "of", "in", "typeof", "instanceof", "true", "false",
            "null", "undefined", "void", "delete", "yield", "interface",
            "type", "enum", "implements", "readonly"
        ].joined(separator: "|")

        return [
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: .anchorsMatchLines),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: .systemOrange),
            HighlightRule(pattern: "'(?:[^'\\\\]|\\\\.)*'", color: .systemOrange),
            HighlightRule(pattern: "`(?:[^`\\\\]|\\\\.)*`", color: .systemOrange),
            HighlightRule(pattern: "\\b(\(keywords))\\b", color: .systemPink),
            HighlightRule(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemYellow),
        ]
    }

    // MARK: - Python Rules

    private func pythonRules() -> [HighlightRule] {
        let keywords = [
            "def", "class", "if", "elif", "else", "for", "while", "return",
            "import", "from", "as", "try", "except", "finally", "with",
            "raise", "pass", "break", "continue", "in", "not", "and", "or",
            "is", "lambda", "yield", "global", "nonlocal", "assert", "del",
            "True", "False", "None", "self", "async", "await"
        ].joined(separator: "|")

        return [
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: .anchorsMatchLines),
            HighlightRule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", color: .systemOrange),
            HighlightRule(pattern: "'''[\\s\\S]*?'''", color: .systemOrange),
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: .systemOrange),
            HighlightRule(pattern: "'(?:[^'\\\\]|\\\\.)*'", color: .systemOrange),
            HighlightRule(pattern: "\\b(\(keywords))\\b", color: .systemPink),
            HighlightRule(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemYellow),
        ]
    }

    // MARK: - JSON Rules

    private func jsonRules() -> [HighlightRule] {
        return [
            // Ключи (строки перед двоеточием)
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"\\s*(?=:)", color: .systemCyan),
            // Значения-строки
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: .systemOrange),
            // Числа
            HighlightRule(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemYellow),
            // true/false/null
            HighlightRule(pattern: "\\b(true|false|null)\\b", color: .systemPink),
        ]
    }

    // MARK: - Generic Rules (для неизвестных языков)

    private func genericRules() -> [HighlightRule] {
        return [
            HighlightRule(pattern: "//.*$", color: .systemGreen, options: .anchorsMatchLines),
            HighlightRule(pattern: "#.*$", color: .systemGreen, options: .anchorsMatchLines),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            HighlightRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", color: .systemOrange),
            HighlightRule(pattern: "'(?:[^'\\\\]|\\\\.)*'", color: .systemOrange),
            HighlightRule(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemYellow),
        ]
    }
}
