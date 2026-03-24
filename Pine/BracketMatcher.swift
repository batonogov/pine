//
//  BracketMatcher.swift
//  Pine
//

import Foundation

/// Результат поиска парной скобки.
struct BracketMatch: Equatable {
    /// UTF-16 позиция открывающей скобки
    let opener: Int
    /// UTF-16 позиция закрывающей скобки
    let closer: Int
}

/// Результат подсветки скобки: найдена пара или orphan.
enum BracketHighlightResult: Equatable {
    /// Скобки совпали — подсветить обе
    case matched(BracketMatch)
    /// Скобка без пары — подсветить как ошибку
    case unmatched(position: Int)
}

/// Алгоритм поиска парных скобок.
/// Поддерживает `()`, `{}`, `[]`.
enum BracketMatcher {

    /// Maximum number of characters to scan in each direction when searching
    /// for a matching bracket. Prevents hangs on very large files.
    static let maxScanIterations = 100_000

    private static let openBrackets: [unichar: unichar] = [
        0x28: 0x29, // ( → )
        0x7B: 0x7D, // { → }
        0x5B: 0x5D  // [ → ]
    ]

    private static let closeBrackets: [unichar: unichar] = [
        0x29: 0x28, // ) → (
        0x7D: 0x7B, // } → {
        0x5D: 0x5B  // ] → [
    ]

    /// Ищет парную скобку относительно позиции курсора.
    ///
    /// - Parameters:
    ///   - text: исходный текст
    ///   - cursorPosition: позиция курсора (UTF-16 offset, между символами)
    ///   - skipRanges: диапазоны строк/комментариев, в которых скобки игнорируются
    /// - Returns: пара позиций (opener, closer) или nil, если скобка не найдена
    static func findMatch(
        in text: String,
        cursorPosition: Int,
        skipRanges: [NSRange] = []
    ) -> BracketMatch? {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return nil }

        // Приоритет: сначала проверяем символ перед курсором, потом после
        if cursorPosition > 0 {
            let charBefore = source.character(at: cursorPosition - 1)
            if !isInSkipRange(cursorPosition - 1, skipRanges: skipRanges) {
                if let match = tryMatch(source: source, position: cursorPosition - 1,
                                        character: charBefore, skipRanges: skipRanges) {
                    return match
                }
            }
        }

        if cursorPosition < length {
            let charAfter = source.character(at: cursorPosition)
            if !isInSkipRange(cursorPosition, skipRanges: skipRanges) {
                if let match = tryMatch(source: source, position: cursorPosition,
                                        character: charAfter, skipRanges: skipRanges) {
                    return match
                }
            }
        }

        return nil
    }

    private static func tryMatch(
        source: NSString,
        position: Int,
        character: unichar,
        skipRanges: [NSRange]
    ) -> BracketMatch? {
        if let expectedClose = openBrackets[character] {
            // Открывающая скобка → ищем закрывающую вперёд
            if let closePos = scanForward(source: source, from: position + 1,
                                          open: character, close: expectedClose,
                                          skipRanges: skipRanges) {
                return BracketMatch(opener: position, closer: closePos)
            }
        } else if let expectedOpen = closeBrackets[character] {
            // Закрывающая скобка → ищем открывающую назад
            if let openPos = scanBackward(source: source, from: position - 1,
                                          open: expectedOpen, close: character,
                                          skipRanges: skipRanges) {
                return BracketMatch(opener: openPos, closer: position)
            }
        }
        return nil
    }

    private static func scanForward(
        source: NSString,
        from start: Int,
        open: unichar,
        close: unichar,
        skipRanges: [NSRange]
    ) -> Int? {
        var depth = 1
        var index = start
        let length = source.length
        var iterations = 0

        while index < length {
            iterations += 1
            if iterations > maxScanIterations { return nil }

            if isInSkipRange(index, skipRanges: skipRanges) {
                index += 1
                continue
            }
            let char = source.character(at: index)
            if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func scanBackward(
        source: NSString,
        from start: Int,
        open: unichar,
        close: unichar,
        skipRanges: [NSRange]
    ) -> Int? {
        var depth = 1
        var index = start
        var iterations = 0

        while index >= 0 {
            iterations += 1
            if iterations > maxScanIterations { return nil }

            if isInSkipRange(index, skipRanges: skipRanges) {
                index -= 1
                continue
            }
            let char = source.character(at: index)
            if char == close {
                depth += 1
            } else if char == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Bracket detection at cursor

    /// Находит позицию скобки, прилегающей к курсору (перед или после).
    /// Возвращает UTF-16 позицию скобки или nil, если скобки рядом нет.
    /// Приоритет: символ перед курсором проверяется первым.
    static func bracketAdjacentToCursor(
        in text: String,
        cursorPosition: Int,
        skipRanges: [NSRange] = []
    ) -> Int? {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return nil }

        if cursorPosition > 0 {
            let pos = cursorPosition - 1
            if !isInSkipRange(pos, skipRanges: skipRanges) {
                let char = source.character(at: pos)
                if openBrackets[char] != nil || closeBrackets[char] != nil {
                    return pos
                }
            }
        }

        if cursorPosition < length {
            let pos = cursorPosition
            if !isInSkipRange(pos, skipRanges: skipRanges) {
                let char = source.character(at: pos)
                if openBrackets[char] != nil || closeBrackets[char] != nil {
                    return pos
                }
            }
        }

        return nil
    }

    /// Определяет тип подсветки для скобки у курсора:
    /// `.matched` — пара найдена, `.unmatched` — orphan скобка, `nil` — скобки нет.
    static func findHighlight(
        in text: String,
        cursorPosition: Int,
        skipRanges: [NSRange] = []
    ) -> BracketHighlightResult? {
        guard let bracketPos = bracketAdjacentToCursor(
            in: text, cursorPosition: cursorPosition, skipRanges: skipRanges
        ) else {
            return nil
        }

        // Ищем match именно для найденной скобки, а не перебираем обе позиции заново.
        // Без этого возможна рассогласовка: bracketAdjacentToCursor выбирает orphan на одной
        // позиции, а findMatch находит match для скобки на другой позиции.
        if let match = findMatchForBracket(
            in: text, at: bracketPos, skipRanges: skipRanges
        ) {
            return .matched(match)
        }

        return .unmatched(position: bracketPos)
    }

    /// Ищет парную скобку для конкретной позиции (без перебора соседних позиций).
    static func findMatchForBracket(
        in text: String,
        at position: Int,
        skipRanges: [NSRange] = []
    ) -> BracketMatch? {
        let source = text as NSString
        let length = source.length
        guard position >= 0, position < length else { return nil }
        guard !isInSkipRange(position, skipRanges: skipRanges) else { return nil }

        let character = source.character(at: position)
        return tryMatch(
            source: source, position: position,
            character: character, skipRanges: skipRanges
        )
    }

    private static func isInSkipRange(_ position: Int, skipRanges: [NSRange]) -> Bool {
        skipRanges.contains { NSLocationInRange(position, $0) }
    }
}
