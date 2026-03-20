//
//  FoldState.swift
//  Pine
//

import Foundation

/// Управляет состоянием свёрнутых регионов кода для одного таба.
struct FoldState {
    /// Текущие свёрнутые регионы.
    private(set) var foldedRanges: [FoldableRange] = []

    /// Сворачивает регион. Если уже свёрнут — ничего не делает.
    mutating func fold(_ range: FoldableRange) {
        guard !foldedRanges.contains(range) else { return }
        foldedRanges.append(range)
    }

    /// Разворачивает регион.
    mutating func unfold(_ range: FoldableRange) {
        foldedRanges.removeAll { $0 == range }
    }

    /// Переключает fold/unfold для региона.
    mutating func toggle(_ range: FoldableRange) {
        if isFolded(range) {
            unfold(range)
        } else {
            fold(range)
        }
    }

    /// Сворачивает все указанные регионы.
    mutating func foldAll(_ ranges: [FoldableRange]) {
        for range in ranges {
            fold(range)
        }
    }

    /// Разворачивает все регионы.
    mutating func unfoldAll() {
        foldedRanges.removeAll()
    }

    /// Проверяет, свёрнут ли данный регион.
    func isFolded(_ range: FoldableRange) -> Bool {
        foldedRanges.contains(range)
    }

    /// Проверяет, скрыта ли строка (попадает ли она внутрь свёрнутого региона).
    /// Строки startLine и endLine самого fold-а остаются видимыми.
    func isLineHidden(_ line: Int) -> Bool {
        foldedRanges.contains { range in
            line > range.startLine && line < range.endLine
        }
    }

    /// Количество скрытых строк при сворачивании региона.
    /// Не зависит от текущего состояния fold — просто разница между start и end.
    func hiddenLineCount(for range: FoldableRange) -> Int {
        max(0, range.endLine - range.startLine - 1)
    }
}
