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
    let mappingCellCount: Int
}

/// Text patching never searches globally for a matching block.
///
/// Preparation diffs the captured after-state against the supplied current
/// state and rejects any human edit intersecting a captured hunk plus two exact
/// guard lines. It accepts a resolved range only when every optimal LCS
/// alignment preserves that guarded region contiguously at one identical
/// current position. A deleted, moved, reordered, or duplicated block
/// therefore conflicts instead of letting one deterministic LCS tie-break
/// select unrelated equal bytes.
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
        guard let table = makeLCSTable(
            before: beforeLines,
            after: afterLines
        ) else {
            return nil
        }
        let steps = diffSteps(
            before: beforeLines,
            after: afterLines,
            table: table
        )
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
            lcsCellCount: table.cellCount
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
        current: Data,
        mappingCellBudget: Int
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
        guard mappingCellBudget >= 0,
              let table = makeLCSTable(
                before: afterLines,
                after: currentLines
              ) else {
            return .failure(.resourceLimitExceeded)
        }
        let mappingCells = table.cellCount.multipliedReportingOverflow(
            by: hunks.count
        )
        guard !mappingCells.overflow,
              mappingCells.partialValue <= mappingCellBudget else {
            return .failure(.resourceLimitExceeded)
        }
        let steps = diffSteps(
            before: afterLines,
            after: currentLines,
            table: table
        )
        let humanEdits = lineEdits(steps: steps)
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
            guard !guardedRange.isEmpty else {
                return .failure(
                    .ambiguousCurrentMapping(hunkIndex: index)
                )
            }
            guard !humanEdits.contains(where: {
                touches($0, guardedRange: guardedRange)
            }) else {
                return .failure(
                    .humanEditOverlapsAgentRegion(hunkIndex: index)
                )
            }
            let expectedGuard = Array(afterLines[guardedRange])

            guard let resolvedGuardStart = uniqueOptimalMapping(
                guardedRange: guardedRange,
                before: afterLines,
                after: currentLines,
                table: table
            ) else {
                return .failure(
                    .ambiguousCurrentMapping(hunkIndex: index)
                )
            }
            guard let resolvedCoreStart = checkedAdd(
                resolvedGuardStart,
                hunk.prefixContext.count
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

            guard duplicateMappingIsStable(
                capturedRange: guardedRange,
                resolvedStart: resolvedGuardStart,
                capturedLines: afterLines,
                currentLines: currentLines,
                humanEdits: humanEdits
            ) else {
                return .failure(
                    .ambiguousCurrentMapping(hunkIndex: index)
                )
            }
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
            lcsCellCount: table.cellCount,
            mappingCellCount: mappingCells.partialValue
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
        steps: [DiffStep]
    ) -> [LineEdit] {
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

    private static func makeLCSTable(
        before: [Data],
        after: [Data]
    ) -> LCSTable? {
        guard let cellCount = lcsCellCount(
            lhsCount: before.count,
            rhsCount: after.count
        ) else {
            return nil
        }
        let columnCount = after.count + 1
        var lengths = [Int](repeating: 0, count: cellCount)
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
        return LCSTable(
            lengths: lengths,
            columnCount: columnCount
        )
    }

    private static func diffSteps(
        before: [Data],
        after: [Data],
        table: LCSTable
    ) -> [DiffStep] {
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
            let removeLength = table.value(
                beforeIndex: beforeIndex + 1,
                afterIndex: afterIndex
            )
            let addLength = table.value(
                beforeIndex: beforeIndex,
                afterIndex: afterIndex + 1
            )
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

    /// Returns a current start only when every optimal LCS alignment preserves
    /// the guarded region contiguously at that same start.
    ///
    /// This walks the optimal-alignment DAG with two rolling rows. `bad`
    /// tracks any optimal path that skips/reorders a guarded line; min/max
    /// track all starts used by paths that preserve the whole guard.
    private static func uniqueOptimalMapping(
        guardedRange: Range<Int>,
        before: [Data],
        after: [Data],
        table: LCSTable
    ) -> Int? {
        guard !guardedRange.isEmpty,
              guardedRange.lowerBound >= 0,
              guardedRange.upperBound <= before.count else {
            return nil
        }
        var current = [MappingState](
            repeating: .unreachable,
            count: after.count + 1
        )
        current[0] = .initial

        for beforeIndex in 0...before.count {
            var next = [MappingState](
                repeating: .unreachable,
                count: after.count + 1
            )
            for afterIndex in 0...after.count {
                let state = current[afterIndex]
                guard state.isReachable else { continue }
                let optimum = table.value(
                    beforeIndex: beforeIndex,
                    afterIndex: afterIndex
                )
                if afterIndex < after.count,
                   table.value(
                    beforeIndex: beforeIndex,
                    afterIndex: afterIndex + 1
                   ) == optimum {
                    current[afterIndex + 1].merge(advance(
                        state,
                        action: .skipAfter,
                        beforeIndex: beforeIndex,
                        afterIndex: afterIndex,
                        guardedRange: guardedRange
                    ))
                }
                guard beforeIndex < before.count else { continue }
                if table.value(
                    beforeIndex: beforeIndex + 1,
                    afterIndex: afterIndex
                ) == optimum {
                    next[afterIndex].merge(advance(
                        state,
                        action: .skipBefore,
                        beforeIndex: beforeIndex,
                        afterIndex: afterIndex,
                        guardedRange: guardedRange
                    ))
                }
                if afterIndex < after.count,
                   before[beforeIndex] == after[afterIndex],
                   table.value(
                    beforeIndex: beforeIndex + 1,
                    afterIndex: afterIndex + 1
                   ) + 1 == optimum {
                    next[afterIndex + 1].merge(advance(
                        state,
                        action: .match,
                        beforeIndex: beforeIndex,
                        afterIndex: afterIndex,
                        guardedRange: guardedRange
                    ))
                }
            }
            if beforeIndex == before.count {
                let result = current[after.count]
                guard result.goodReachable,
                      !result.badReachable,
                      let minimum = result.minimumStart,
                      minimum == result.maximumStart else {
                    return nil
                }
                return minimum
            }
            current = next
        }
        return nil
    }

    private static func advance(
        _ state: MappingState,
        action: AlignmentAction,
        beforeIndex: Int,
        afterIndex: Int,
        guardedRange: Range<Int>
    ) -> MappingState {
        var result = MappingState.unreachable
        result.badReachable = state.badReachable
        guard state.goodReachable else { return result }

        if beforeIndex < guardedRange.lowerBound
            || beforeIndex >= guardedRange.upperBound {
            result.includeGood(from: state)
            return result
        }
        if beforeIndex == guardedRange.lowerBound {
            switch action {
            case .skipAfter:
                result.includeGood(start: nil)
            case .match:
                result.includeGood(start: afterIndex)
            case .skipBefore:
                result.badReachable = true
            }
            return result
        }
        guard action == .match else {
            result.badReachable = true
            return result
        }
        result.includeGood(from: state)
        return result
    }

    /// Equal guarded blocks have no intrinsic identity. When more than one
    /// occurrence exists, preparation accepts only a uniform positional shift
    /// with every human edit outside the complete duplicate envelope.
    ///
    /// This rejects a delete/move/reorder that a unique LCS can otherwise
    /// misinterpret by pairing equal occurrences in their new ordinal order.
    private static func duplicateMappingIsStable(
        capturedRange: Range<Int>,
        resolvedStart: Int,
        capturedLines: [Data],
        currentLines: [Data],
        humanEdits: [LineEdit]
    ) -> Bool {
        let pattern = Array(capturedLines[capturedRange])
        let capturedOccurrences = occurrenceStarts(
            of: pattern,
            in: capturedLines
        )
        let currentOccurrences = occurrenceStarts(
            of: pattern,
            in: currentLines
        )
        guard let capturedOrdinal = capturedOccurrences.firstIndex(
            of: capturedRange.lowerBound
        ),
        let currentOrdinal = currentOccurrences.firstIndex(
            of: resolvedStart
        ) else {
            return false
        }
        guard capturedOccurrences.count > 1
                || currentOccurrences.count > 1 else {
            return true
        }
        guard capturedOccurrences.count == currentOccurrences.count,
              capturedOrdinal == currentOrdinal,
              let firstCaptured = capturedOccurrences.first,
              let lastCaptured = capturedOccurrences.last,
              let firstCurrent = currentOccurrences.first else {
            return false
        }
        let delta = firstCurrent - firstCaptured
        for index in capturedOccurrences.indices {
            guard currentOccurrences[index] - capturedOccurrences[index]
                    == delta else {
                return false
            }
        }
        let envelopeEnd = lastCaptured + pattern.count
        let duplicateEnvelope = firstCaptured..<envelopeEnd
        return !humanEdits.contains {
            touches($0, guardedRange: duplicateEnvelope)
        }
    }

    private static func occurrenceStarts(
        of pattern: [Data],
        in lines: [Data]
    ) -> [Int] {
        guard !pattern.isEmpty,
              pattern.count <= lines.count else {
            return []
        }
        var prefixLengths = [Int](
            repeating: 0,
            count: pattern.count
        )
        var prefixLength = 0
        for index in pattern.indices.dropFirst() {
            while prefixLength > 0,
                  pattern[index] != pattern[prefixLength] {
                prefixLength = prefixLengths[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] {
                prefixLength += 1
            }
            prefixLengths[index] = prefixLength
        }

        var result: [Int] = []
        var matched = 0
        for index in lines.indices {
            while matched > 0,
                  lines[index] != pattern[matched] {
                matched = prefixLengths[matched - 1]
            }
            if lines[index] == pattern[matched] {
                matched += 1
            }
            if matched == pattern.count {
                result.append(index - pattern.count + 1)
                matched = prefixLengths[matched - 1]
            }
        }
        return result
    }

    private static func touches(
        _ edit: LineEdit,
        guardedRange: Range<Int>
    ) -> Bool {
        if edit.baseRange.isEmpty {
            return edit.baseRange.lowerBound > guardedRange.lowerBound
                && edit.baseRange.lowerBound < guardedRange.upperBound
        }
        return edit.baseRange.overlaps(guardedRange)
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

    private struct LCSTable {
        let lengths: [Int]
        let columnCount: Int

        var cellCount: Int {
            lengths.count
        }

        func value(
            beforeIndex: Int,
            afterIndex: Int
        ) -> Int {
            lengths[beforeIndex * columnCount + afterIndex]
        }
    }

    private enum AlignmentAction: Equatable {
        case skipBefore
        case skipAfter
        case match
    }

    private struct MappingState {
        var goodReachable: Bool
        var badReachable: Bool
        var minimumStart: Int?
        var maximumStart: Int?

        static let unreachable = MappingState(
            goodReachable: false,
            badReachable: false,
            minimumStart: nil,
            maximumStart: nil
        )

        static let initial = MappingState(
            goodReachable: true,
            badReachable: false,
            minimumStart: nil,
            maximumStart: nil
        )

        var isReachable: Bool {
            goodReachable || badReachable
        }

        mutating func includeGood(start: Int?) {
            goodReachable = true
            guard let start else { return }
            minimumStart = min(minimumStart ?? start, start)
            maximumStart = max(maximumStart ?? start, start)
        }

        mutating func includeGood(from other: MappingState) {
            guard other.goodReachable else { return }
            goodReachable = true
            if let minimum = other.minimumStart {
                minimumStart = min(minimumStart ?? minimum, minimum)
            }
            if let maximum = other.maximumStart {
                maximumStart = max(maximumStart ?? maximum, maximum)
            }
        }

        mutating func merge(_ other: MappingState) {
            badReachable = badReachable || other.badReachable
            includeGood(from: other)
        }
    }
}
