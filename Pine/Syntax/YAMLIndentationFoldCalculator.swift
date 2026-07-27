//
//  YAMLIndentationFoldCalculator.swift
//  Pine
//
//  Language-aware local folding for YAML indentation blocks (#1225).
//

import Foundation

/// A tolerant, UTF-16 based YAML indentation-fold calculator.
///
/// This is deliberately a bounded structural scanner rather than a complete
/// YAML parser. It recognizes block mappings, block sequences, and block
/// scalars while treating quoted scalars and flow collections as opaque for
/// indentation purposes. Incomplete buffers retain any valid surrounding
/// structure and never make fold calculation unbounded.
///
/// The caller runs this work away from the main actor. All offsets use
/// `NSString` UTF-16 coordinates to match `NSTextView` and `FoldableRange`.
nonisolated enum YAMLIndentationFoldCalculator {
    static let tabWidth = 8
    static let maxActiveDepth = 500
    private static let cancellationCharacterStride = 4_096
    private static let cancellationLineStride = 64

    typealias CancellationCheck = @Sendable () -> Bool

    struct Analysis: Sendable {
        let ranges: [FoldableRange]
        /// Sorted, merged comments, quoted scalars, and multiline scalars.
        /// Bracket folding skips these ranges for the same snapshot.
        let lexicalSkipRanges: [NSRange]
    }

    private enum LineKind {
        case blank
        case comment
        /// A physical line inside a quoted scalar, flow collection, or block
        /// scalar. Its indentation is content rather than YAML block scope.
        case continuation
        case code
    }

    private struct Line {
        let start: Int
        let contentEnd: Int
        /// Offset after the complete line terminator (`LF`, `CRLF`, or `CR`).
        /// The final physical line ends at the source length.
        let fullEnd: Int
        let indentEnd: Int
        let indentationColumn: Int
        let rawIsBlank: Bool
        var kind: LineKind
        var isSequenceEntry = false
        var headers: [HeaderCandidate] = []
    }

    private struct HeaderCandidate {
        let startLineIndex: Int
        let indentationColumn: Int
        let markerOffset: Int
        /// YAML permits a block sequence to be indented at the same level as
        /// the mapping key whose value it supplies (BLOCK-OUT context).
        let allowsIndentlessSequence: Bool
    }

    private struct ActiveBlock {
        let header: HeaderCandidate
        var lastIncludedLineIndex: Int
    }

    private struct QuoteState {
        let character: unichar
        let start: Int
    }

    private struct LexicalState {
        var quote: QuoteState?
        var flowStack: [unichar] = []
        /// Whether the next token inside a flow collection may begin a node.
        /// Plain scalars keep this false across physical line breaks.
        var nodeMayStart = true
    }

    private struct ParsedLine {
        let commentStart: Int?
        let mappingColon: Int?
        let sequenceMarker: Int?
        let explicitKeyMarker: Int?
        let blockScalar: BlockScalarHeader?
        let hasCode: Bool
        let hasTrailingPlainScalar: Bool
    }

    private struct BlockScalarHeader {
        let markerOffset: Int
        let explicitIndent: Int?
    }

    private struct BlockScalarContext {
        let headerIndex: Int
        let scalarIndent: Int
        let explicitIndent: Int?
        let lines: [Line]
    }

    /// Calculates YAML indentation folds and returns the lexical exclusions
    /// used by bracket folding during the same immutable pass.
    static func analyze(
        text: String,
        additionalSkipRanges: [NSRange] = [],
        isCancelled: CancellationCheck = { Task.isCancelled }
    ) -> Analysis? {
        guard !isCancelled() else { return nil }
        let source = text as NSString
        guard source.length > 0 else {
            return Analysis(ranges: [], lexicalSkipRanges: [])
        }

        guard var lines = makeLines(
            in: source,
            isCancelled: isCancelled
        ) else {
            return nil
        }
        var lexicalRanges: [NSRange] = []
        guard parseStructure(
            in: source,
            lines: &lines,
            lexicalRanges: &lexicalRanges,
            isCancelled: isCancelled
        ) else {
            return nil
        }
        guard !isCancelled() else { return nil }
        let exclusions = normalizedRanges(
            additionalSkipRanges + lexicalRanges,
            boundedBy: source.length
        )
        guard !isCancelled(),
              let resolvedRanges = resolveRanges(
                lines: lines,
                isCancelled: isCancelled
              ) else {
            return nil
        }
        let ranges = canonicalizedForDisplay(resolvedRanges)
        guard !isCancelled() else { return nil }
        return Analysis(
            ranges: ranges,
            lexicalSkipRanges: exclusions
        )
    }

    /// Convenience API for focused calculator tests.
    static func calculate(
        text: String,
        skipRanges: [NSRange] = []
    ) -> [FoldableRange] {
        analyze(
            text: text,
            additionalSkipRanges: skipRanges
        )?.ranges ?? []
    }

    // MARK: - Physical lines

    private static func makeLines(
        in source: NSString,
        isCancelled: CancellationCheck
    ) -> [Line]? {
        var bounds: [(start: Int, end: Int)] = []
        var lineStart = 0
        var index = 0
        var nextCancellationCheck = cancellationCharacterStride

        while index < source.length {
            if index >= nextCancellationCheck {
                guard !isCancelled() else { return nil }
                nextCancellationCheck =
                    index + cancellationCharacterStride
            }
            let character = source.character(at: index)
            if character == ASCII.carriageReturn {
                bounds.append((lineStart, index))
                if index + 1 < source.length,
                   source.character(at: index + 1) == ASCII.newline {
                    index += 2
                } else {
                    index += 1
                }
                lineStart = index
            } else if character == ASCII.newline {
                bounds.append((lineStart, index))
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        bounds.append((lineStart, source.length))

        var lines: [Line] = []
        lines.reserveCapacity(bounds.count)
        for (boundIndex, bound) in bounds.enumerated() {
            if boundIndex.isMultiple(
                of: cancellationLineStride
            ), isCancelled() {
                return nil
            }
            var cursor = bound.start
            var column = 0
            var nextIndentCancellationCheck =
                cursor + cancellationCharacterStride
            while cursor < bound.end {
                if cursor >= nextIndentCancellationCheck {
                    guard !isCancelled() else { return nil }
                    nextIndentCancellationCheck =
                        cursor + cancellationCharacterStride
                }
                let character = source.character(at: cursor)
                if character == YAMLASCII.space {
                    column += 1
                    cursor += 1
                } else if character == YAMLASCII.tab {
                    // Tabs are invalid YAML indentation, but treating them
                    // deterministically keeps incomplete buffers safe.
                    column += tabWidth - (column % tabWidth)
                    cursor += 1
                } else {
                    break
                }
            }

            let isBlank = cursor == bound.end
            lines.append(Line(
                start: bound.start,
                contentEnd: bound.end,
                fullEnd: boundIndex + 1 < bounds.count
                    ? bounds[boundIndex + 1].start
                    : source.length,
                indentEnd: cursor,
                indentationColumn: column,
                rawIsBlank: isBlank,
                kind: isBlank ? .blank : .code
            ))
        }
        return lines
    }

    // MARK: - Lexical and structural scan

    private static func parseStructure(
        in source: NSString,
        lines: inout [Line],
        lexicalRanges: inout [NSRange],
        isCancelled: CancellationCheck
    ) -> Bool {
        var lexicalState = LexicalState()
        var plainScalarIndentation: Int?
        var scalarContent = Array(
            repeating: false,
            count: lines.count
        )

        for lineIndex in lines.indices {
            if lineIndex.isMultiple(
                of: cancellationLineStride
            ), isCancelled() {
                return false
            }
            if scalarContent[lineIndex] {
                lines[lineIndex].kind = .continuation
                appendWholeLineRange(
                    lines[lineIndex],
                    to: &lexicalRanges
                )
                continue
            }

            let line = lines[lineIndex]
            if plainScalarIndentation != nil,
               line.rawIsBlank {
                lines[lineIndex].kind = .blank
                appendWholeLineRange(
                    lines[lineIndex],
                    to: &lexicalRanges
                )
                continue
            }
            if let scalarIndent = plainScalarIndentation {
                if isCommentOnlyLine(source: source, line: line)
                    || line.indentationColumn <= scalarIndent {
                    plainScalarIndentation = nil
                } else {
                    lines[lineIndex].kind = .continuation
                    appendWholeLineRange(
                        lines[lineIndex],
                        to: &lexicalRanges
                    )
                    continue
                }
            }

            if isHardDocumentBoundary(
                source: source,
                line: line
            ) {
                if let quote = lexicalState.quote {
                    appendRange(
                        from: quote.start,
                        to: line.start,
                        to: &lexicalRanges
                    )
                }
                lexicalState = LexicalState()
            }

            let startsInQuote = lexicalState.quote != nil
            let startsInFlow =
                !lexicalState.flowStack.isEmpty
            guard let parsed = scanLine(
                source: source,
                line: line,
                lexicalState: &lexicalState,
                lexicalRanges: &lexicalRanges,
                isCancelled: isCancelled
            ) else {
                return false
            }

            if startsInQuote || startsInFlow {
                plainScalarIndentation = nil
                lines[lineIndex].kind = .continuation
                continue
            }
            if line.rawIsBlank {
                lines[lineIndex].kind = .blank
                continue
            }
            guard parsed.hasCode else {
                lines[lineIndex].kind = .comment
                continue
            }

            lines[lineIndex].kind = .code
            lines[lineIndex].isSequenceEntry =
                parsed.sequenceMarker != nil
            lines[lineIndex].headers = headerCandidates(
                source: source,
                line: lines[lineIndex],
                lineIndex: lineIndex,
                parsed: parsed
            )

            if let blockScalar = parsed.blockScalar {
                guard markBlockScalarContent(
                    BlockScalarContext(
                        headerIndex: lineIndex,
                        scalarIndent:
                            blockScalarIndentationColumn(
                                source: source,
                                line: lines[lineIndex],
                                mappingColon:
                                    parsed.mappingColon,
                                markerOffset:
                                    blockScalar.markerOffset
                            ),
                        explicitIndent:
                            blockScalar.explicitIndent,
                        lines: lines
                    ),
                    marked: &scalarContent,
                    isCancelled: isCancelled
                ) else {
                    return false
                }
            }

            plainScalarIndentation =
                parsed.hasTrailingPlainScalar
                    ? nodeIndentationColumn(
                        source: source,
                        line: lines[lineIndex],
                        mappingColon: parsed.mappingColon,
                        sequenceMarker:
                            parsed.sequenceMarker
                    )
                    : nil
        }

        if let quote = lexicalState.quote {
            appendRange(
                from: quote.start,
                to: source.length,
                to: &lexicalRanges
            )
        }
        return !isCancelled()
    }

    private static func scanLine(
        source: NSString,
        line: Line,
        lexicalState: inout LexicalState,
        lexicalRanges: inout [NSRange],
        isCancelled: CancellationCheck
    ) -> ParsedLine? {
        var cursor = line.indentEnd
        var nextCancellationCheck =
            cursor + cancellationCharacterStride
        var commentStart: Int?
        var mappingColon: Int?
        var hasCode = false
        var plainScalarActive = false
        let startedInsideQuote = lexicalState.quote != nil
        let startedInsideFlow =
            !lexicalState.flowStack.isEmpty
        var nodeMayStart = startedInsideFlow
            ? lexicalState.nodeMayStart
            : true

        let sequenceMarker: Int? =
            !startedInsideQuote
                && !startedInsideFlow
                && isBlockIndicator(
                    YAMLASCII.hyphen,
                    at: line.indentEnd,
                    source: source,
                    lineEnd: line.contentEnd
                )
            ? line.indentEnd
            : nil
        let explicitKeyMarker: Int? =
            !startedInsideQuote
                && !startedInsideFlow
                && isBlockIndicator(
                    YAMLASCII.questionMark,
                    at: line.indentEnd,
                    source: source,
                    lineEnd: line.contentEnd
                )
            ? line.indentEnd
            : nil

        while cursor < line.contentEnd {
            if cursor >= nextCancellationCheck {
                guard !isCancelled() else { return nil }
                nextCancellationCheck =
                    cursor + cancellationCharacterStride
            }
            if let activeQuote = lexicalState.quote {
                let character = source.character(at: cursor)
                if activeQuote.character == YAMLASCII.doubleQuote,
                   character == YAMLASCII.backslash {
                    cursor = min(line.contentEnd, cursor + 2)
                    continue
                }
                if character == activeQuote.character {
                    if activeQuote.character == YAMLASCII.singleQuote,
                       cursor + 1 < line.contentEnd,
                       source.character(at: cursor + 1)
                        == YAMLASCII.singleQuote {
                        cursor += 2
                        continue
                    }
                    cursor += 1
                    appendRange(
                        from: activeQuote.start,
                        to: cursor,
                        to: &lexicalRanges
                    )
                    lexicalState.quote = nil
                    nodeMayStart = false
                    continue
                }
                cursor += 1
                continue
            }

            let character = source.character(at: cursor)
            if character == YAMLASCII.numberSign,
               startsComment(
                at: cursor,
                line: line,
                source: source
               ) {
                commentStart = cursor
                appendRange(
                    from: cursor,
                    to: line.contentEnd,
                    to: &lexicalRanges
                )
                plainScalarActive = false
                break
            }

            let isFlowExplicitKey =
                !lexicalState.flowStack.isEmpty
                    && nodeMayStart
                    && character == YAMLASCII.questionMark
                    && isBlockIndicator(
                        YAMLASCII.questionMark,
                        at: cursor,
                        source: source,
                        lineEnd: line.contentEnd
                    )
            let isCompactSequenceMarker =
                lexicalState.flowStack.isEmpty
                    && nodeMayStart
                    && character == YAMLASCII.hyphen
                    && isBlockIndicator(
                        YAMLASCII.hyphen,
                        at: cursor,
                        source: source,
                        lineEnd: line.contentEnd
                    )
            if cursor == sequenceMarker
                || cursor == explicitKeyMarker
                || isFlowExplicitKey
                || isCompactSequenceMarker {
                hasCode = true
                plainScalarActive = false
                nodeMayStart = true
                cursor += 1
                continue
            }

            if nodeMayStart,
               isNodePropertyIndicator(character) {
                hasCode = true
                plainScalarActive = false
                cursor = nodePropertyEnd(
                    at: cursor,
                    source: source,
                    lineEnd: line.contentEnd,
                    inFlow:
                        !lexicalState.flowStack.isEmpty
                )
                continue
            }

            if nodeMayStart,
               isQuoteIndicator(character) {
                plainScalarActive = false
                lexicalState.quote = QuoteState(
                    character: character,
                    start: cursor
                )
                hasCode = true
                cursor += 1
                continue
            }

            if !isHorizontalWhitespace(character) {
                hasCode = true
            }

            if isFlowOpener(character),
               nodeMayStart {
                plainScalarActive = false
                if lexicalState.flowStack.count
                    < maxActiveDepth {
                    lexicalState.flowStack.append(character)
                }
                nodeMayStart = true
            } else if let opener = matchingFlowOpener(
                for: character
            ), !lexicalState.flowStack.isEmpty {
                if lexicalState.flowStack.last == opener {
                    lexicalState.flowStack.removeLast()
                }
                plainScalarActive = false
                nodeMayStart = false
            } else if character == YAMLASCII.comma,
                      !lexicalState.flowStack.isEmpty {
                plainScalarActive = false
                nodeMayStart = true
            } else if character == YAMLASCII.colon,
                      lexicalState.flowStack.isEmpty,
                      mappingColon == nil,
                      isMappingColon(
                        at: cursor,
                        source: source,
                        lineEnd: line.contentEnd
                      ) {
                mappingColon = cursor
                plainScalarActive = false
                nodeMayStart = true
            } else if character == YAMLASCII.colon,
                      !lexicalState.flowStack.isEmpty {
                plainScalarActive = false
                nodeMayStart = true
            } else if !isHorizontalWhitespace(character) {
                if nodeMayStart {
                    plainScalarActive =
                        canStartPlainScalar(character)
                }
                nodeMayStart = false
            }
            cursor += 1
        }

        lexicalState.nodeMayStart =
            lexicalState.flowStack.isEmpty
                ? true
                : nodeMayStart
        let codeEnd = commentStart ?? line.contentEnd
        let scalar = blockScalarHeader(
            source: source,
            line: line,
            codeEnd: codeEnd,
            mappingColon: mappingColon,
            sequenceMarker: sequenceMarker
        )
        return ParsedLine(
            commentStart: commentStart,
            mappingColon: mappingColon,
            sequenceMarker: sequenceMarker,
            explicitKeyMarker: explicitKeyMarker,
            blockScalar: scalar,
            hasCode: hasCode,
            hasTrailingPlainScalar:
                plainScalarActive
                    && scalar == nil
                    && lexicalState.quote == nil
                    && lexicalState.flowStack.isEmpty
        )
    }

    private static func headerCandidates(
        source: NSString,
        line: Line,
        lineIndex: Int,
        parsed: ParsedLine
    ) -> [HeaderCandidate] {
        let codeEnd = parsed.commentStart ?? line.contentEnd
        guard !isDirectiveOrDocumentMarker(
            source: source,
            line: line,
            codeEnd: codeEnd
        ) else {
            return []
        }

        var headers: [HeaderCandidate] = []
        if let sequenceMarker = parsed.sequenceMarker {
            headers.append(
                HeaderCandidate(
                    startLineIndex: lineIndex,
                    indentationColumn: line.indentationColumn,
                    markerOffset: sequenceMarker,
                    allowsIndentlessSequence: false
                )
            )
        } else if let explicitKey = parsed.explicitKeyMarker {
            headers.append(
                HeaderCandidate(
                    startLineIndex: lineIndex,
                    indentationColumn: line.indentationColumn,
                    markerOffset: explicitKey,
                    allowsIndentlessSequence: false
                )
            )
        }

        if let colon = parsed.mappingColon {
            let valueStart = colon + 1
            if parsed.blockScalar != nil
                || tailIsEmptyOrProperties(
                    source: source,
                    from: valueStart,
                    to: codeEnd
                ) {
                headers.append(
                    HeaderCandidate(
                        startLineIndex: lineIndex,
                        indentationColumn: mappingIndentationColumn(
                            source: source,
                            line: line,
                            sequenceMarker:
                                parsed.sequenceMarker
                        ),
                        markerOffset: colon,
                        allowsIndentlessSequence:
                            parsed.blockScalar == nil
                    )
                )
            }
        } else if let scalar = parsed.blockScalar,
                  parsed.sequenceMarker == nil {
            headers.append(
                HeaderCandidate(
                    startLineIndex: lineIndex,
                    indentationColumn: line.indentationColumn,
                    markerOffset: scalar.markerOffset,
                    allowsIndentlessSequence: false
                )
            )
        }

        return headers
    }

    // MARK: - Block scalar detection

    private static func blockScalarHeader(
        source: NSString,
        line: Line,
        codeEnd: Int,
        mappingColon: Int?,
        sequenceMarker: Int?
    ) -> BlockScalarHeader? {
        let valueStart: Int
        if let mappingColon {
            valueStart = mappingColon + 1
        } else if let sequenceMarker {
            valueStart = sequenceMarker + 1
        } else {
            valueStart = line.indentEnd
        }
        guard valueStart <= codeEnd else { return nil }

        let tokenRanges = horizontalTokenRanges(
            source: source,
            from: valueStart,
            to: codeEnd
        )
        guard let indicatorRange = tokenRanges.last,
              let explicitIndent = scalarIndentIndicator(
                source: source,
                range: indicatorRange
              ) else {
            return nil
        }

        var isExplicitKey = false
        for propertyRange in tokenRanges.dropLast() {
            let first = source.character(
                at: propertyRange.location
            )
            let isProperty =
                first == YAMLASCII.ampersand
                    || first == YAMLASCII.exclamationMark
            let isCompactSequenceMarker =
                mappingColon == nil
                    && propertyRange.length == 1
                    && first == YAMLASCII.hyphen
            let isExplicitKeyMarker =
                mappingColon == nil
                    && propertyRange.length == 1
                    && first == YAMLASCII.questionMark
                    && !isExplicitKey
            guard isProperty
                    || isCompactSequenceMarker
                    || isExplicitKeyMarker else {
                return nil
            }
            isExplicitKey = isExplicitKey
                || isExplicitKeyMarker
        }

        return BlockScalarHeader(
            markerOffset: indicatorRange.location,
            explicitIndent: explicitIndent
        )
    }

    /// `nil` means "not an indicator"; `.some(nil)` represents an implicit
    /// indentation indicator (`|`, `>-`, and similar).
    private static func scalarIndentIndicator(
        source: NSString,
        range: NSRange
    ) -> Int?? {
        guard range.length >= 1,
              range.length <= 3 else {
            return nil
        }
        let first = source.character(at: range.location)
        guard first == YAMLASCII.verticalBar
                || first == YAMLASCII.greaterThan else {
            return nil
        }

        var digit: Int?
        var sawChomping = false
        if range.length > 1 {
            for offset in 1..<range.length {
                let character = source.character(
                    at: range.location + offset
                )
                if character >= YAMLASCII.one
                    && character <= YAMLASCII.nine {
                    guard digit == nil else { return nil }
                    digit = Int(character - YAMLASCII.zero)
                } else if character == YAMLASCII.plus
                            || character == YAMLASCII.hyphen {
                    guard !sawChomping else { return nil }
                    sawChomping = true
                } else {
                    return nil
                }
            }
        }
        return .some(digit)
    }

    private static func markBlockScalarContent(
        _ context: BlockScalarContext,
        marked: inout [Bool],
        isCancelled: CancellationCheck
    ) -> Bool {
        let headerIndex = context.headerIndex
        let lines = context.lines
        guard headerIndex + 1 < lines.count else { return true }

        let contentIndent: Int
        if let explicit = context.explicitIndent {
            contentIndent = context.scalarIndent + explicit
        } else {
            var firstContentIndex = headerIndex + 1
            while firstContentIndex < lines.count,
                  lines[firstContentIndex].rawIsBlank {
                if firstContentIndex.isMultiple(
                    of: cancellationLineStride
                ), isCancelled() {
                    return false
                }
                firstContentIndex += 1
            }
            guard firstContentIndex < lines.count,
                  lines[firstContentIndex].indentationColumn
                    > context.scalarIndent else {
                return true
            }
            contentIndent =
                lines[firstContentIndex].indentationColumn
        }

        var index = headerIndex + 1
        while index < lines.count {
            if index.isMultiple(
                of: cancellationLineStride
            ), isCancelled() {
                return false
            }
            let line = lines[index]
            if line.rawIsBlank {
                marked[index] = true
            } else if line.indentationColumn >= contentIndent {
                marked[index] = true
            } else {
                break
            }
            index += 1
        }
        return true
    }

    // MARK: - Range resolution

    /// The editor exposes one disclosure control per physical line. Keep the
    /// outermost useful range for that line so gutter clicks, Fold Code, and
    /// Fold All all address the same region.
    static func canonicalizedForDisplay(
        _ ranges: [FoldableRange]
    ) -> [FoldableRange] {
        let sorted = ranges.sorted(by: foldOrder)
        var canonical: [FoldableRange] = []
        canonical.reserveCapacity(sorted.count)

        for range in sorted {
            guard let current = canonical.last,
                  current.startLine == range.startLine else {
                canonical.append(range)
                continue
            }
            if isPreferredDisplayRange(
                range,
                over: current
            ) {
                canonical[canonical.count - 1] = range
            }
        }
        return canonical
    }

    private static func isPreferredDisplayRange(
        _ candidate: FoldableRange,
        over current: FoldableRange
    ) -> Bool {
        if candidate.endLine != current.endLine {
            return candidate.endLine > current.endLine
        }
        if candidate.kind != current.kind {
            return candidate.kind == .indentation
        }
        if candidate.startCharIndex != current.startCharIndex {
            return candidate.startCharIndex
                < current.startCharIndex
        }
        return candidate.endCharIndex > current.endCharIndex
    }

    private static func resolveRanges(
        lines: [Line],
        isCancelled: CancellationCheck
    ) -> [FoldableRange]? {
        var awaitingBody: [HeaderCandidate] = []
        var active: [ActiveBlock] = []
        var ranges: [FoldableRange] = []

        for (lineIndex, line) in lines.enumerated() {
            if lineIndex.isMultiple(
                of: cancellationLineStride
            ), isCancelled() {
                return nil
            }
            switch line.kind {
            case .blank:
                break
            case .comment:
                for index in active.indices
                where commentBelongs(
                    line,
                    to: active[index].header
                ) {
                    active[index].lastIncludedLineIndex =
                        lineIndex
                }
            case .continuation:
                if !line.rawIsBlank {
                    activate(
                        awaitingBody,
                        with: line,
                        at: lineIndex,
                        active: &active
                    )
                    awaitingBody.removeAll(
                        keepingCapacity: true
                    )
                }
                for index in active.indices {
                    active[index].lastIncludedLineIndex =
                        lineIndex
                }
            case .code:
                var remaining: [ActiveBlock] = []
                remaining.reserveCapacity(active.count)
                for var block in active {
                    if lineBelongs(
                        line,
                        to: block.header
                    ) {
                        block.lastIncludedLineIndex =
                            lineIndex
                        remaining.append(block)
                    } else {
                        appendRange(
                            for: block,
                            lines: lines,
                            to: &ranges
                        )
                    }
                }
                active = remaining

                activate(
                    awaitingBody,
                    with: line,
                    at: lineIndex,
                    active: &active
                )
                awaitingBody.removeAll(keepingCapacity: true)
            }

            if !line.headers.isEmpty {
                awaitingBody.append(
                    contentsOf: line.headers
                )
            }
        }

        for block in active {
            appendRange(
                for: block,
                lines: lines,
                to: &ranges
            )
        }
        ranges.sort(by: foldOrder)
        guard !isCancelled() else { return nil }
        return ranges.enumerated().compactMap { index, range in
            index == 0 || range != ranges[index - 1]
                ? range
                : nil
        }
    }

    private static func activate(
        _ headers: [HeaderCandidate],
        with line: Line,
        at lineIndex: Int,
        active: inout [ActiveBlock]
    ) {
        for header in headers
        where lineBelongs(line, to: header)
            && active.count < maxActiveDepth {
            active.append(
                ActiveBlock(
                    header: header,
                    lastIncludedLineIndex: lineIndex
                )
            )
        }
    }

    private static func lineBelongs(
        _ line: Line,
        to header: HeaderCandidate
    ) -> Bool {
        if line.indentationColumn > header.indentationColumn {
            return true
        }
        return header.allowsIndentlessSequence
            && line.indentationColumn == header.indentationColumn
            && line.isSequenceEntry
    }

    private static func commentBelongs(
        _ line: Line,
        to header: HeaderCandidate
    ) -> Bool {
        line.indentationColumn > header.indentationColumn
    }

    private static func appendRange(
        for block: ActiveBlock,
        lines: [Line],
        to ranges: inout [FoldableRange]
    ) {
        let startLine = block.header.startLineIndex + 1
        let endLine = block.lastIncludedLineIndex + 1
        guard endLine > startLine else { return }

        ranges.append(
            FoldableRange(
                startLine: startLine,
                endLine: endLine,
                startCharIndex: block.header.markerOffset,
                endCharIndex:
                    lines[block.lastIncludedLineIndex].contentEnd,
                kind: .indentation
            )
        )
    }

    private static func foldOrder(
        _ lhs: FoldableRange,
        _ rhs: FoldableRange
    ) -> Bool {
        if lhs.startLine != rhs.startLine {
            return lhs.startLine < rhs.startLine
        }
        if lhs.endLine != rhs.endLine {
            return lhs.endLine < rhs.endLine
        }
        if lhs.startCharIndex != rhs.startCharIndex {
            return lhs.startCharIndex < rhs.startCharIndex
        }
        return lhs.endCharIndex < rhs.endCharIndex
    }

    // MARK: - Token helpers

    private static func isHardDocumentBoundary(
        source: NSString,
        line: Line
    ) -> Bool {
        guard line.indentationColumn == 0 else { return false }
        return hasDocumentMarker(
            source: source,
            from: line.indentEnd,
            to: line.contentEnd
        )
    }

    private static func isDirectiveOrDocumentMarker(
        source: NSString,
        line: Line,
        codeEnd: Int
    ) -> Bool {
        guard line.indentEnd < codeEnd else { return false }
        if source.character(at: line.indentEnd)
            == YAMLASCII.percent {
            return true
        }
        return hasDocumentMarker(
            source: source,
            from: line.indentEnd,
            to: codeEnd
        )
    }

    private static func hasDocumentMarker(
        source: NSString,
        from start: Int,
        to end: Int
    ) -> Bool {
        guard start + 3 <= end else { return false }
        let marker = source.substring(
            with: NSRange(location: start, length: 3)
        )
        guard marker == "---" || marker == "..." else {
            return false
        }
        return start + 3 == end
            || isHorizontalWhitespace(
                source.character(at: start + 3)
            )
    }

    private static func isBlockIndicator(
        _ indicator: unichar,
        at location: Int,
        source: NSString,
        lineEnd: Int
    ) -> Bool {
        guard location < lineEnd,
              source.character(at: location) == indicator else {
            return false
        }
        return location + 1 == lineEnd
            || isHorizontalWhitespace(
                source.character(at: location + 1)
            )
    }

    private static func isMappingColon(
        at location: Int,
        source: NSString,
        lineEnd: Int
    ) -> Bool {
        location + 1 == lineEnd
            || isHorizontalWhitespace(
                source.character(at: location + 1)
            )
    }

    private static func startsComment(
        at location: Int,
        line: Line,
        source: NSString
    ) -> Bool {
        location == line.indentEnd
            || (location > line.start
                && isHorizontalWhitespace(
                    source.character(at: location - 1)
                ))
    }

    private static func isCommentOnlyLine(
        source: NSString,
        line: Line
    ) -> Bool {
        line.indentEnd < line.contentEnd
            && source.character(at: line.indentEnd)
                == YAMLASCII.numberSign
    }

    private static func isNodePropertyIndicator(
        _ character: unichar
    ) -> Bool {
        character == YAMLASCII.ampersand
            || character == YAMLASCII.exclamationMark
    }

    private static func isQuoteIndicator(
        _ character: unichar
    ) -> Bool {
        character == YAMLASCII.singleQuote
            || character == YAMLASCII.doubleQuote
    }

    private static func canStartPlainScalar(
        _ character: unichar
    ) -> Bool {
        character != YAMLASCII.asterisk
            && character != YAMLASCII.verticalBar
            && character != YAMLASCII.greaterThan
    }

    private static func nodePropertyEnd(
        at location: Int,
        source: NSString,
        lineEnd: Int,
        inFlow: Bool
    ) -> Int {
        var cursor = location + 1

        // A verbatim tag URI may contain characters that otherwise delimit
        // flow tokens, so consume it through its closing angle bracket.
        if source.character(at: location)
                == YAMLASCII.exclamationMark,
           cursor < lineEnd,
           source.character(at: cursor)
                == YAMLASCII.lessThan {
            cursor += 1
            while cursor < lineEnd {
                let character = source.character(at: cursor)
                cursor += 1
                if character == YAMLASCII.greaterThan {
                    break
                }
            }
            return cursor
        }

        while cursor < lineEnd {
            let character = source.character(at: cursor)
            if isHorizontalWhitespace(character)
                || (inFlow
                    && isFlowTokenDelimiter(character)) {
                break
            }
            cursor += 1
        }
        return cursor
    }

    private static func isFlowOpener(
        _ character: unichar
    ) -> Bool {
        character == YAMLASCII.openBracket
            || character == YAMLASCII.openBrace
    }

    private static func isFlowTokenDelimiter(
        _ character: unichar
    ) -> Bool {
        character == YAMLASCII.comma
            || character == YAMLASCII.openBracket
            || character == YAMLASCII.closeBracket
            || character == YAMLASCII.openBrace
            || character == YAMLASCII.closeBrace
    }

    private static func matchingFlowOpener(
        for character: unichar
    ) -> unichar? {
        switch character {
        case YAMLASCII.closeBracket:
            YAMLASCII.openBracket
        case YAMLASCII.closeBrace:
            YAMLASCII.openBrace
        default:
            nil
        }
    }

    private static func tailIsEmptyOrProperties(
        source: NSString,
        from start: Int,
        to end: Int
    ) -> Bool {
        let tokens = horizontalTokenRanges(
            source: source,
            from: start,
            to: end
        )
        return tokens.allSatisfy { range in
            let first = source.character(at: range.location)
            return first == YAMLASCII.ampersand
                || first == YAMLASCII.exclamationMark
        }
    }

    private static func horizontalTokenRanges(
        source: NSString,
        from start: Int,
        to end: Int
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            while cursor < end,
                  isHorizontalWhitespace(
                    source.character(at: cursor)
                  ) {
                cursor += 1
            }
            guard cursor < end else { break }
            let tokenStart = cursor
            while cursor < end,
                  !isHorizontalWhitespace(
                    source.character(at: cursor)
                  ) {
                cursor += 1
            }
            ranges.append(
                NSRange(
                    location: tokenStart,
                    length: cursor - tokenStart
                )
            )
        }
        return ranges
    }

    private static func nodeIndentationColumn(
        source: NSString,
        line: Line,
        mappingColon: Int?,
        sequenceMarker: Int?
    ) -> Int {
        guard let sequenceMarker else {
            return line.indentationColumn
        }

        let columns = sequenceIndentationColumns(
            source: source,
            line: line,
            firstMarker: sequenceMarker
        )
        return mappingColon == nil
            ? columns.innermostMarker
            : columns.node
    }

    /// Resolves a block scalar's indentation relative to every compact block
    /// indicator that precedes it. Unlike ordinary sequence parsing, an
    /// explicit mapping key may introduce a nested sequence on the same line
    /// (`- ? - |2`), so the first physical `-` is not sufficient.
    private static func blockScalarIndentationColumn(
        source: NSString,
        line: Line,
        mappingColon: Int?,
        markerOffset: Int
    ) -> Int {
        let columns = blockPrefixIndentationColumns(
            source: source,
            line: line,
            before: mappingColon ?? markerOffset
        )
        return mappingColon == nil
            ? columns.innermostMarker
            : columns.node
    }

    private static func blockPrefixIndentationColumns(
        source: NSString,
        line: Line,
        before end: Int
    ) -> (node: Int, innermostMarker: Int) {
        var cursor = line.indentEnd
        var column = line.indentationColumn
        var innermostMarker = column

        while cursor < end {
            let character = source.character(at: cursor)
            guard character == YAMLASCII.hyphen
                    || character == YAMLASCII.questionMark,
                  isBlockIndicator(
                    character,
                    at: cursor,
                    source: source,
                    lineEnd: end
                  ) else {
                break
            }

            innermostMarker = column
            cursor += 1
            column += 1
            while cursor < end {
                let whitespace = source.character(at: cursor)
                guard isHorizontalWhitespace(whitespace) else {
                    break
                }
                if whitespace == YAMLASCII.space {
                    column += 1
                } else {
                    column += tabWidth - (column % tabWidth)
                }
                cursor += 1
            }
        }
        return (column, innermostMarker)
    }

    private static func mappingIndentationColumn(
        source: NSString,
        line: Line,
        sequenceMarker: Int?
    ) -> Int {
        guard let sequenceMarker else {
            return line.indentationColumn
        }
        return sequenceIndentationColumns(
            source: source,
            line: line,
            firstMarker: sequenceMarker
        ).node
    }

    private static func sequenceIndentationColumns(
        source: NSString,
        line: Line,
        firstMarker: Int
    ) -> (node: Int, innermostMarker: Int) {
        var cursor = firstMarker
        var column = line.indentationColumn
        var innermostMarker = column

        while cursor < line.contentEnd,
              isBlockIndicator(
                YAMLASCII.hyphen,
                at: cursor,
                source: source,
                lineEnd: line.contentEnd
              ) {
            innermostMarker = column
            cursor += 1
            column += 1
            while cursor < line.contentEnd {
                let character = source.character(at: cursor)
                guard isHorizontalWhitespace(character) else {
                    break
                }
                if character == YAMLASCII.space {
                    column += 1
                } else {
                    column += tabWidth - (column % tabWidth)
                }
                cursor += 1
            }
        }
        return (column, innermostMarker)
    }

    private static func isHorizontalWhitespace(
        _ character: unichar
    ) -> Bool {
        character == YAMLASCII.space
            || character == YAMLASCII.tab
    }

    // MARK: - Lexical ranges

    private static func appendWholeLineRange(
        _ line: Line,
        to ranges: inout [NSRange]
    ) {
        appendRange(
            from: line.start,
            to: line.fullEnd,
            to: &ranges
        )
    }

    private static func appendRange(
        from start: Int,
        to end: Int,
        to ranges: inout [NSRange]
    ) {
        guard end > start else { return }
        guard let last = ranges.last,
              start <= NSMaxRange(last) else {
            ranges.append(
                NSRange(location: start, length: end - start)
            )
            return
        }
        let mergedStart = min(last.location, start)
        let mergedEnd = max(NSMaxRange(last), end)
        ranges[ranges.count - 1] = NSRange(
            location: mergedStart,
            length: mergedEnd - mergedStart
        )
    }

    private static func normalizedRanges(
        _ ranges: [NSRange],
        boundedBy length: Int
    ) -> [NSRange] {
        let valid = ranges.compactMap { range -> NSRange? in
            guard range.location >= 0,
                  range.length > 0,
                  range.location < length else {
                return nil
            }
            return NSRange(
                location: range.location,
                length: min(
                    range.length,
                    length - range.location
                )
            )
        }
        .sorted {
            if $0.location != $1.location {
                return $0.location < $1.location
            }
            return $0.length < $1.length
        }

        var merged: [NSRange] = []
        for range in valid {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length:
                        max(
                            NSMaxRange(last),
                            NSMaxRange(range)
                        ) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

nonisolated private enum YAMLASCII {
    static let tab: unichar = 0x09
    static let space: unichar = 0x20
    static let exclamationMark: unichar = 0x21
    static let doubleQuote: unichar = 0x22
    static let numberSign: unichar = 0x23
    static let percent: unichar = 0x25
    static let ampersand: unichar = 0x26
    static let singleQuote: unichar = 0x27
    static let asterisk: unichar = 0x2A
    static let plus: unichar = 0x2B
    static let comma: unichar = 0x2C
    static let hyphen: unichar = 0x2D
    static let zero: unichar = 0x30
    static let one: unichar = 0x31
    static let nine: unichar = 0x39
    static let colon: unichar = 0x3A
    static let lessThan: unichar = 0x3C
    static let greaterThan: unichar = 0x3E
    static let questionMark: unichar = 0x3F
    static let openBracket: unichar = 0x5B
    static let backslash: unichar = 0x5C
    static let closeBracket: unichar = 0x5D
    static let openBrace: unichar = 0x7B
    static let verticalBar: unichar = 0x7C
    static let closeBrace: unichar = 0x7D
}
