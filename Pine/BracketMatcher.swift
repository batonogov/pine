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

/// Алгоритм поиска парных скобок.
/// Поддерживает `()`, `{}`, `[]`.
enum BracketMatcher {

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

        while index < length {
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

        while index >= 0 {
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

    private static func isInSkipRange(_ position: Int, skipRanges: [NSRange]) -> Bool {
        skipRanges.contains { NSLocationInRange(position, $0) }
    }
}
