//
//  FoldRangeCalculator.swift
//  Pine
//

import Foundation

/// Описание складываемого региона кода.
struct FoldableRange: Equatable, Sendable {
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
enum FoldKind: Equatable, Sendable {
    case braces       // { }
    case brackets     // [ ]
    case parentheses  // ( )
}

/// Вычисляет складываемые регионы по парным скобкам.
enum FoldRangeCalculator {

    /// Maximum nesting depth for bracket matching stack.
    /// Prevents unbounded memory growth on pathological input.
    static let maxStackDepth = 500

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
        for i in 0..<length where source.character(at: i) == ASCII.newline {
            lineStarts.append(i + 1)
        }

        // Стек: (charIndex, kind)
        var stack: [(charIndex: Int, kind: FoldKind)] = []
        var results: [FoldableRange] = []

        for i in 0..<length {
            if isInSkipRange(i, skipRanges: skipRanges) { continue }

            let char = source.character(at: i)

            if let info = openBrackets[char] {
                // Skip push if stack is at maximum depth to prevent unbounded growth
                if stack.count < maxStackDepth {
                    stack.append((charIndex: i, kind: info.kind))
                }
            } else if let expectedOpen = closeBrackets[char] {
                // Скобки правильно вложены — matching opener всегда на вершине стека
                if let last = stack.last,
                   source.character(at: last.charIndex) == expectedOpen {
                    stack.removeLast()

                    let startLine = lineNumber(at: last.charIndex, lineStarts: lineStarts)
                    let endLine = lineNumber(at: i, lineStarts: lineStarts)

                    // Только многострочные регионы
                    if endLine > startLine {
                        results.append(FoldableRange(
                            startLine: startLine,
                            endLine: endLine,
                            startCharIndex: last.charIndex,
                            endCharIndex: i,
                            kind: last.kind
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
        var lo = 0, hi = skipRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = skipRanges[mid]
            if position < range.location {
                hi = mid - 1
            } else if position >= NSMaxRange(range) {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
