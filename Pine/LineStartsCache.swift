//
//  LineStartsCache.swift
//  Pine
//

import Foundation

/// Кэш позиций начала строк для быстрого определения номера строки по символьному смещению.
/// Использует binary search — O(log n) вместо линейного сканирования O(n).
struct LineStartsCache {
    /// Массив UTF-16 смещений начала каждой строки. Первый элемент всегда 0.
    private var lineStarts: [Int]

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

    /// Инкрементально обновляет кэш после редактирования текста.
    /// - Parameters:
    ///   - editedRange: Диапазон в новом тексте, покрывающий вставленный/изменённый контент.
    ///   - changeInLength: Разница в длине (положительная — вставка, отрицательная — удаление).
    ///   - source: Новый текст (после редактирования) как NSString.
    mutating func update(editedRange: NSRange, changeInLength: Int, in source: NSString) {
        let editLocation = editedRange.location

        // Находим первую строку, затронутую изменением (binary search).
        // Это строка, чей start <= editLocation.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= editLocation {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let firstAffectedIdx = low

        // Находим последнюю строку, затронутую изменением.
        // При вставке: конец editedRange в новом тексте.
        // При удалении: editLocation + abs(changeInLength) в старых координатах.
        let oldEndOfEdit: Int
        if changeInLength >= 0 {
            oldEndOfEdit = editLocation
        } else {
            oldEndOfEdit = editLocation - changeInLength // editLocation + abs(changeInLength)
        }

        // Удаляем все строки, начинающиеся внутри затронутой области (в старых координатах).
        var lastRemovedIdx = firstAffectedIdx
        while lastRemovedIdx + 1 < lineStarts.count && lineStarts[lastRemovedIdx + 1] <= oldEndOfEdit {
            lastRemovedIdx += 1
        }

        // Удаляем устаревшие строки после firstAffectedIdx.
        if lastRemovedIdx > firstAffectedIdx {
            lineStarts.removeSubrange((firstAffectedIdx + 1)...lastRemovedIdx)
        }

        // Сдвигаем все строки после затронутой области на changeInLength.
        if changeInLength != 0 {
            for i in (firstAffectedIdx + 1)..<lineStarts.count {
                lineStarts[i] += changeInLength
            }
        }

        // Сканируем editedRange в новом тексте и вставляем новые строки.
        let scanEnd = min(editedRange.location + editedRange.length, source.length)
        var newStarts: [Int] = []
        for i in editedRange.location..<scanEnd where source.character(at: i) == 0x0A {
            newStarts.append(i + 1)
        }

        if !newStarts.isEmpty {
            lineStarts.insert(contentsOf: newStarts, at: firstAffectedIdx + 1)
        }
    }
}
