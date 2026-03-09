//
//  TerminalContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import AppKit

/// NSViewRepresentable-обёртка для отображения терминала.
/// Использует кастомный NSTextView, который перехватывает клавиши
/// и отправляет их в TerminalSession вместо редактирования текста.
struct TerminalContentView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // Используем кастомный TerminalTextView (определён ниже)
        let textView = TerminalTextView()
        textView.isEditable = true          // Нужно для перехвата keyDown
        textView.isSelectable = true        // Можно выделять текст
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Моноширинный шрифт, тёмный фон
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        textView.textColor = NSColor(white: 0.9, alpha: 1.0)
        textView.insertionPointColor = .white

        // Текст растягивается по ширине
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)

        // Колбэк: каждое нажатие клавиши отправляется в TerminalSession
        textView.onKeyInput = { [weak session] text in
            session?.send(text)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalTextView else { return }

        let currentOutput = session.displayText

        if textView.string != currentOutput {
            // Проверяем, был ли пользователь внизу (чтобы не сбивать ручной скролл)
            let clipView = scrollView.contentView
            let isAtBottom = clipView.bounds.maxY >= (textView.frame.height - 20)

            // Обновляем текст
            textView.string = currentOutput

            // Автоскролл вниз только если пользователь уже был внизу
            if isAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}

// MARK: - Кастомный NSTextView для терминала

/// Перехватывает ВСЕ нажатия клавиш и отправляет их в терминал.
/// Обычный NSTextView при нажатии Enter вставляет перенос строки в текст.
/// Нам же нужно отправить "\n" в zsh, а не редактировать view.
class TerminalTextView: NSTextView {
    /// Колбэк: вызывается при каждом нажатии клавиши
    var onKeyInput: ((String) -> Void)?

    /// keyDown — вызывается AppKit при нажатии любой клавиши.
    /// Мы перехватываем его полностью, не вызывая super (иначе текст вставится в view).
    override func keyDown(with event: NSEvent) {
        // Ctrl+комбинации — отправляем как control-символы
        if event.modifierFlags.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let scalar = chars.unicodeScalars.first {
                // Control-символ: Ctrl+C = 0x03, Ctrl+D = 0x04, Ctrl+Z = 0x1A и т.д.
                // Формула: ASCII буквы - 64. 'c' (99) - 96 = 3
                let value = scalar.value
                if value >= 97 && value <= 122 { // a-z
                    let ctrlChar = Character(UnicodeScalar(value - 96)!)
                    onKeyInput?(String(ctrlChar))
                    return
                }
            }
        }

        // Специальные клавиши — отправляем ANSI escape-последовательности.
        // Терминалы используют ESC + [ + буква для стрелок и других клавиш.
        switch event.keyCode {
        case 126: onKeyInput?("\u{1B}[A"); return  // ↑ Up
        case 125: onKeyInput?("\u{1B}[B"); return  // ↓ Down
        case 124: onKeyInput?("\u{1B}[C"); return  // → Right
        case 123: onKeyInput?("\u{1B}[D"); return  // ← Left
        case 36:  onKeyInput?("\n"); return         // Enter (Return)
        case 51:  onKeyInput?("\u{7F}"); return     // Backspace (DEL)
        case 48:  onKeyInput?("\t"); return         // Tab
        case 53:  onKeyInput?("\u{1B}"); return     // Escape
        default: break
        }

        // Обычные символы — отправляем как есть
        if let chars = event.characters, !chars.isEmpty {
            onKeyInput?(chars)
        }
    }

    // Отключаем стандартную обработку — мы всё делаем в keyDown
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Не вызываем super — текст управляется PTY
    }

    override func doCommand(by selector: Selector) {
        // Игнорируем стандартные команды (insertNewline, deleteBackward и т.д.)
        // Всё уже обработано в keyDown
    }

    // Разрешаем вставку из буфера обмена (Cmd+V)
    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) {
            onKeyInput?(string)
        }
    }
}
