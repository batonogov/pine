//
//  PythonIndentationFoldCalculator.swift
//  Pine
//
//  Language-aware local folding for Python indentation suites (#1008).
//

import Foundation

/// A pure, UTF-16 based Python indentation-fold calculator.
///
/// Python's configured LSP server (Pyright) does not advertise
/// `textDocument/foldingRange`, so bracket pairs alone cannot preserve useful
/// offline folding for `class`, `def`, and control-flow suites. This
/// calculator supplies that local structure without adding a parser
/// dependency. It is intentionally tolerant of incomplete buffers: malformed
/// nested declarations cannot erase a valid enclosing suite.
///
/// The caller runs this work away from the main actor. All offsets are UTF-16
/// `NSString` offsets, matching `NSTextView` and `FoldableRange`.
nonisolated enum PythonIndentationFoldCalculator {
    static let tabWidth = 8
    static let maxActiveDepth = 500

    struct Analysis: Sendable {
        let ranges: [FoldableRange]
        /// Sorted, merged comment/string ranges used by both indentation and
        /// bracket scanning for the same immutable snapshot.
        let lexicalSkipRanges: [NSRange]
    }

    private enum LineKind {
        case blank
        case comment
        /// Physical line wholly continuing a string token that began on an
        /// earlier line. Its leading whitespace is string data, not Python
        /// indentation, so it cannot emit INDENT/DEDENT.
        case lexicalContinuation
        case code
    }

    private struct Line {
        let start: Int
        let contentEnd: Int
        let indentEnd: Int
        let indentationColumn: Int
        let kind: LineKind
    }

    private struct HeaderCandidate {
        let startLineIndex: Int
        let headerEndLineIndex: Int
        let indentationColumn: Int
        let colonOffset: Int
    }

    private struct HeaderScan {
        let candidate: HeaderCandidate?
        let consumedThroughLineIndex: Int
    }

    private struct ActiveBlock {
        let header: HeaderCandidate
        var lastIncludedLineIndex: Int
    }

    /// Calculates Python suite folds and returns the lexical exclusions used
    /// during the same immutable pass.
    static func analyze(
        text: String,
        additionalSkipRanges: [NSRange] = []
    ) -> Analysis {
        let source = text as NSString
        guard source.length > 0 else {
            return Analysis(ranges: [], lexicalSkipRanges: [])
        }

        let lexicalRanges = pythonLexicalSkipRanges(in: source)
        let exclusions = normalizedRanges(
            additionalSkipRanges + lexicalRanges,
            boundedBy: source.length
        )
        let lines = makeLines(
            in: source,
            exclusions: exclusions
        )
        let headers = headerCandidates(
            in: source,
            lines: lines,
            exclusions: exclusions
        )
        return Analysis(
            ranges: resolveRanges(headers: headers, lines: lines),
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
        ).ranges
    }

    // MARK: - Lines

    private static func makeLines(
        in source: NSString,
        exclusions: [NSRange]
    ) -> [Line] {
        var bounds: [(start: Int, end: Int)] = []
        var lineStart = 0
        var index = 0

        while index < source.length {
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

        return bounds.map { bound in
            var cursor = bound.start
            var column = 0
            while cursor < bound.end {
                switch source.character(at: cursor) {
                case ASCII.space:
                    column += 1
                    cursor += 1
                case ASCII.tab:
                    column += tabWidth - (column % tabWidth)
                    cursor += 1
                case ASCII.formFeed:
                    // Python ignores a leading form-feed for indentation.
                    column = 0
                    cursor += 1
                default:
                    break
                }
                if cursor < bound.end,
                   !isIndentationCharacter(
                    source.character(at: cursor)
                   ) {
                    break
                }
            }

            let kind: LineKind
            if let exclusion = excludedRange(
                containing: bound.start,
                in: exclusions
            ),
            exclusion.location < bound.start {
                kind = .lexicalContinuation
            } else if cursor == bound.end {
                kind = .blank
            } else if source.character(at: cursor) == ASCII.numberSign {
                kind = .comment
            } else {
                kind = .code
            }
            return Line(
                start: bound.start,
                contentEnd: bound.end,
                indentEnd: cursor,
                indentationColumn: column,
                kind: kind
            )
        }
    }

    private static func isIndentationCharacter(
        _ character: unichar
    ) -> Bool {
        character == ASCII.space
            || character == ASCII.tab
            || character == ASCII.formFeed
    }

    // MARK: - Header recognition

    private static let suiteKeywords: Set<String> = [
        "class",
        "def",
        "if",
        "elif",
        "else",
        "for",
        "while",
        "try",
        "except",
        "finally",
        "with",
        "match",
        "case"
    ]

    private static let asyncSuiteKeywords: Set<String> = [
        "def",
        "for",
        "with"
    ]

    private static func headerCandidates(
        in source: NSString,
        lines: [Line],
        exclusions: [NSRange]
    ) -> [HeaderCandidate] {
        var result: [HeaderCandidate] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            guard line.kind == .code,
                  let keywordEnd = suiteKeywordEnd(
                    source: source,
                    line: line,
                    exclusions: exclusions
                  ) else {
                lineIndex += 1
                continue
            }

            let scan = scanHeader(
                source: source,
                lines: lines,
                startLineIndex: lineIndex,
                keywordEnd: keywordEnd,
                exclusions: exclusions
            )
            if let candidate = scan.candidate {
                result.append(candidate)
            }
            // Continuation lines belong to this logical header and cannot
            // independently start another suite.
            lineIndex = max(
                lineIndex + 1,
                scan.consumedThroughLineIndex + 1
            )
        }
        return result
    }

    private static func suiteKeywordEnd(
        source: NSString,
        line: Line,
        exclusions: [NSRange]
    ) -> Int? {
        let start = line.indentEnd
        guard start < line.contentEnd,
              excludedRange(
                containing: start,
                in: exclusions
              ) == nil,
              let first = readASCIIWord(
                source: source,
                from: start,
                limit: line.contentEnd
              ) else {
            return nil
        }

        if suiteKeywords.contains(first.word) {
            return first.end
        }
        guard first.word == "async" else { return nil }

        var cursor = first.end
        while cursor < line.contentEnd,
              isHorizontalWhitespace(
                source.character(at: cursor)
              ) {
            cursor += 1
        }
        guard let second = readASCIIWord(
            source: source,
            from: cursor,
            limit: line.contentEnd
        ),
        asyncSuiteKeywords.contains(second.word) else {
            return nil
        }
        return second.end
    }

    private static func readASCIIWord(
        source: NSString,
        from start: Int,
        limit: Int
    ) -> (word: String, end: Int)? {
        guard start < limit,
              isASCIIIdentifierCharacter(
                source.character(at: start)
              ) else {
            return nil
        }
        var end = start
        while end < limit,
              isASCIIIdentifierCharacter(
                source.character(at: end)
              ) {
            end += 1
        }
        return (
            source.substring(
                with: NSRange(location: start, length: end - start)
            ),
            end
        )
    }

    private static func isASCIIIdentifierCharacter(
        _ character: unichar
    ) -> Bool {
        (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || (character >= 0x30 && character <= 0x39)
            || character == ASCII.underscore
    }

    private static func isHorizontalWhitespace(
        _ character: unichar
    ) -> Bool {
        character == ASCII.space
            || character == ASCII.tab
            || character == ASCII.formFeed
    }

    /// Finds the final top-level colon of one logical Python header.
    ///
    /// Tracking delimiters avoids mistaking annotation, dictionary, slice,
    /// or lambda colons for the suite terminator. A non-empty inline suite
    /// (`if ready: run()`) deliberately produces no multiline fold.
    private static func scanHeader(
        source: NSString,
        lines: [Line],
        startLineIndex: Int,
        keywordEnd: Int,
        exclusions: [NSRange]
    ) -> HeaderScan {
        var delimiterStack: [unichar] = []
        var latestTopLevelColon: Int?
        var consumedThrough = startLineIndex

        for lineIndex in startLineIndex..<lines.count {
            consumedThrough = lineIndex
            let line = lines[lineIndex]
            var cursor = lineIndex == startLineIndex
                ? keywordEnd
                : line.start
            var lastCodeOffset: Int?

            while cursor < line.contentEnd {
                if let excluded = excludedRange(
                    containing: cursor,
                    in: exclusions
                ) {
                    cursor = min(
                        line.contentEnd,
                        NSMaxRange(excluded)
                    )
                    continue
                }

                let character = source.character(at: cursor)
                if !isHorizontalWhitespace(character) {
                    lastCodeOffset = cursor
                }

                if isOpeningDelimiter(character) {
                    if delimiterStack.count < maxActiveDepth {
                        delimiterStack.append(character)
                    }
                } else if let opener = matchingOpeningDelimiter(
                    for: character
                ) {
                    if delimiterStack.last == opener {
                        delimiterStack.removeLast()
                    }
                } else if character == ASCII.colon,
                          delimiterStack.isEmpty {
                    latestTopLevelColon = cursor
                }
                cursor += 1
            }

            let explicitContinuation: Bool
            if let lastCodeOffset {
                explicitContinuation =
                    source.character(at: lastCodeOffset)
                    == ASCII.backslash
            } else {
                explicitContinuation = false
            }

            guard delimiterStack.isEmpty,
                  !explicitContinuation else {
                continue
            }

            guard let colonOffset = latestTopLevelColon else {
                return HeaderScan(
                    candidate: nil,
                    consumedThroughLineIndex: consumedThrough
                )
            }

            // The final top-level colon must end the logical line apart from
            // whitespace or a skipped comment. Otherwise this is an inline
            // suite and has no indentation body to fold.
            if hasCode(
                after: colonOffset,
                through: line.contentEnd,
                source: source,
                exclusions: exclusions
            ) {
                return HeaderScan(
                    candidate: nil,
                    consumedThroughLineIndex: consumedThrough
                )
            }

            return HeaderScan(
                candidate: HeaderCandidate(
                    startLineIndex: startLineIndex,
                    headerEndLineIndex: lineIndex,
                    indentationColumn:
                        lines[startLineIndex].indentationColumn,
                    colonOffset: colonOffset
                ),
                consumedThroughLineIndex: consumedThrough
            )
        }

        // An unterminated delimiter at EOF is malformed but bounded. The
        // enclosing valid suite remains discoverable; this logical header is
        // simply not emitted.
        return HeaderScan(
            candidate: nil,
            consumedThroughLineIndex: consumedThrough
        )
    }

    private static func hasCode(
        after offset: Int,
        through end: Int,
        source: NSString,
        exclusions: [NSRange]
    ) -> Bool {
        var cursor = offset + 1
        while cursor < end {
            if let excluded = excludedRange(
                containing: cursor,
                in: exclusions
            ) {
                cursor = min(end, NSMaxRange(excluded))
                continue
            }
            if !isHorizontalWhitespace(
                source.character(at: cursor)
            ) {
                return true
            }
            cursor += 1
        }
        return false
    }

    private static func isOpeningDelimiter(
        _ character: unichar
    ) -> Bool {
        character == ASCII.openParenthesis
            || character == ASCII.openBracket
            || character == ASCII.openBrace
    }

    private static func matchingOpeningDelimiter(
        for character: unichar
    ) -> unichar? {
        switch character {
        case ASCII.closeParenthesis:
            ASCII.openParenthesis
        case ASCII.closeBracket:
            ASCII.openBracket
        case ASCII.closeBrace:
            ASCII.openBrace
        default:
            nil
        }
    }

    // MARK: - Suite resolution

    private static func resolveRanges(
        headers: [HeaderCandidate],
        lines: [Line]
    ) -> [FoldableRange] {
        let headersByEndLine = Dictionary(
            grouping: headers,
            by: \.headerEndLineIndex
        )
        var awaitingBody: [HeaderCandidate] = []
        var active: [ActiveBlock] = []
        var ranges: [FoldableRange] = []

        for (lineIndex, line) in lines.enumerated() {
            switch line.kind {
            case .blank:
                break
            case .comment:
                for index in active.indices
                where line.indentationColumn
                    > active[index].header.indentationColumn {
                    active[index].lastIncludedLineIndex = lineIndex
                }
            case .lexicalContinuation:
                // This line belongs to the already-started logical string
                // statement regardless of its visual indentation.
                for index in active.indices {
                    active[index].lastIncludedLineIndex = lineIndex
                }
            case .code:
                var remaining: [ActiveBlock] = []
                remaining.reserveCapacity(active.count)
                for var block in active {
                    if line.indentationColumn
                        <= block.header.indentationColumn {
                        appendRange(
                            for: block,
                            lines: lines,
                            to: &ranges
                        )
                    } else {
                        block.lastIncludedLineIndex = lineIndex
                        remaining.append(block)
                    }
                }
                active = remaining

                for header in awaitingBody {
                    if line.indentationColumn
                        > header.indentationColumn,
                       active.count < maxActiveDepth {
                        active.append(
                            ActiveBlock(
                                header: header,
                                lastIncludedLineIndex: lineIndex
                            )
                        )
                    }
                }
                // A physical comment/blank/string-continuation cannot decide
                // suite ownership. The first actual code line can, and
                // resolves every pending header whether it indents or not.
                awaitingBody.removeAll(keepingCapacity: true)
            }

            if let completedHeaders = headersByEndLine[lineIndex] {
                awaitingBody.append(contentsOf: completedHeaders)
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
        return ranges
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
                startCharIndex: block.header.colonOffset,
                endCharIndex:
                    lines[block.lastIncludedLineIndex].contentEnd,
                kind: .braces
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

    // MARK: - Lexical exclusions

    /// Finds comments and Python strings, including unterminated strings at
    /// EOF. The syntax highlighter's ranges are unioned with this recovery
    /// scan so incomplete triple-quoted text cannot manufacture declarations.
    private static func pythonLexicalSkipRanges(
        in source: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = 0

        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == ASCII.numberSign {
                let start = cursor
                while cursor < source.length,
                      !isLineTerminator(
                        source.character(at: cursor)
                      ) {
                    cursor += 1
                }
                ranges.append(
                    NSRange(location: start, length: cursor - start)
                )
                continue
            }

            guard character == ASCII.singleQuote
                    || character == ASCII.doubleQuote else {
                cursor += 1
                continue
            }

            let quote = character
            let start = cursor
            let isTriple = cursor + 2 < source.length
                && source.character(at: cursor + 1) == quote
                && source.character(at: cursor + 2) == quote
            cursor += isTriple ? 3 : 1

            while cursor < source.length {
                let current = source.character(at: cursor)
                if current == ASCII.backslash {
                    if cursor + 1 < source.length,
                       source.character(at: cursor + 1)
                        == ASCII.carriageReturn,
                       cursor + 2 < source.length,
                       source.character(at: cursor + 2)
                        == ASCII.newline {
                        cursor += 3
                    } else {
                        cursor = min(source.length, cursor + 2)
                    }
                    continue
                }

                if isTriple {
                    if current == quote,
                       cursor + 2 < source.length,
                       source.character(at: cursor + 1) == quote,
                       source.character(at: cursor + 2) == quote {
                        cursor += 3
                        break
                    }
                } else if current == quote {
                    cursor += 1
                    break
                } else if isLineTerminator(current) {
                    // Recover after an unterminated single-line string.
                    break
                }
                cursor += 1
            }

            ranges.append(
                NSRange(location: start, length: cursor - start)
            )
        }
        return ranges
    }

    private static func isLineTerminator(
        _ character: unichar
    ) -> Bool {
        character == ASCII.newline
            || character == ASCII.carriageReturn
    }

    static func normalizedRanges(
        _ ranges: [NSRange],
        boundedBy length: Int
    ) -> [NSRange] {
        let valid = ranges.compactMap { range -> NSRange? in
            guard range.location >= 0,
                  range.length > 0,
                  range.location < length else {
                return nil
            }
            let boundedLength = min(
                range.length,
                length - range.location
            )
            return NSRange(
                location: range.location,
                length: boundedLength
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
                        max(NSMaxRange(last), NSMaxRange(range))
                        - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func excludedRange(
        containing location: Int,
        in ranges: [NSRange]
    ) -> NSRange? {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            let range = ranges[midpoint]
            if location < range.location {
                upper = midpoint
            } else if location >= NSMaxRange(range) {
                lower = midpoint + 1
            } else {
                return range
            }
        }
        return nil
    }
}

nonisolated private extension ASCII {
    static let tab: unichar = 0x09
    static let formFeed: unichar = 0x0C
    static let space: unichar = 0x20
    static let numberSign: unichar = 0x23
    static let singleQuote: unichar = 0x27
    static let doubleQuote: unichar = 0x22
    static let openParenthesis: unichar = 0x28
    static let closeParenthesis: unichar = 0x29
    static let colon: unichar = 0x3A
    static let openBracket: unichar = 0x5B
    static let backslash: unichar = 0x5C
    static let closeBracket: unichar = 0x5D
    static let underscore: unichar = 0x5F
    static let openBrace: unichar = 0x7B
    static let closeBrace: unichar = 0x7D
}
