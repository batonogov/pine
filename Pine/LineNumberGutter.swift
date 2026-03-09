//
//  LineNumberGutter.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import AppKit

/// Отдельный NSView, который рисует номера строк.
/// Добавляется как subview NSScrollView и остаётся на месте при скролле.
final class LineNumberView: NSView {
    weak var textView: NSTextView?

    private let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let gutterTextColor = NSColor.secondaryLabelColor
    private let gutterBgColor = NSColor.controlBackgroundColor
    private let separatorColor = NSColor.separatorColor

    var gutterWidth: CGFloat = 40

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)

        // Скролл — подписываемся без object, чтобы не зависеть от конкретного clipView
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBoundsChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: nil
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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Гарантируем что clipView шлёт уведомления о скролле
        textView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleBoundsChange(_ notification: Notification) {
        // Реагируем только на скролл нашего scroll view
        guard let clipView = notification.object as? NSClipView,
              clipView == textView?.enclosingScrollView?.contentView else { return }
        display()
    }

    @objc private func contentDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView
        else { return }

        // Принудительно завершаем layout
        layoutManager.ensureLayout(for: textContainer)

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
            numStr.draw(at: NSPoint(x: x, y: originY), withAttributes: attrs)
            return
        }

        // ── Находим видимый диапазон глифов ──
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        if visibleGlyphRange.location == NSNotFound { return }

        // ── Считаем номер первой видимой строки ──
        // (количество \n до первого видимого символа + 1)
        let firstVisibleCharIndex = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )
        var lineNumber: Int
        if firstVisibleCharIndex == 0 {
            lineNumber = 1
        } else {
            let textBefore = source.substring(to: firstVisibleCharIndex)
            lineNumber = textBefore.components(separatedBy: "\n").count
        }

        // ── Рисуем номера видимых строк через enumerateLineFragments ──
        // Этот метод проходит только по видимым фрагментам строк — быстро.
        var previousLineCharIndex = -1

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { (lineRect, _, _, glyphRange, _) in
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
                // Y: позиция фрагмента в textContainer + сдвиг контейнера − скролл
                let y = lineRect.origin.y + originY - visibleRect.origin.y

                let numStr = "\(lineNumber)" as NSString
                let size = numStr.size(withAttributes: attrs)
                let x = self.gutterWidth - size.width - 8
                numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

                lineNumber += 1
            }

            previousLineCharIndex = charIndex
        }

        // ── Обновляем ширину гуттера если изменилось количество цифр ──
        let totalLines = source.components(separatedBy: "\n").count
        let digits = max(String(totalLines).count, 2)
        let charWidth = "0".size(withAttributes: [.font: gutterFont]).width
        let newWidth = CGFloat(digits) * charWidth + 20
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
}
