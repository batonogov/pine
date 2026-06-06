//
//  SyntaxHighlightEngine.swift
//  Pine
//
//  Extracted from SyntaxHighlighter.swift — sync highlight application logic.
//

import AppKit

/// Thread-safe generation counter for cancelling stale highlight requests.
nonisolated final class HighlightGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    var current: Int {
        lock.withLock { value }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A single match found by regex computation (value type, safe to pass between threads).
nonisolated struct HighlightMatch: Sendable {
    let range: NSRange
    let scope: String
    let priority: Int
}

/// Result of background match computation.
nonisolated struct HighlightMatchResult: Sendable {
    let matches: [HighlightMatch]
    let repaintRange: NSRange
    let multilineFingerprint: [Int]
}

/// Synchronous syntax highlight engine.
/// Computes matches against compiled rules and applies colors to NSTextStorage.
///
/// Thread safety: `computeMatches`/`computeMatchesWithRules` are pure computation
/// (thread-safe). `applyMatches`/`resetAttributes` MUST be called on the main thread.
nonisolated final class SyntaxHighlightEngine: @unchecked Sendable {
    /// Number of context lines around edited region for incremental highlighting.
    let contextLines = 20

    /// Number of context lines for viewport-based highlighting.
    let viewportContextLines = 50

    /// Scope priorities: comment and string override others.
    private(set) var scopePriority: [String: Int] = [
        "comment": 100,
        "attribute": 95,
        "string": 90,
        "markdown.code.fenced": 95,
        "markdown.code.double": 94,
        "markdown.code": 92,
        "markdown.heading.1": 80,
        "markdown.heading.2": 80,
        "markdown.heading.3": 80,
        "markdown.heading.4": 80,
        "markdown.heading.5": 80,
        "markdown.heading.6": 80,
        "markdown.bold": 60,
        "markdown.italic": 55,
        "markdown.image": 52,
        "markdown.link": 50,
        "markdown.list": 40,
        "markdown.quote": 30,
        "markdown.rule": 20,
    ]

    private(set) var theme: Theme

    init(theme: Theme = .default) {
        self.theme = theme
    }

    /// Returns priority and color for a scope if it should be highlighted.
    /// Returns nil if the scope has no theme color.
    func shouldHighlight(scope: String) -> (priority: Int, color: NSColor)? {
        guard let color = theme.color(for: scope) else { return nil }
        let priority = scopePriority[scope] ?? 0
        return (priority, color)
    }

    // MARK: - Match Computation (thread-safe)

    /// Pure computation: finds regex matches without touching NSTextStorage.
    /// - Parameter fullFingerprintRange: When non-nil, collects multiline fingerprint
    ///   via a separate full-text pass instead of inline collection. Use this for
    ///   viewport highlights where `searchRange != fullRange` to ensure the fingerprint
    ///   covers the entire document (needed for structural change detection).
    func computeMatches(
        text: String,
        rules: [CompiledRule],
        grammarName: String?,
        repaintRange: NSRange,
        searchRange: NSRange,
        fullFingerprintRange: NSRange? = nil,
        nestedHighlighter: NestedHighlighter? = nil
    ) -> HighlightMatchResult {
        let source = text as NSString
        let totalLength = source.length
        let fullRange = NSRange(location: 0, length: totalLength)

        var matches: [HighlightMatch] = []
        var highlightedRanges: [
            (repaintRange: NSRange, originalRange: NSRange, priority: Int, scope: String)
        ] = []
        var multilineFingerprint: [Int] = []

        // When caller requests a full fingerprint, compute it upfront from the full text.
        if let fpRange = fullFingerprintRange {
            multilineFingerprint = GrammarCompiler.collectMultilineFingerprint(
                rules: rules, source: text, searchRange: fpRange
            )
        }

        for rule in rules {
            let priority = scopePriority[rule.scope] ?? 0
            let hasColor = theme.color(for: rule.scope) != nil

            if !hasColor && !rule.isMultiline { continue }

            // Multiline rules scan the full text; others scan only searchRange
            let scanRange = rule.isMultiline ? fullRange : searchRange

            rule.regex.enumerateMatches(in: text, range: scanRange) { match, _, _ in
                guard let matchRange = match?.range else { return }

                // Collect inline fingerprint only when no separate full pass was requested
                if rule.isMultiline && fullFingerprintRange == nil {
                    multilineFingerprint.append(matchRange.length)
                }

                guard hasColor else { return }

                let clipped = NSIntersectionRange(matchRange, repaintRange)
                guard clipped.length > 0 else { return }

                var isOverridden = false
                var lexicalRangesToReplace: [NSRange] = []
                for existing in highlightedRanges {
                    guard NSIntersectionRange(existing.repaintRange, clipped).length > 0 else {
                        continue
                    }
                    if areMutuallyExclusiveLexicalScopes(rule.scope, existing.scope) {
                        if NSLocationInRange(matchRange.location, existing.originalRange) {
                            isOverridden = true
                            break
                        }
                        lexicalRangesToReplace.append(existing.originalRange)
                        continue
                    }
                    if existing.priority > priority {
                        isOverridden = true
                        break
                    }
                }

                if !isOverridden {
                    if !lexicalRangesToReplace.isEmpty {
                        highlightedRanges.removeAll { existing in
                            areMutuallyExclusiveLexicalScopes(rule.scope, existing.scope) &&
                            lexicalRangesToReplace.contains { NSEqualRanges($0, existing.originalRange) }
                        }
                    }
                    matches.append(HighlightMatch(
                        range: clipped, scope: rule.scope, priority: priority
                    ))
                    highlightedRanges.append((
                        repaintRange: clipped,
                        originalRange: matchRange,
                        priority: priority,
                        scope: rule.scope
                    ))
                }
            }
        }

        // Post-pass: nested highlighting inside fenced code blocks for Markdown
        if grammarName == "Markdown", let nestedHighlighter {
            let nestedMatches = nestedHighlighter.computeNestedFencedMatches(
                text: text, repaintRange: repaintRange
            )
            matches.append(contentsOf: nestedMatches)
        }

        return HighlightMatchResult(
            matches: matches,
            repaintRange: repaintRange,
            multilineFingerprint: multilineFingerprint
        )
    }

    // MARK: - Match Application (main thread only)

    /// Applies pre-computed matches to NSTextStorage. MUST be called on the main thread.
    func applyMatches(
        _ result: HighlightMatchResult,
        to textStorage: NSTextStorage,
        font: NSFont
    ) {
        let currentLength = textStorage.length
        guard result.repaintRange.location + result.repaintRange.length <= currentLength else {
            return
        }

        let undoManager = textStorage.layoutManagers.first?.firstTextView?.undoManager

        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            return
        }

        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: result.repaintRange)

        for match in result.matches {
            guard match.range.location + match.range.length <= currentLength else { continue }
            guard let color = theme.color(for: match.scope) else { continue }
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }

        textStorage.endEditing()
    }

    /// Resets attributes to base style (no grammar). Main thread only.
    func resetAttributes(textStorage: NSTextStorage, range: NSRange, font: NSFont) {
        let currentLength = textStorage.length
        guard currentLength > 0 else { return }
        let safeRange = NSRange(
            location: min(range.location, currentLength),
            length: min(range.length, currentLength - min(range.location, currentLength))
        )
        guard safeRange.length > 0 else { return }

        let undoManager = textStorage.layoutManagers.first?.firstTextView?.undoManager

        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            return
        }

        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: safeRange)
        textStorage.endEditing()
    }

    // MARK: - Range helpers

    /// Expands a range to line boundaries plus N context lines.
    func expandToContext(
        _ range: NSRange,
        in source: NSString,
        totalLength: Int,
        lines: Int? = nil
    ) -> NSRange {
        let contextCount = lines ?? contextLines
        let expanded = source.lineRange(for: range)

        var linesAdded = 0
        var start = expanded.location
        while start > 0 && linesAdded < contextCount {
            start -= 1
            if source.character(at: start) == ASCII.newline { linesAdded += 1 }
        }
        if start > 0 { start += 1 }

        linesAdded = 0
        var end = NSMaxRange(expanded)
        while end < totalLength && linesAdded < contextCount {
            if source.character(at: end) == ASCII.newline { linesAdded += 1 }
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    /// Returns comment and string ranges in text (used for bracket matching).
    func commentAndStringRanges(
        in text: String,
        rules: [CompiledRule]
    ) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []

        for rule in rules where rule.scope == "comment" || rule.scope == "string" {
            rule.regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                if let range = match?.range {
                    ranges.append(range)
                }
            }
        }

        return ranges
    }

    // MARK: - Private

    private func areMutuallyExclusiveLexicalScopes(_ lhs: String, _ rhs: String) -> Bool {
        (lhs == "comment" && rhs == "string") || (lhs == "string" && rhs == "comment")
    }
}
