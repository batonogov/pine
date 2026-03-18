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

    var gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let gutterTextColor = NSColor.secondaryLabelColor
    private let gutterBgColor = NSColor.controlBackgroundColor
    private let separatorColor = NSColor.separatorColor

    var gutterWidth: CGFloat = 40
    var lineDiffs: [GitLineDiff] = [] {
        didSet {
            rebuildDiffMap()
            needsDisplay = true
        }
    }

    /// Pre-indexed diff lookup: line number → kind (cached, rebuilt when lineDiffs changes)
    private var diffMap: [Int: GitLineDiff.Kind] = [:]

    private func rebuildDiffMap() {
        diffMap = Dictionary(lineDiffs.map { ($0.line, $0.kind) }, uniquingKeysWith: { _, last in last })
    }

    // Diff marker colors
    private let addedColor = NSColor.systemGreen
    private let modifiedColor = NSColor.systemBlue
    private let deletedColor = NSColor.systemRed

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
        needsDisplay = true
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
        var lineNumber = 1
        if firstVisibleCharIndex > 0 {
            // Быстрый подсчёт \n без аллокации массива строк
            let ptr = source as String
            var count = 0
            let endIndex = ptr.utf16.index(ptr.utf16.startIndex, offsetBy: firstVisibleCharIndex)
            for ch in ptr.utf16[ptr.utf16.startIndex..<endIndex] where ch == 0x0A {
                count += 1
            }
            lineNumber = count + 1
        }

        // ── Рисуем номера видимых строк через enumerateLineFragments ──
        // Этот метод проходит только по видимым фрагментам строк — быстро.
        var previousLineCharIndex = -1
        let diffBarWidth: CGFloat = 3

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { lineRect, _, _, glyphRange, _ in
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

                // ── Git diff marker ──
                if let diffKind = self.diffMap[lineNumber] {
                    let markerColor: NSColor
                    switch diffKind {
                    case .added:    markerColor = self.addedColor
                    case .modified: markerColor = self.modifiedColor
                    case .deleted:  markerColor = self.deletedColor
                    }

                    if diffKind == .deleted {
                        // Deleted: small red triangle at the gutter edge
                        let triangleSize: CGFloat = 5
                        let triX = self.gutterWidth - diffBarWidth
                        let triY = y
                        let path = NSBezierPath()
                        path.move(to: NSPoint(x: triX, y: triY))
                        path.line(to: NSPoint(x: triX + triangleSize, y: triY + triangleSize / 2))
                        path.line(to: NSPoint(x: triX, y: triY + triangleSize))
                        path.close()
                        markerColor.setFill()
                        path.fill()
                    } else {
                        // Added/Modified: colored bar at the right edge of gutter
                        let barRect = NSRect(
                            x: self.gutterWidth - diffBarWidth,
                            y: y,
                            width: diffBarWidth,
                            height: lineRect.height
                        )
                        markerColor.setFill()
                        barRect.fill()
                    }
                }

                lineNumber += 1
            }

            previousLineCharIndex = charIndex
        }

        // ── Номер для завершающей пустой строки (после последнего \n) ──
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0 && source.hasSuffix("\n") {
            let y = extraRect.origin.y + originY - visibleRect.origin.y
            if y >= -extraRect.height && y <= bounds.height {
                let numStr = "\(lineNumber)" as NSString
                let size = numStr.size(withAttributes: attrs)
                let x = gutterWidth - size.width - 8
                numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }
        }

        // ── Обновляем ширину гуттера если изменилось количество цифр ──
        var totalLines = 1
        for i in 0..<source.length where source.character(at: i) == 0x0A {
            totalLines += 1
        }
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
