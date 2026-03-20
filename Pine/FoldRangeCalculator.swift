//
//  FoldRangeCalculator.swift
//  Pine
//

import Foundation

/// Описание складываемого региона кода.
struct FoldableRange: Equatable {
    /// 1-based номер строки с открывающей скобкой
    let startLine: Int
    /// 1-based номер строки с закрывающей скобкой
    let endLine: Int
    /// UTF-16 смещение открывающего символа
    let startCharIndex: Int
    /// UTF-16 смещение закрывающего символа
    let endCharIndex: Int
    /// Тип складываемого региона
    let kind: FoldKind
}

/// Тип складываемого региона.
enum FoldKind: Equatable {
    case braces       // { }
    case brackets     // [ ]
    case parentheses  // ( )
}

/// Вычисляет складываемые регионы по парным скобкам.
enum FoldRangeCalculator {

    private static let openBrackets: [unichar: (close: unichar, kind: FoldKind)] = [
        0x7B: (0x7D, .braces),       // { → }
        0x5B: (0x5D, .brackets),     // [ → ]
        0x28: (0x29, .parentheses)   // ( → )
    ]

    private static let closeBrackets: [unichar: unichar] = [
        0x7D: 0x7B, // } → {
        0x5D: 0x5B, // ] → [
        0x29: 0x28  // ) → (
    ]

    /// Вычисляет все складываемые регионы в тексте.
    ///
    /// - Parameters:
    ///   - text: исходный текст
    ///   - skipRanges: диапазоны строк/комментариев, в которых скобки игнорируются
    /// - Returns: массив складываемых регионов, отсортированный по startLine
    static func calculate(
        text: String,
        skipRanges: [NSRange] = []
    ) -> [FoldableRange] {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return [] }

        // Предварительно вычисляем номера строк и позиции начала строк
        var lineStarts: [Int] = [0]
        for i in 0..<length where source.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }

        // Стек: (charIndex, kind)
        var stack: [(charIndex: Int, kind: FoldKind)] = []
        var results: [FoldableRange] = []

        for i in 0..<length {
            if isInSkipRange(i, skipRanges: skipRanges) { continue }

            let char = source.character(at: i)

            if let info = openBrackets[char] {
                stack.append((charIndex: i, kind: info.kind))
            } else if let expectedOpen = closeBrackets[char] {
                // Ищем matching opener в стеке
                if let lastIdx = stack.lastIndex(where: {
                    openBrackets[source.character(at: $0.charIndex)]?.close == char
                        && source.character(at: $0.charIndex) == expectedOpen
                }) {
                    let opener = stack[lastIdx]
                    stack.removeSubrange(lastIdx...)

                    let startLine = lineNumber(at: opener.charIndex, lineStarts: lineStarts)
                    let endLine = lineNumber(at: i, lineStarts: lineStarts)

                    // Только многострочные регионы
                    if endLine > startLine {
                        results.append(FoldableRange(
                            startLine: startLine,
                            endLine: endLine,
                            startCharIndex: opener.charIndex,
                            endCharIndex: i,
                            kind: opener.kind
                        ))
                    }
                }
            }
        }

        results.sort { $0.startLine < $1.startLine }
        return results
    }

    /// Возвращает 1-based номер строки для символьного смещения.
    private static func lineNumber(at charIndex: Int, lineStarts: [Int]) -> Int {
        // Binary search для эффективности
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charIndex {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1 // 1-based
    }

    private static func isInSkipRange(_ position: Int, skipRanges: [NSRange]) -> Bool {
        skipRanges.contains { NSLocationInRange(position, $0) }
    }
}
