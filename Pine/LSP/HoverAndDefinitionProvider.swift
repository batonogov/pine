//
//  HoverAndDefinitionProvider.swift
//  Pine
//
//  Phase 2 of LSP support (issue #1011, parent #994).
//
//  Value types for the two Phase 2 features:
//    • `textDocument/hover` — type/documentation tooltip (`LSPHover`).
//    • `textDocument/definition` — go-to-definition (`LSPDefinitionResponse`,
//      `LSPLocation`, `LSPLocationLink`).
//
//  Plus an `LSPPositionConverter` that maps a UTF-16 caret offset (the unit
//  NSTextView/NSString use) to an LSP `Position` (0-based line + character),
//  handling multi-byte characters correctly. Reused by hover and definition.
//
//  All types are `nonisolated` + `Sendable` so they can cross the background
//  JSON-RPC queue → main-actor boundary without Swift 6 strict-concurrency
//  errors. This mirrors the Phase 1 value types (`LSPPosition`, `LSPRange`,
//  `LSPDiagnostic`) in `DiagnosticsProvider.swift`.
//

import Foundation

// MARK: - Hover

/// A `MarkupContent` payload returned by `textDocument/hover`.
///
/// `kind` is `"markdown"` or `"plaintext"` per the LSP spec.
nonisolated struct LSPMarkupContent: Equatable, Sendable {
    let value: String
    let isMarkdown: Bool

    /// Initialises from the raw JSON dictionary of an LSP `MarkupContent`.
    /// Returns `nil` when the `value` field is missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let value = dict["value"] as? String else { return nil }
        self.value = value
        self.isMarkdown = (dict["kind"] as? String) == "markdown"
    }

    init(value: String, isMarkdown: Bool) {
        self.value = value
        self.isMarkdown = isMarkdown
    }
}

/// The result of a `textDocument/hover` request.
///
/// Per the LSP spec the `contents` may be a `MarkupContent`, a `MarkedString`,
/// or an array of `MarkedString`. Pine normalises all forms into a single
/// `markup` value. `range` is the span the server says the hover applies to
/// (optional — used to highlight, but not required for rendering the tooltip).
nonisolated struct LSPHover: Equatable, Sendable {
    let markup: LSPMarkupContent
    let range: LSPRange?

    /// Initialises from the raw `result` of a hover request.
    /// Returns `nil` when the server returned `null` or malformed content.
    init?(result: Any?) {
        guard let dict = result as? [String: Any] else { return nil }

        // `contents` may be a MarkupContent object, a MarkedString (string or
        // {language, value}), or an array of MarkedStrings. Normalise to one
        // LSPMarkupContent.
        let contents = dict["contents"]
        guard let markup = LSPHover.normaliseContents(contents) else { return nil }
        self.markup = markup

        if let rangeJSON = dict["range"] {
            self.range = LSPRange(json: rangeJSON)
        } else {
            self.range = nil
        }
    }

    init(markup: LSPMarkupContent, range: LSPRange? = nil) {
        self.markup = markup
        self.range = range
    }

    /// Normalises the polymorphic `contents` field of a hover result into a
    /// single `LSPMarkupContent`. Returns `nil` only when every form is empty.
    private static func normaliseContents(_ contents: Any?) -> LSPMarkupContent? {
        // 1. MarkupContent object: { "value": "...", "kind": "..." }
        if let markup = LSPMarkupContent(json: contents ?? [:]) {
            return markup
        }

        // 2. Plain MarkedString (a bare JSON string).
        if let raw = contents as? String, !raw.isEmpty {
            return LSPMarkupContent(value: raw, isMarkdown: false)
        }

        // 3. Code MarkedString: { "language": "...", "value": "..." }
        if let dict = contents as? [String: Any],
           let value = dict["value"] as? String, !value.isEmpty {
            // A code block is always rendered as a fenced snippet — treat as
            // plaintext so the popover shows it verbatim, not re-parsed.
            return LSPMarkupContent(value: value, isMarkdown: false)
        }

        // 4. Array of MarkedStrings: join each element.
        if let array = contents as? [Any], !array.isEmpty {
            var pieces: [String] = []
            var anyMarkdown = false
            for element in array {
                if let s = element as? String, !s.isEmpty {
                    pieces.append(s)
                } else if let d = element as? [String: Any],
                          let v = d["value"] as? String, !v.isEmpty {
                    if let lang = d["language"] as? String, !lang.isEmpty {
                        pieces.append("```\(lang)\n\(v)\n```")
                        anyMarkdown = true
                    } else {
                        pieces.append(v)
                    }
                }
            }
            if pieces.isEmpty { return nil }
            return LSPMarkupContent(value: pieces.joined(separator: "\n\n"), isMarkdown: anyMarkdown)
        }

        return nil
    }
}

// MARK: - Definition

/// An LSP `Location` — a document URI plus a range within it.
nonisolated struct LSPLocation: Equatable, Sendable {
    let uri: String
    let range: LSPRange

    /// Initialises from the raw JSON dictionary of an LSP `Location`.
    /// Returns `nil` when the URI or range is missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let uri = dict["uri"] as? String else { return nil }
        guard let range = LSPRange(json: dict["range"] ?? [:]) else { return nil }
        self.uri = uri
        self.range = range
    }

    init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    /// Resolves the `uri` to a `URL`, decoding the `file://` percent-encoding
    /// that language servers apply to paths with spaces or unicode.
    var url: URL? {
        URL(string: uri)
    }
}

/// An LSP `LocationLink` — the richer definition form with origin/target
/// selection ranges, supported when the client declares
/// `definition.linkSupport`.
nonisolated struct LSPLocationLink: Equatable, Sendable {
    let targetUri: String
    let targetRange: LSPRange
    let targetSelectionRange: LSPRange
    let originSelectionRange: LSPRange?

    /// Initialises from the raw JSON dictionary of an LSP `LocationLink`.
    /// Returns `nil` when the required target fields are missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let uri = dict["targetUri"] as? String else { return nil }
        guard let targetRange = LSPRange(json: dict["targetRange"] ?? [:]) else { return nil }
        guard let targetSelectionRange = LSPRange(json: dict["targetSelectionRange"] ?? [:]) else { return nil }
        self.targetUri = uri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
        if let origin = dict["originSelectionRange"] {
            self.originSelectionRange = LSPRange(json: origin)
        } else {
            self.originSelectionRange = nil
        }
    }

    /// The URL to navigate to (cursor lands on `targetSelectionRange.start`).
    var url: URL? {
        URL(string: targetUri)
    }
}

/// The result of a `textDocument/definition` request.
///
/// The LSP spec allows the server to answer with a single `Location`, an
/// array of `Location`, an array of `LocationLink`, or `null` (no
/// definition). This enum captures all four shapes.
nonisolated enum LSPDefinitionResponse: Equatable, Sendable {
    /// No definition available (server returned `null` or an empty array).
    case empty
    /// One or more `Location` results.
    case locations([LSPLocation])
    /// One or more `LocationLink` results (richer form).
    case locationLinks([LSPLocationLink])

    /// `true` when there is nothing to navigate to.
    var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .locations(let locs): return locs.isEmpty
        case .locationLinks(let links): return links.isEmpty
        }
    }

    /// The number of distinct definitions available (for disambiguation UI).
    var count: Int {
        switch self {
        case .empty: return 0
        case .locations(let locs): return locs.count
        case .locationLinks(let links): return links.count
        }
    }

    /// Initialises from the raw `result` of a definition request, handling
    /// every legal shape the spec permits.
    init(result: Any?) {
        // null → empty
        guard let result else {
            self = .empty
            return
        }

        // A single Location object.
        if let location = LSPLocation(json: result) {
            self = .locations([location])
            return
        }

        // A single LocationLink object (rare, but legal).
        if let link = LSPLocationLink(json: result) {
            self = .locationLinks([link])
            return
        }

        // An array of Location or LocationLink.
        if let array = result as? [Any] {
            let locations = array.compactMap { LSPLocation(json: $0) }
            let links = array.compactMap { LSPLocationLink(json: $0) }
            // Prefer LocationLink when the array elements are links; a mixed
            // array is not spec-compliant so this disambiguation is safe.
            if !links.isEmpty && locations.isEmpty {
                self = .locationLinks(links)
            } else if !locations.isEmpty {
                self = .locations(locations)
            } else {
                self = .empty
            }
            return
        }

        self = .empty
    }
}

// MARK: - Position conversion

/// Converts a UTF-16 caret offset (the unit `NSString`/`NSTextView` use) to an
/// LSP `Position` (0-based line + character).
///
/// LSP positions are measured in UTF-16 code units, which is exactly the unit
/// `NSString`/`NSTextView` use — so the conversion is a line/char split with
/// no transcoding. Both multi-byte characters (handled natively by UTF-16
/// offsets) and CRLF files (each `\r` counts as one character) are correct.
///
/// `nonisolated` because this is pure data work invoked from main-actor UI
/// code; it holds no state.
nonisolated enum LSPPositionConverter {

    /// Returns the 0-based (line, character) for a UTF-16 offset within text.
    static func lspPosition(utf16Offset offset: Int, in text: String) -> LSPPosition {
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        var line = 0
        var char = 0
        var pos = 0
        while pos < clamped {
            if ns.character(at: pos) == ASCII.newline {
                line += 1
                char = 0
            } else {
                char += 1
            }
            pos += 1
        }
        return LSPPosition(line: line, character: char)
    }

    /// Converts a 0-based LSP line (1-based in Pine) + 0-based character
    /// back into a UTF-16 offset, for navigating to a definition target.
    static func utf16Offset(line: Int, character: Int, in text: String) -> Int {
        let ns = text as NSString
        var currentLine = 0
        var offset = 0
        while currentLine < line && offset < ns.length {
            if ns.character(at: offset) == ASCII.newline {
                currentLine += 1
            }
            offset += 1
        }
        // `offset` now points at the start of the target line; advance by
        // `character` (clamped to the remaining length of the line).
        let remaining = ns.length - offset
        return offset + min(max(0, character), remaining)
    }
}
