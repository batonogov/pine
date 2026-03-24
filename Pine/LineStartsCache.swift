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
        for i in 0..<length where source.character(at: i) == ASCII.newline {
            starts.append(i + 1)
        }
        lineStarts = starts
    }

    /// Возвращает 0-based индекс строки, содержащей данное UTF-16 смещение.
    private func lineIndex(containing charIndex: Int) -> Int {
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
        return low
    }

    /// Возвращает 1-based номер строки для данного UTF-16 символьного смещения.
    /// Использует binary search — O(log n).
    func lineNumber(at charIndex: Int) -> Int {
        lineIndex(containing: charIndex) + 1
    }

    /// Инкрементально обновляет кэш после редактирования текста.
    /// - Parameters:
    ///   - editedRange: Диапазон в новом тексте, покрывающий вставленный/изменённый контент.
    ///   - changeInLength: Разница в длине (положительная — вставка, отрицательная — удаление).
    ///   - source: Новый текст (после редактирования) как NSString.
    mutating func update(editedRange: NSRange, changeInLength: Int, in source: NSString) {
        let editLocation = editedRange.location

        // Находим первую строку, затронутую изменением (binary search).
        let firstAffectedIdx = lineIndex(containing: editLocation)

        // Конец затронутой области в старых координатах.
        // editedRange.length — длина в новом тексте, вычитаем changeInLength чтобы получить длину в старом.
        let oldEditLength = editedRange.length - changeInLength
        let oldEndOfEdit = editLocation + oldEditLength

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
        for i in editedRange.location..<scanEnd where source.character(at: i) == ASCII.newline {
            newStarts.append(i + 1)
        }

        if !newStarts.isEmpty {
            lineStarts.insert(contentsOf: newStarts, at: firstAffectedIdx + 1)
        }
    }
}
