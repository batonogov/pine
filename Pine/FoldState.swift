//
//  FoldState.swift
//  Pine
//

import Foundation

/// Управляет состоянием свёрнутых регионов кода для одного таба.
struct FoldState {
    /// Текущие свёрнутые регионы.
    private(set) var foldedRanges: [FoldableRange] = []

    /// Кэш скрытых строк для O(1) проверки isLineHidden.
    private var hiddenLines: Set<Int> = []

    /// Сворачивает регион. Если уже свёрнут — ничего не делает.
    mutating func fold(_ range: FoldableRange) {
        guard !foldedRanges.contains(range) else { return }
        foldedRanges.append(range)
        addHiddenLines(for: range)
    }

    /// Разворачивает регион.
    mutating func unfold(_ range: FoldableRange) {
        foldedRanges.removeAll { $0 == range }
        rebuildHiddenLines()
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
        hiddenLines.removeAll()
    }

    /// Проверяет, свёрнут ли данный регион.
    func isFolded(_ range: FoldableRange) -> Bool {
        foldedRanges.contains(range)
    }

    /// Проверяет, скрыта ли строка (попадает ли она внутрь свёрнутого региона).
    /// Заголовок `startLine` остаётся видимым. Для скобочных регионов видима
    /// также строка с закрывающей скобкой; indentation-регион скрывается до
    /// своей последней строки включительно.
    /// O(1) через Set lookup.
    func isLineHidden(_ line: Int) -> Bool {
        hiddenLines.contains(line)
    }

    /// Количество скрытых строк при сворачивании региона.
    /// Не зависит от текущего состояния fold.
    func hiddenLineCount(for range: FoldableRange) -> Int {
        switch range.kind {
        case .indentation:
            max(0, range.endLine - range.startLine)
        case .braces, .brackets, .parentheses:
            max(0, range.endLine - range.startLine - 1)
        }
    }

    // MARK: - Private

    private mutating func addHiddenLines(for range: FoldableRange) {
        let endExclusive = range.kind == .indentation
            ? range.endLine + 1
            : range.endLine
        guard endExclusive > range.startLine + 1 else { return }
        for line in (range.startLine + 1)..<endExclusive {
            hiddenLines.insert(line)
        }
    }

    private mutating func rebuildHiddenLines() {
        hiddenLines.removeAll()
        for range in foldedRanges {
            addHiddenLines(for: range)
        }
    }
}
