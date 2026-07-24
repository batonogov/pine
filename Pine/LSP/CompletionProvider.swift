//
//  CompletionProvider.swift
//  Pine
//
//  Phase 3 of LSP support (issue #1012, parent #994).
//
//  Value types for `textDocument/completion`:
//    • `LSPCompletionItem` — a single completion suggestion (label, insert
//      text, kind, detail, documentation, deprecated flag, sort text).
//    • `LSPCompletionList` — the server response (an array of items plus the
//      `isIncomplete` flag).
//    • `LSPCompletionItemKind` — the 25 LSP kinds mapped to SF Symbol icons.
//    • `LSPInsertTextFormat` — plain vs. snippet.
//    • `LSPSnippet` — a parser/expander for LSP snippet syntax (tab stops,
//      placeholders, choices) that produces plain text + ordered tab stops.
//
//  Plus a pure prefix-filter + ranker that narrows the server list to the
//  items matching the word being typed, scored by prefix/substring/camelCase
//  heuristics.
//
//  All types are `nonisolated` + `Sendable` so they can cross the background
//  JSON-RPC queue → main-actor boundary without Swift 6 strict-concurrency
//  errors. This mirrors the Phase 1/2 value types (`LSPPosition`, `LSPRange`,
//  `LSPDiagnostic`, `LSPHover`, `LSPDefinitionResponse`) in
//  `DiagnosticsProvider.swift` and `HoverAndDefinitionProvider.swift`.
//

import Foundation

// MARK: - Insert text format

/// The LSP `InsertTextFormat` enum (1 = plain, 2 = snippet).
nonisolated enum LSPInsertTextFormat: Int, Sendable, Equatable {
    /// The primary text to insert is plain text.
    case plain = 1
    /// The primary text to insert is a snippet in LSP snippet syntax.
    case snippet = 2

    /// Initialises from the raw JSON number value. Falls back to `.plain`
    /// when the value is absent (the spec default).
    init(raw: Any?) {
        guard let value = raw as? Int,
              let format = LSPInsertTextFormat(rawValue: value) else {
            self = .plain
            return
        }
        self = format
    }
}

// MARK: - Completion item kind

/// The LSP `CompletionItemKind` enum (1-based per spec), mapped to an SF
/// Symbol name for the popup icon.
///
/// `nonisolated` because this is pure data with no actor surface. Without
/// `nonisolated`, the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// would make the enum implicitly `@MainActor` and the value-type decoder
/// (`LSPCompletionItem.init(json:)`) would not compile when called from a
/// background JSON-RPC callback.
nonisolated enum LSPCompletionItemKind: Int, Sendable, Equatable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case operatorKind = 24
    case typeParameter = 25

    /// Initialises from the raw JSON number value. Returns `nil` when the
    /// value is absent or out of range — servers may omit `kind`.
    init?(raw: Any?) {
        guard let value = raw as? Int,
              let kind = LSPCompletionItemKind(rawValue: value) else { return nil }
        self = kind
    }

    /// An SF Symbol name for this kind, used by the popup. Reuses the icon
    /// vocabulary from the file tree / Problems panel for visual consistency.
    var symbolName: String {
        switch self {
        case .text:           return "textformat"
        case .method:         return "function"
        case .function:       return "function"
        case .constructor:    return "wrench.and.screwdriver"
        case .field:          return "square.dashed"
        case .variable:       return "v.square"
        case .class:          return "c.square"
        case .interface:      return "i.square"
        case .module:         return "shippingbox"
        case .property:       return "p.square"
        case .unit:           return "ruler"
        case .value:          return "equal.square"
        case .enum:           return "e.square"
        case .keyword:        return "k.square"
        case .snippet:        return "scissors"
        case .color:          return "paintpalette"
        case .file:           return "doc"
        case .reference:      return "arrow.right.square"
        case .folder:         return "folder"
        case .enumMember:     return "list.bullet"
        case .constant:       return "c.square"
        case .struct:         return "s.square"
        case .event:          return "bell"
        case .operatorKind:   return "plus.forwardslash.minus"
        case .typeParameter:  return "t.square"
        }
    }
}

// MARK: - Completion item

/// A single `CompletionItem` from `textDocument/completion`.
///
/// Pine stores the fields needed to render the popup and to insert the chosen
/// item. Fields the server may attach but Pine does not yet use (tags,
/// preselect, commitCharacters, filterText, `textEdit`, additionalTextEdits,
/// data) are decoded defensively but not surfaced on the value type — the
/// insertion strategy in Phase 3 replaces the current word with
/// `insertText`, which is the common-case fallback the spec recommends.
nonisolated struct LSPCompletionItem: Equatable, Sendable, Identifiable {

    /// A stable identifier for SwiftUI `ForEach` and for diffing. Derived
    /// from `label` when the server omits a `data`/`sortText` discriminator.
    let id: String

    /// The human-readable label shown in the popup.
    let label: String

    /// The text to insert. Falls back to `label` when the server omits it,
    /// per the LSP spec.
    let insertText: String

    /// Whether `insertText` is plain text or an LSP snippet.
    let insertTextFormat: LSPInsertTextFormat

    /// The kind of completion (function, variable, etc.). `nil` when the
    /// server omits it.
    let kind: LSPCompletionItemKind?

    /// Optional detail string (e.g. a type signature) shown beside the label.
    let detail: String?

    /// Optional documentation shown in a side pane / tooltip.
    let documentation: String?

    /// When `true` the item is rendered struck-through (deprecated API).
    let deprecated: Bool

    /// Optional sort key. When present it is preferred over `label` for
    /// ranking so server-side pre-sorting is preserved.
    let sortText: String?

    /// Optional filter key. When present it is preferred over `label` when
    /// matching against the word being typed.
    let filterText: String?

    /// Initialises from the raw JSON dictionary of a `CompletionItem`.
    /// Returns `nil` only when `label` is missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let label = dict["label"] as? String, !label.isEmpty else { return nil }

        self.label = label
        self.insertText = (dict["insertText"] as? String) ?? label
        self.insertTextFormat = LSPInsertTextFormat(raw: dict["insertTextFormat"])
        self.kind = LSPCompletionItemKind(raw: dict["kind"])
        self.detail = dict["detail"] as? String
        self.documentation = LSPCompletionItem.extractDocumentation(dict["documentation"])
        // `deprecated` may be a boolean (newer servers) or missing (older).
        self.deprecated = (dict["deprecated"] as? Bool) ?? false
        self.sortText = dict["sortText"] as? String
        self.filterText = dict["filterText"] as? String

        // Prefer an explicit discriminator for the SwiftUI identity; fall
        // back to the label so duplicate labels remain distinct by index in
        // the parent array (handled by the `ForEach` enumerated wrapper).
        if let dataID = dict["data"] as? String {
            self.id = dataID
        } else if let sort = dict["sortText"] as? String {
            self.id = "\(sort)\u{0}\(label)"
        } else {
            self.id = label
        }
    }

    /// Test/fixture convenience constructor.
    init(
        label: String,
        insertText: String? = nil,
        insertTextFormat: LSPInsertTextFormat = .plain,
        kind: LSPCompletionItemKind? = nil,
        detail: String? = nil,
        documentation: String? = nil,
        deprecated: Bool = false,
        sortText: String? = nil,
        filterText: String? = nil,
        id: String? = nil
    ) {
        self.label = label
        self.insertText = insertText ?? label
        self.insertTextFormat = insertTextFormat
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.deprecated = deprecated
        self.sortText = sortText
        self.filterText = filterText
        self.id = id ?? sortText ?? label
    }

    /// Normalises the polymorphic `documentation` field (a string, a
    /// `MarkupContent`, or absent) into a plain string.
    private static func extractDocumentation(_ raw: Any?) -> String? {
        if let string = raw as? String, !string.isEmpty { return string }
        if let dict = raw as? [String: Any],
           let value = dict["value"] as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}

// MARK: - Completion list

/// The result of a `textDocument/completion` request.
///
/// The LSP spec allows the server to answer with either a `CompletionItem[]`
/// or a `CompletionList` object (`{ isIncomplete, items }`). This type
/// normalises both into a single value.
nonisolated struct LSPCompletionList: Equatable, Sendable {

    /// All completion items, in server order.
    let items: [LSPCompletionItem]

    /// When `true` the list is not complete and the client should re-request
    /// as the user keeps typing. Pine treats the list as complete regardless
    /// and filters client-side for simplicity.
    let isIncomplete: Bool

    /// `true` when the server returned no items.
    var isEmpty: Bool { items.isEmpty }

    /// Initialises from the raw `result` of a completion request, handling
    /// the `CompletionItem[]` and `CompletionList` shapes.
    init(result: Any?) {
        // null → empty.
        guard let result else {
            self.items = []
            self.isIncomplete = false
            return
        }

        // CompletionList object.
        if let dict = result as? [String: Any] {
            let rawItems = (dict["items"] as? [Any]) ?? []
            self.items = rawItems.compactMap { LSPCompletionItem(json: $0) }
            self.isIncomplete = (dict["isIncomplete"] as? Bool) ?? false
            return
        }

        // Bare array.
        if let array = result as? [Any] {
            self.items = array.compactMap { LSPCompletionItem(json: $0) }
            self.isIncomplete = false
            return
        }

        self.items = []
        self.isIncomplete = false
    }

    init(items: [LSPCompletionItem], isIncomplete: Bool = false) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

// MARK: - Snippet parser

/// Parses LSP snippet syntax (`insertTextFormat == Snippet`) into plain text
/// plus an ordered list of tab-stop ranges.
///
/// Supports the subset of the spec that real servers emit:
///   • `$0` — final cursor position.
///   • `$n`, `${n}` — tab stop `n` (empty placeholder).
///   • `${n:default}` — tab stop `n` with a default value.
///   • `${n|a,b,c|}` — tab stop `n` with a choice list (first choice is the
///     default). Pine inserts the first choice and does not cycle.
///   • `$$`, `$}` — literal `$`/`}` escaping.
///   • `\` escapes (`\}`, `\\`, `\$`) inside placeholders.
///
/// Tab stops are returned ordered by position so the editor can advance
/// through them on Tab. The final tab stop (`$0`) sorts last regardless of
/// where it appears; if absent a synthetic one is appended at the end.
///
/// `nonisolated` because the parser is pure data work invoked from the
/// main-actor insertion path; it holds no state.
nonisolated struct LSPSnippet: Equatable, Sendable {

    /// A single tab stop: the 1-based index (0 = final) and the range of the
    /// placeholder text within the expanded `text`.
    struct TabStop: Equatable, Sendable {
        let index: Int
        /// Range in the expanded plain-text `text` (UTF-16 / NSString offsets,
        /// matching the editor's `NSTextView` coordinate space).
        let range: Range<Int>
    }

    /// The snippet expanded to plain text (placeholders replaced by their
    /// defaults, choices by their first option, tab-stop markers removed).
    let text: String

    /// The ordered tab stops (final tab stop last). Empty when the snippet
    /// had no tab stops.
    let tabStops: [TabStop]

    /// Parses an LSP snippet string.
    init(_ snippet: String) {
        var output = [Character]()
        // Pre-allocate the result text for efficiency on large snippets.
        output.reserveCapacity(snippet.count)
        var tabStops: [TabStop] = []
        // Map of placeholder index → default text, so the final tab-stop
        // ordering pass can re-sort by index with `$0` last.
        // (Handled directly via TabStop.index below.)

        let chars = Array(snippet)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Escape: `\` consumes the next char literally.
            if c == "\\", i + 1 < chars.count {
                output.append(chars[i + 1])
                i += 2
                continue
            }

            // Tab stop / placeholder start: `$`.
            if c == "$", i + 1 < chars.count {
                let next = chars[i + 1]

                // `$$` → literal `$`.
                if next == "$" {
                    output.append("$")
                    i += 2
                    continue
                }

                // `$n` — simple tab stop with no placeholder.
                if next.wholeNumberValue != nil {
                    let start = output.count
                    // Look ahead for more digits: `$10` is tab stop 10.
                    var j = i + 1
                    var number = 0
                    while j < chars.count, let d = chars[j].wholeNumberValue {
                        number = number * 10 + d
                        j += 1
                    }
                    // No placeholder text; zero-length tab stop.
                    tabStops.append(TabStop(index: number, range: start..<start))
                    i = j
                    continue
                }

                // `${...}` — braced tab stop / placeholder / choice.
                if next == "{", i + 2 < chars.count {
                    let start = output.count
                    // Read the index number.
                    var j = i + 2
                    var number = 0
                    var hasNumber = false
                    while j < chars.count, let d = chars[j].wholeNumberValue {
                        number = number * 10 + d
                        hasNumber = true
                        j += 1
                    }
                    guard hasNumber, j < chars.count else {
                        // Malformed — emit literally and move on.
                        output.append("$")
                        output.append("{")
                        i += 2
                        continue
                    }

                    // Now at the char after the number. Possibilities:
                    //   `}`     → empty placeholder `${n}`
                    //   `:`     → `${n:default}` (read until balanced `}`)
                    //   `|`     → `${n|a,b,c|}` (choice)
                    let after = chars[j]
                    if after == "}" {
                        tabStops.append(TabStop(index: number, range: start..<start))
                        i = j + 1
                        continue
                    }

                    if after == ":" || after == "|" {
                        // Read the placeholder body until the matching `}`.
                        // For choices (`|...|}`) the body is `a,b,c` — we
                        // take the first comma-delimited segment as the
                        // default text, per the spec.
                        let isChoice = (after == "|")
                        var body = ""
                        j += 1 // consume `:` or `|`
                        var depth = 1
                        while j < chars.count && depth > 0 {
                            let b = chars[j]
                            if isChoice {
                                // Choice body ends at `|` followed by `}`.
                                if b == "|" && j + 1 < chars.count && chars[j + 1] == "}" {
                                    j += 2 // consume `|}`
                                    depth = 0
                                    break
                                }
                                // For choices, only the first segment (up to
                                // the first `,`) becomes the default text.
                                if b == "," {
                                    // Skip the rest until `|}`.
                                    while j < chars.count {
                                        if chars[j] == "|" && j + 1 < chars.count && chars[j + 1] == "}" {
                                            j += 2
                                            depth = 0
                                            break
                                        }
                                        j += 1
                                    }
                                    break
                                }
                                body.append(b)
                                j += 1
                            } else {
                                // Placeholder: read until `}`, respecting `\` escapes.
                                if b == "\\" && j + 1 < chars.count {
                                    body.append(chars[j + 1])
                                    j += 2
                                    continue
                                }
                                if b == "}" {
                                    depth = 0
                                    j += 1
                                    break
                                }
                                body.append(b)
                                j += 1
                            }
                        }
                        for ch in body { output.append(ch) }
                        let end = output.count
                        let range: Range<Int>
                        if body.isEmpty {
                            range = start..<start
                        } else {
                            range = start..<end
                        }
                        tabStops.append(TabStop(index: number, range: range))
                        i = j
                        continue
                    }

                    // Unknown shape — emit literally.
                    output.append("$")
                    output.append("{")
                    i += 2
                    continue
                }

                // `$` followed by something else → literal `$`.
                output.append("$")
                i += 1
                continue
            }

            output.append(c)
            i += 1
        }

        self.text = String(output)

        // Order tab stops: ascending by index, but `$0` (the final tab stop)
        // goes last. Drop duplicates keeping the first occurrence of each
        // index (a snippet should not repeat an index, but be defensive).
        var seen = Set<Int>()
        var ordered: [TabStop] = []
        var finalStop: TabStop?
        for stop in tabStops {
            if seen.contains(stop.index) { continue }
            seen.insert(stop.index)
            if stop.index == 0 {
                finalStop = stop
            } else {
                ordered.append(stop)
            }
        }
        ordered.sort { $0.index < $1.index }
        if let finalStop {
            ordered.append(finalStop)
        } else if !ordered.isEmpty {
            // No explicit `$0` — the cursor lands after the last tab stop.
            let end = self.text.utf16.count
            ordered.append(TabStop(index: 0, range: end..<end))
        }

        self.tabStops = ordered
    }

    /// `true` when the snippet contains at least one tab stop.
    var hasTabStops: Bool { !tabStops.isEmpty }
}

// MARK: - Prefix filter & ranker

/// Pure prefix-filter and ranker for completion items.
///
/// Given the server's (possibly large) list and the word the user is typing,
/// returns the subset that matches, sorted by relevance. Relevance is a
/// simple score: prefix match > word-boundary / camelCase match > substring
/// match > label-only fuzzy. Server sort order is the tie-breaker.
///
/// `nonisolated` because the scoring is pure data work invoked from the
/// main-actor typing path.
nonisolated enum CompletionFilter {

    /// Filters and ranks `items` by `prefix` (case-insensitive).
    /// An empty prefix returns the items in server order (server ranking is
    /// authoritative when nothing has been typed yet).
    static func filter(_ items: [LSPCompletionItem], prefix: String) -> [LSPCompletionItem] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }

        let needle = trimmed.lowercased()

        // Compute the score for each item, drop non-matches.
        var scored: [(item: LSPCompletionItem, score: Int, order: Int)] = []
        for (order, item) in items.enumerated() {
            guard let score = score(item: item, needle: needle) else { continue }
            scored.append((item, score, order))
        }

        // Sort by score (desc) then by original server order (asc) so the
        // server's own ranking is the stable tie-breaker.
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }

        return scored.map { $0.item }
    }

    /// Returns a relevance score for `item` against `needle` (already
    /// lowercased), or `nil` when the item does not match at all.
    ///
    /// Scoring bands (higher = better):
    ///   • 10 000 — the item's filterText/label equals the needle exactly.
    ///   • 5 000  — the item's filterText/label starts with the needle.
    ///   • 2 000  — the needle appears at a camelCase / word boundary.
    ///   • 1 000  — the needle is a substring of the filterText/label.
    ///   • 500    — the needle matches as a subsequence (fuzzy) of the label.
    private static func score(item: LSPCompletionItem, needle: String) -> Int? {
        // Prefer filterText when the server provides it, else label.
        let candidate = (item.filterText ?? item.label).lowercased()
        let label = item.label.lowercased()

        if candidate == needle || label == needle { return 10_000 }
        if candidate.hasPrefix(needle) { return 5_000 }
        if label.hasPrefix(needle) { return 5_000 }

        if let boundaryScore = wordBoundaryScore(candidate: candidate, needle: needle) {
            return boundaryScore
        }
        if let boundaryScore = wordBoundaryScore(candidate: label, needle: needle) {
            return boundaryScore
        }

        if candidate.contains(needle) { return 1_000 }
        if label.contains(needle) { return 1_000 }

        // Fuzzy subsequence fallback.
        if isSubsequence(needle, in: label) { return 500 }
        if let filt = item.filterText, isSubsequence(needle, in: filt.lowercased()) {
            return 500
        }

        return nil
    }

    /// Scores a match where the needle starts at a word boundary (underscore,
    /// camelCase hump, or start) within `candidate`. Returns `nil` when the
    /// needle is not at a boundary. A prefix match (boundary at index 0) is
    /// already handled by the caller, so this returns at most 2 000.
    private static func wordBoundaryScore(candidate: String, needle: String) -> Int? {
        guard let range = candidate.range(of: needle) else { return nil }
        let index = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        if index == 0 { return nil } // prefix already scored higher upstream
        let before = candidate[candidate.index(candidate.startIndex, offsetBy: index - 1)]
        if before == "_" || before == "-" || before == "." || before == "/" {
            return 2_000
        }
        // camelCase boundary: a lowercase letter followed by an uppercase one.
        // We only have lowercased text, so approximate: previous char is a
        // letter and the boundary char's original-case counterpart was upper.
        if before.isLetter {
            // Re-derive from the non-lowercased label is not possible here; we
            // accept underscore/dash/dot boundaries as the reliable signal.
            return nil
        }
        return nil
    }

    /// `true` when `needle` is a subsequence of `haystack` (order preserved,
    /// not necessarily contiguous).
    private static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        var needleIter = needle.makeIterator()
        var current = needleIter.next()
        for char in haystack {
            if let c = current, c == char { current = needleIter.next() }
        }
        return current == nil
    }
}
