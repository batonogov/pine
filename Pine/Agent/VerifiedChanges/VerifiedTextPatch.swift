//
//  VerifiedTextPatch.swift
//  Pine
//
//  Deterministic line diff and checked inverse-hunk application for #933.
//

import Foundation

nonisolated enum VerifiedTextPatch {
    static let maximumLineCount = 4_096
    static let maximumDiffCellCount = 4_000_000
    private static let contextLineCount = 2

    static func canDiff(before: Data, after: Data) -> Bool {
        guard isText(before),
              isText(after) else {
            return false
        }
        let beforeLines = lines(in: before)
        let afterLines = lines(in: after)
        guard beforeLines.count <= maximumLineCount,
              afterLines.count <= maximumLineCount else {
            return false
        }
        let cellCount = (beforeLines.count + 1)
            .multipliedReportingOverflow(by: afterLines.count + 1)
        return !cellCount.overflow
            && cellCount.partialValue <= maximumDiffCellCount
    }

    static func makeHunks(
        before: Data,
        after: Data
    ) -> [VerifiedTextPatchHunk] {
        let beforeLines = lines(in: before)
        let afterLines = lines(in: after)
        let steps = diffSteps(before: beforeLines, after: afterLines)
        var hunks: [VerifiedTextPatchHunk] = []
        var beforeIndex = 0
        var afterIndex = 0
        var activeBeforeStart: Int?
        var activeAfterStart: Int?
        var removed: [Data] = []
        var added: [Data] = []

        func finishHunk() {
            guard let beforeStart = activeBeforeStart,
                  let afterStart = activeAfterStart else {
                return
            }
            let prefixStart = max(0, afterStart - contextLineCount)
            let suffixStart = afterStart + added.count
            let suffixEnd = min(
                afterLines.count,
                suffixStart + contextLineCount
            )
            hunks.append(VerifiedTextPatchHunk(
                beforeStartLine: beforeStart,
                beforeLineCount: removed.count,
                afterStartLine: afterStart,
                afterLineCount: added.count,
                prefixContext: Array(afterLines[prefixStart..<afterStart]),
                afterLines: added,
                beforeLines: removed,
                suffixContext: Array(afterLines[suffixStart..<suffixEnd])
            ))
            activeBeforeStart = nil
            activeAfterStart = nil
            removed = []
            added = []
        }

        for step in steps {
            switch step {
            case .equal:
                finishHunk()
                beforeIndex += 1
                afterIndex += 1
            case .remove(let line):
                if activeBeforeStart == nil {
                    activeBeforeStart = beforeIndex
                    activeAfterStart = afterIndex
                }
                removed.append(line)
                beforeIndex += 1
            case .add(let line):
                if activeBeforeStart == nil {
                    activeBeforeStart = beforeIndex
                    activeAfterStart = afterIndex
                }
                added.append(line)
                afterIndex += 1
            }
        }
        finishHunk()
        return hunks
    }

    static func applyInverse(
        hunks: [VerifiedTextPatchHunk],
        to current: Data
    ) -> Result<Data, VerifiedPatchConflictReason> {
        guard isText(current) else {
            return .failure(.currentContentIsNotText)
        }
        let currentLines = lines(in: current)
        var resolutions: [ResolvedHunk] = []

        for (index, hunk) in hunks.enumerated() {
            let pattern = hunk.prefixContext
                + hunk.afterLines
                + hunk.suffixContext
            guard !pattern.isEmpty else {
                return .failure(.ambiguousTextContext(hunkIndex: index))
            }
            let occurrences = occurrenceStarts(
                of: pattern,
                in: currentLines
            )
            guard !occurrences.isEmpty else {
                return .failure(.textContextMissing(hunkIndex: index))
            }
            guard occurrences.count == 1,
                  let occurrence = occurrences.first else {
                return .failure(.ambiguousTextContext(hunkIndex: index))
            }
            let coreStart = occurrence + hunk.prefixContext.count
            let coreEnd = coreStart + hunk.afterLines.count
            resolutions.append(ResolvedHunk(
                originalIndex: index,
                range: coreStart..<coreEnd,
                replacement: hunk.beforeLines
            ))
        }

        guard !hasOverlap(resolutions) else {
            return .failure(.overlappingResolvedHunks)
        }

        var result = currentLines
        for resolution in resolutions.sorted(by: descendingResolutionOrder) {
            result.replaceSubrange(
                resolution.range,
                with: resolution.replacement
            )
        }
        return .success(result.reduce(into: Data()) { $0.append($1) })
    }

    static func isText(_ data: Data) -> Bool {
        !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    static func lines(in data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        var lineStart = data.startIndex
        var index = lineStart
        while index < data.endIndex {
            if data[index] == 0x0A {
                let next = data.index(after: index)
                result.append(Data(data[lineStart..<next]))
                lineStart = next
            }
            index = data.index(after: index)
        }
        if lineStart < data.endIndex {
            result.append(Data(data[lineStart..<data.endIndex]))
        }
        return result
    }

    private static func diffSteps(
        before: [Data],
        after: [Data]
    ) -> [DiffStep] {
        let columnCount = after.count + 1
        var lengths = [Int](
            repeating: 0,
            count: (before.count + 1) * columnCount
        )
        if !before.isEmpty, !after.isEmpty {
            for beforeIndex in stride(
                from: before.count - 1,
                through: 0,
                by: -1
            ) {
                for afterIndex in stride(
                    from: after.count - 1,
                    through: 0,
                    by: -1
                ) {
                    let offset = beforeIndex * columnCount + afterIndex
                    if before[beforeIndex] == after[afterIndex] {
                        lengths[offset] = 1
                            + lengths[
                                (beforeIndex + 1) * columnCount
                                    + afterIndex + 1
                            ]
                    } else {
                        lengths[offset] = max(
                            lengths[
                                (beforeIndex + 1) * columnCount
                                    + afterIndex
                            ],
                            lengths[
                                beforeIndex * columnCount
                                    + afterIndex + 1
                            ]
                        )
                    }
                }
            }
        }

        var steps: [DiffStep] = []
        var beforeIndex = 0
        var afterIndex = 0
        while beforeIndex < before.count || afterIndex < after.count {
            if beforeIndex < before.count,
               afterIndex < after.count,
               before[beforeIndex] == after[afterIndex] {
                steps.append(.equal)
                beforeIndex += 1
                afterIndex += 1
                continue
            }
            if beforeIndex == before.count {
                steps.append(.add(after[afterIndex]))
                afterIndex += 1
                continue
            }
            if afterIndex == after.count {
                steps.append(.remove(before[beforeIndex]))
                beforeIndex += 1
                continue
            }

            let removeLength = lengths[
                (beforeIndex + 1) * columnCount + afterIndex
            ]
            let addLength = lengths[
                beforeIndex * columnCount + afterIndex + 1
            ]
            // Stable tie-break: removals precede additions. This makes patch
            // bytes independent of dictionary order, locale, or hash seeds.
            if removeLength >= addLength {
                steps.append(.remove(before[beforeIndex]))
                beforeIndex += 1
            } else {
                steps.append(.add(after[afterIndex]))
                afterIndex += 1
            }
        }
        return steps
    }

    private static func occurrenceStarts(
        of pattern: [Data],
        in lines: [Data]
    ) -> [Int] {
        guard pattern.count <= lines.count else { return [] }
        if pattern.isEmpty {
            return Array(0...lines.count)
        }
        var result: [Int] = []
        for start in 0...(lines.count - pattern.count)
        where Array(lines[start..<(start + pattern.count)]) == pattern {
            result.append(start)
            if result.count > 1 {
                return result
            }
        }
        return result
    }

    private static func hasOverlap(_ resolutions: [ResolvedHunk]) -> Bool {
        let ordered = resolutions.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.originalIndex < $1.originalIndex
        }
        for lhsIndex in ordered.indices {
            for rhsIndex in ordered.indices where rhsIndex > lhsIndex {
                if rangesOverlap(
                    ordered[lhsIndex].range,
                    ordered[rhsIndex].range
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func rangesOverlap(
        _ lhs: Range<Int>,
        _ rhs: Range<Int>
    ) -> Bool {
        if lhs.isEmpty, rhs.isEmpty {
            return lhs.lowerBound == rhs.lowerBound
        }
        if lhs.isEmpty {
            return lhs.lowerBound >= rhs.lowerBound
                && lhs.lowerBound <= rhs.upperBound
        }
        if rhs.isEmpty {
            return rhs.lowerBound >= lhs.lowerBound
                && rhs.lowerBound <= lhs.upperBound
        }
        return lhs.overlaps(rhs)
    }

    private static func descendingResolutionOrder(
        _ lhs: ResolvedHunk,
        _ rhs: ResolvedHunk
    ) -> Bool {
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound > rhs.range.lowerBound
        }
        return lhs.originalIndex > rhs.originalIndex
    }

    private enum DiffStep {
        case equal
        case remove(Data)
        case add(Data)
    }

    private struct ResolvedHunk {
        let originalIndex: Int
        let range: Range<Int>
        let replacement: [Data]
    }
}
