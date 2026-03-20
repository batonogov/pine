//
//  LineStartsCache.swift
//  Pine
//

import Foundation

/// Кэш позиций начала строк для быстрого определения номера строки по символьному смещению.
/// Использует binary search — O(log n) вместо линейного сканирования O(n).
struct LineStartsCache {
    /// Массив UTF-16 смещений начала каждой строки. Первый элемент всегда 0.
    private let lineStarts: [Int]

    /// Количество строк в тексте (1-based).
    var lineCount: Int { lineStarts.count }

    /// Создаёт кэш из текста, сканируя позиции '\n'.
    init(text: String) {
        self.init(source: text as NSString)
    }

    /// Создаёт кэш из NSString, сканируя позиции '\n'.
    init(source: NSString) {
        let length = source.length
        var starts: [Int] = [0]
        for i in 0..<length where source.character(at: i) == 0x0A {
            starts.append(i + 1)
        }
        lineStarts = starts
    }

    /// Возвращает 1-based номер строки для данного UTF-16 символьного смещения.
    /// Использует binary search — O(log n).
    func lineNumber(at charIndex: Int) -> Int {
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
}
