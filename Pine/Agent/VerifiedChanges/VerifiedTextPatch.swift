//
//  VerifiedTextPatch.swift
//  Pine
//
//  Bounded deterministic diff and conservative positional three-way merge.
//

import Foundation

nonisolated struct VerifiedTextPatchPlan: Sendable, Equatable {
    let hunks: [VerifiedTextPatchHunk]
    let lcsCellCount: Int
}

nonisolated struct VerifiedPreparedTextResult: Sendable, Equatable {
    let content: Data
    let hunks: [VerifiedPreparedTextHunk]
    let lcsCellCount: Int
}

/// Text patching never searches globally for a matching block.
///
/// Preparation diffs the captured after-state against the supplied current
/// state, rejects any human edit intersecting a captured hunk plus two exact
/// guard lines, and maps the original range only by the bounded edit deltas
/// before it. It then verifies the complete guarded region at that resolved
/// position. A deleted/moved original block therefore conflicts even if
/// identical bytes appear elsewhere.
nonisolated enum VerifiedTextPatch {
    private static let contextLineCount = 2

    static func plan(
        before: Data,
        after: Data
    ) -> VerifiedTextPatchPlan? {
        guard isText(before), isText(after) else {
            return nil
        }
        let beforeLines = lines(in: before)
        let afterLines = lines(in: after)
        guard let cellCount = lcsCellCount(
            lhsCount: beforeLines.count,
            rhsCount: afterLines.count
        ) else {
            return nil
        }
        let steps = diffSteps(before: beforeLines, after: afterLines)
        let hunks = makeHunks(
            steps: steps,
            afterLines: afterLines
        )
        guard !hunks.isEmpty,
              hunks.count <= VerifiedPatchLimits.maximumHunkCount else {
            return nil
        }
        return VerifiedTextPatchPlan(
            hunks: hunks,
            lcsCellCount: cellCount
        )
    }

    static func estimatedLCSCellCount(
        before: Data,
        after: Data
    ) -> Int? {
        guard isText(before),
              isText(after) else {
            return nil
        }
        return lcsCellCount(
            lhsCount: lines(in: before).count,
            rhsCount: lines(in: after).count
        )
    }

    static func prepareInverse(
        hunks: [VerifiedTextPatchHunk],
        capturedAfter: Data,
        current: Data
    ) -> Result<VerifiedPreparedTextResult, VerifiedPatchConflictReason> {
        guard isText(capturedAfter),
              isText(current) else {
            return .failure(.currentContentIsNotText)
        }
        guard hunks.count <= VerifiedPatchLimits.maximumHunkCount else {
            return .failure(.resourceLimitExceeded)
        }

        let afterLines = lines(in: capturedAfter)
        let currentLines = lines(in: current)
        guard let cellCount = lcsCellCount(
            lhsCount: afterLines.count,
            rhsCount: currentLines.count
        ) else {
            return .failure(.resourceLimitExceeded)
        }
        let humanEdits = lineEdits(
            from: afterLines,
            to: currentLines
        )
        var resolved: [VerifiedPreparedTextHunk] = []

        for (index, hunk) in hunks.enumerated() {
            guard let capturedRange = checkedRange(
                start: hunk.afterStartLine,
                count: hunk.afterLineCount,
                upperBound: afterLines.count
            ) else {
                return .failure(.mappedRegionMismatch(hunkIndex: index))
            }
            let guardStart = hunk.afterStartLine
                - hunk.prefixContext.count
            guard guardStart >= 0,
                  let coreAndSuffixCount = checkedAdd(
                    hunk.afterLineCount,
                    hunk.suffixContext.count
                  ),
                  let guardEnd = checkedAdd(
                    hunk.afterStartLine,
                    coreAndSuffixCount
                  ),
                  guardEnd <= afterLines.count else {
                return .failure(.mappedRegionMismatch(hunkIndex: index))
            }
            let guardedRange = guardStart..<guardEnd
            guard !humanEdits.contains(where: {
                touches($0, guardedRange: guardedRange)
            }) else {
                return .failure(
                    .humanEditOverlapsAgentRegion(hunkIndex: index)
                )
            }

            guard let delta = positionalDelta(
                before: guardStart,
                edits: humanEdits
            ),
            let resolvedGuardStart = checkedOffset(
                guardStart,
                by: delta
            ),
            let resolvedCoreStart = checkedOffset(
                hunk.afterStartLine,
                by: delta
            ),
            let resolvedGuardEnd = checkedAdd(
                resolvedGuardStart,
                guardedRange.count
            ),
            resolvedGuardStart >= 0,
            resolvedGuardEnd <= currentLines.count,
            let resolvedCoreRange = checkedRange(
                start: resolvedCoreStart,
                count: capturedRange.count,
                upperBound: currentLines.count
            ) else {
                return .failure(.mappedRegionMismatch(hunkIndex: index))
            }

            let expectedGuard = Array(afterLines[guardedRange])
            let actualGuard = Array(
                currentLines[resolvedGuardStart..<resolvedGuardEnd]
            )
            guard expectedGuard == actualGuard else {
                return .failure(.mappedRegionMismatch(hunkIndex: index))
            }
            resolved.append(VerifiedPreparedTextHunk(
                capturedAfterRange: capturedRange,
                resolvedCurrentRange: resolvedCoreRange,
                replacementLines: hunk.beforeLines
            ))
        }

        guard !hasOverlap(resolved) else {
            return .failure(.overlappingResolvedHunks)
        }
        var result = currentLines
        for hunk in resolved.sorted(by: descendingOrder) {
            result.replaceSubrange(
                hunk.resolvedCurrentRange,
                with: hunk.replacementLines
            )
        }
        return .success(VerifiedPreparedTextResult(
            content: result.reduce(into: Data()) { $0.append($1) },
            hunks: resolved,
            lcsCellCount: cellCount
        ))
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

    private static func lcsCellCount(
        lhsCount: Int,
        rhsCount: Int
    ) -> Int? {
        guard lhsCount <= VerifiedPatchLimits.maximumLineCount,
              rhsCount <= VerifiedPatchLimits.maximumLineCount else {
            return nil
        }
        let lhs = lhsCount.addingReportingOverflow(1)
        let rhs = rhsCount.addingReportingOverflow(1)
        guard !lhs.overflow,
              !rhs.overflow else {
            return nil
        }
        let cells = lhs.partialValue.multipliedReportingOverflow(
            by: rhs.partialValue
        )
        guard !cells.overflow,
              cells.partialValue
                <= VerifiedPatchLimits.maximumLCSCellCountPerDiff else {
            return nil
        }
        return cells.partialValue
    }

    private static func makeHunks(
        steps: [DiffStep],
        afterLines: [Data]
    ) -> [VerifiedTextPatchHunk] {
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

    private static func lineEdits(
        from before: [Data],
        to after: [Data]
    ) -> [LineEdit] {
        let steps = diffSteps(before: before, after: after)
        var edits: [LineEdit] = []
        var beforeIndex = 0
        var activeStart: Int?
        var removedCount = 0
        var replacement: [Data] = []

        func finishEdit() {
            guard let start = activeStart else { return }
            edits.append(LineEdit(
                baseRange: start..<(start + removedCount),
                replacement: replacement
            ))
            activeStart = nil
            removedCount = 0
            replacement = []
        }

        for step in steps {
            switch step {
            case .equal:
                finishEdit()
                beforeIndex += 1
            case .remove:
                if activeStart == nil { activeStart = beforeIndex }
                removedCount += 1
                beforeIndex += 1
            case .add(let line):
                if activeStart == nil { activeStart = beforeIndex }
                replacement.append(line)
            }
        }
        finishEdit()
        return edits
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

    private static func touches(
        _ edit: LineEdit,
        guardedRange: Range<Int>
    ) -> Bool {
        if edit.baseRange.isEmpty {
            return edit.baseRange.lowerBound >= guardedRange.lowerBound
                && edit.baseRange.lowerBound <= guardedRange.upperBound
        }
        return edit.baseRange.overlaps(guardedRange)
    }

    private static func positionalDelta(
        before position: Int,
        edits: [LineEdit]
    ) -> Int? {
        var result = 0
        for edit in edits where edit.baseRange.upperBound <= position {
            let delta = edit.replacement.count
                .subtractingReportingOverflow(edit.baseRange.count)
            guard !delta.overflow else { return nil }
            let sum = result.addingReportingOverflow(delta.partialValue)
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }

    private static func checkedRange(
        start: Int,
        count: Int,
        upperBound: Int
    ) -> Range<Int>? {
        guard start >= 0,
              count >= 0,
              let end = checkedAdd(start, count),
              end <= upperBound else {
            return nil
        }
        return start..<end
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func checkedOffset(
        _ value: Int,
        by offset: Int
    ) -> Int? {
        checkedAdd(value, offset)
    }

    private static func hasOverlap(
        _ hunks: [VerifiedPreparedTextHunk]
    ) -> Bool {
        for lhsIndex in hunks.indices {
            for rhsIndex in hunks.indices where rhsIndex > lhsIndex {
                if rangesOverlap(
                    hunks[lhsIndex].resolvedCurrentRange,
                    hunks[rhsIndex].resolvedCurrentRange
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

    private static func descendingOrder(
        _ lhs: VerifiedPreparedTextHunk,
        _ rhs: VerifiedPreparedTextHunk
    ) -> Bool {
        lhs.resolvedCurrentRange.lowerBound
            > rhs.resolvedCurrentRange.lowerBound
    }

    private enum DiffStep {
        case equal
        case remove(Data)
        case add(Data)
    }

    private struct LineEdit {
        let baseRange: Range<Int>
        let replacement: [Data]
    }
}
