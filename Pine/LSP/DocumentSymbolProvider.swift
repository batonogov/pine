//
//  DocumentSymbolProvider.swift
//  Pine
//
//  LSP `textDocument/documentSymbol` decoding and normalization for #1008.
//

import Foundation

/// A recursive LSP `DocumentSymbol`. Positions remain in the encoding
/// negotiated with the server until the provider validates them against the
/// immutable document snapshot.
nonisolated struct LSPDocumentSymbol: Equatable, Sendable {
    let name: String
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [LSPDocumentSymbol]
    let positionEncoding: LSPPositionEncoding

    init?(
        json: Any,
        positionEncoding: LSPPositionEncoding = .utf16
    ) {
        guard let dictionary = json as? [String: Any],
              let name = dictionary["name"] as? String,
              !name.isEmpty,
              let kind = dictionary["kind"] as? Int,
              let range = LSPRange(json: dictionary["range"] ?? [:]),
              let selectionRange = LSPRange(
                json: dictionary["selectionRange"] ?? [:]
              ) else {
            return nil
        }

        self.name = name
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = (dictionary["children"] as? [Any] ?? []).compactMap {
            LSPDocumentSymbol(
                json: $0,
                positionEncoding: positionEncoding
            )
        }
        self.positionEncoding = positionEncoding
    }

    init(
        name: String,
        kind: Int,
        range: LSPRange,
        selectionRange: LSPRange,
        children: [LSPDocumentSymbol] = [],
        positionEncoding: LSPPositionEncoding = .utf16
    ) {
        self.name = name
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
        self.positionEncoding = positionEncoding
    }
}

/// Converts LSP line/character ranges to Pine's UTF-16 `NSRange` model.
nonisolated enum LSPTextRangeNormalizer {
    private struct LineBounds {
        let start: Int
        let contentEnd: Int
    }

    static func normalize(
        _ range: LSPRange,
        in text: String,
        encoding: LSPPositionEncoding
    ) -> NSRange? {
        let source = text as NSString
        let lines = lineBounds(in: source)
        guard let start = offset(
            for: range.start,
            lines: lines,
            source: source,
            encoding: encoding
        ),
        let end = offset(
            for: range.end,
            lines: lines,
            source: source,
            encoding: encoding
        ),
        end >= start else {
            return nil
        }
        return NSRange(location: start, length: end - start)
    }

    private static func offset(
        for position: LSPPosition,
        lines: [LineBounds],
        source: NSString,
        encoding: LSPPositionEncoding
    ) -> Int? {
        guard position.line >= 0,
              position.line < lines.count,
              position.character >= 0 else {
            return nil
        }
        let line = lines[position.line]
        let utf16Length = line.contentEnd - line.start

        switch encoding {
        case .utf16:
            guard position.character <= utf16Length else { return nil }
            return line.start + position.character
        case .utf8:
            let lineText = source.substring(
                with: NSRange(
                    location: line.start,
                    length: utf16Length
                )
            )
            let utf8 = lineText.utf8
            guard position.character <= utf8.count,
                  let utf8Index = utf8.index(
                    utf8.startIndex,
                    offsetBy: position.character,
                    limitedBy: utf8.endIndex
                  ),
                  let utf16Index = utf8Index.samePosition(
                    in: lineText.utf16
                  ) else {
                return nil
            }
            return line.start + lineText.utf16.distance(
                from: lineText.utf16.startIndex,
                to: utf16Index
            )
        case .unknown:
            return nil
        }
    }

    private static func lineBounds(in source: NSString) -> [LineBounds] {
        var lines: [LineBounds] = []
        var lineStart = 0
        var index = 0

        while index < source.length {
            let character = source.character(at: index)
            if character == 0x0A {
                lines.append(
                    LineBounds(start: lineStart, contentEnd: index)
                )
                index += 1
                lineStart = index
            } else if character == 0x0D {
                lines.append(
                    LineBounds(start: lineStart, contentEnd: index)
                )
                if index + 1 < source.length,
                   source.character(at: index + 1) == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                lineStart = index
            } else {
                index += 1
            }
        }

        if lineStart < source.length || lines.isEmpty {
            lines.append(
                LineBounds(start: lineStart, contentEnd: source.length)
            )
        } else if lineStart == source.length {
            lines.append(
                LineBounds(start: lineStart, contentEnd: lineStart)
            )
        }
        return lines
    }
}

/// Adapts an LSP document-symbol request to Pine's recursive symbol model.
nonisolated final class LSPDocumentSymbolProvider:
    SymbolProviding,
    @unchecked Sendable {

    private let requester:
        @Sendable (DocumentSnapshot) async -> [LSPDocumentSymbol]?

    init(
        requester: @Sendable @escaping (
            DocumentSnapshot
        ) async -> [LSPDocumentSymbol]?
    ) {
        self.requester = requester
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        true
    }

    func symbols(
        for snapshot: DocumentSnapshot
    ) async -> [DocumentSymbolNode]? {
        guard let symbols = await requester(snapshot), !symbols.isEmpty else {
            return nil
        }
        return Self.normalize(symbols, snapshot: snapshot)
    }

    /// Validates every range independently. Invalid children are discarded
    /// without losing a valid parent; an all-invalid response defers to regex.
    static func normalize(
        _ symbols: [LSPDocumentSymbol],
        snapshot: DocumentSnapshot
    ) -> [DocumentSymbolNode]? {
        let normalized = symbols.compactMap {
            normalize($0, snapshot: snapshot, parentRange: nil)
        }
        .sorted(by: sourceOrder)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalize(
        _ symbol: LSPDocumentSymbol,
        snapshot: DocumentSnapshot,
        parentRange: NSRange?
    ) -> DocumentSymbolNode? {
        guard let range = LSPTextRangeNormalizer.normalize(
            symbol.range,
            in: snapshot.text,
            encoding: symbol.positionEncoding
        ),
        let selectionRange = LSPTextRangeNormalizer.normalize(
            symbol.selectionRange,
            in: snapshot.text,
            encoding: symbol.positionEncoding
        ),
        contains(range, selectionRange),
        parentRange.map({ contains($0, range) }) ?? true else {
            return nil
        }

        let children = symbol.children.compactMap {
            normalize(
                $0,
                snapshot: snapshot,
                parentRange: range
            )
        }
        .sorted(by: sourceOrder)

        return DocumentSymbolNode(
            name: symbol.name,
            kind: SymbolKind(lspKind: symbol.kind),
            range: range,
            selectionRange: selectionRange,
            children: children
        )
    }

    private static func contains(
        _ outer: NSRange,
        _ inner: NSRange
    ) -> Bool {
        inner.location >= outer.location
            && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func sourceOrder(
        _ lhs: DocumentSymbolNode,
        _ rhs: DocumentSymbolNode
    ) -> Bool {
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        if lhs.range.length != rhs.range.length {
            return lhs.range.length > rhs.range.length
        }
        return lhs.name < rhs.name
    }
}

nonisolated extension SymbolKind {
    init(lspKind: Int) {
        switch lspKind {
        case 2, 3, 4:
            self = .namespace
        case 5:
            self = .class
        case 6, 9, 12:
            self = .function
        case 7, 8:
            self = .property
        case 10:
            self = .enum
        case 11:
            self = .interface
        case 13, 14:
            self = .variable
        case 23:
            self = .struct
        default:
            self = .other
        }
    }
}
