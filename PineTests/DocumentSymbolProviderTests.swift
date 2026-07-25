//
//  DocumentSymbolProviderTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("LSP Document Symbol Provider Tests")
struct DocumentSymbolProviderTests {
    @Test("Decodes recursive DocumentSymbol hierarchy")
    func decodesHierarchy() throws {
        let json: [String: Any] = [
            "name": "Container",
            "kind": 5,
            "range": rangeJSON(0, 0, 4, 1),
            "selectionRange": rangeJSON(0, 6, 0, 15),
            "children": [
                [
                    "name": "method",
                    "kind": 6,
                    "range": rangeJSON(1, 4, 3, 5),
                    "selectionRange": rangeJSON(1, 9, 1, 15)
                ]
            ]
        ]

        let symbol = try #require(LSPDocumentSymbol(json: json))

        #expect(symbol.name == "Container")
        #expect(symbol.kind == 5)
        #expect(symbol.children.map(\.name) == ["method"])
        #expect(symbol.positionEncoding == .utf16)
    }

    @Test("Malformed children do not discard a valid parent")
    func malformedChildIsSkipped() throws {
        let json: [String: Any] = [
            "name": "Container",
            "kind": 5,
            "range": rangeJSON(0, 0, 1, 1),
            "selectionRange": rangeJSON(0, 0, 0, 9),
            "children": [
                ["name": "missing ranges", "kind": 12],
                [
                    "name": "valid",
                    "kind": 12,
                    "range": rangeJSON(0, 0, 0, 9),
                    "selectionRange": rangeJSON(0, 0, 0, 5)
                ]
            ]
        ]

        let symbol = try #require(LSPDocumentSymbol(json: json))

        #expect(symbol.children.map(\.name) == ["valid"])
    }

    @Test("Rejects missing required DocumentSymbol fields")
    func rejectsMissingFields() {
        #expect(LSPDocumentSymbol(json: ["name": "x"]) == nil)
        #expect(
            LSPDocumentSymbol(
                json: [
                    "name": "",
                    "kind": 12,
                    "range": rangeJSON(0, 0, 0, 1),
                    "selectionRange": rangeJSON(0, 0, 0, 1)
                ]
            ) == nil
        )
        #expect(LSPDocumentSymbol(json: "not a symbol") == nil)
    }

    @Test("Normalizes emoji, CJK, CRLF, and nested declarations")
    func normalizesUnicodeCRLFHierarchy() throws {
        let text = "class 外😀 {\r\n  func 子() {}\r\n}\r\n"
        let child = symbol(
            name: "子",
            kind: 12,
            range: range(1, 2, 1, 13),
            selection: range(1, 7, 1, 8)
        )
        let parent = symbol(
            name: "外😀",
            kind: 5,
            range: range(0, 0, 2, 1),
            selection: range(0, 6, 0, 9),
            children: [child]
        )
        let snapshot = snapshot(text)

        let nodes = try #require(
            LSPDocumentSymbolProvider.normalize(
                [parent],
                snapshot: snapshot
            )
        )
        let root = try #require(nodes.first)
        let nested = try #require(root.children.first)

        #expect(root.name == "外😀")
        #expect(root.kind == .class)
        #expect(root.selectionRange == NSRange(location: 6, length: 3))
        #expect(nested.name == "子")
        #expect(nested.kind == .function)
        #expect(nested.selectionRange == NSRange(location: 20, length: 1))
    }

    @Test("Converts UTF-8 positions to UTF-16 ranges")
    func convertsUTF8Positions() throws {
        let text = "😀 class X\n"
        let raw = symbol(
            name: "X",
            kind: 5,
            range: range(0, 4, 0, 12),
            selection: range(0, 11, 0, 12),
            encoding: .utf8
        )

        let node = try #require(
            LSPDocumentSymbolProvider.normalize(
                [raw],
                snapshot: snapshot(text)
            )?.first
        )

        #expect(node.range == NSRange(location: 2, length: 8))
        #expect(node.selectionRange == NSRange(location: 9, length: 1))
    }

    @Test("Mid-scalar UTF-8 positions fail closed")
    func rejectsMidScalarUTF8() {
        let raw = symbol(
            name: "bad",
            kind: 12,
            range: range(0, 1, 0, 4),
            selection: range(0, 1, 0, 4),
            encoding: .utf8
        )

        #expect(
            LSPDocumentSymbolProvider.normalize(
                [raw],
                snapshot: snapshot("😀")
            ) == nil
        )
    }

    @Test("Unknown encoding and out-of-bounds positions fail closed")
    func rejectsUnknownAndOutOfBounds() {
        let unknown = symbol(
            name: "x",
            kind: 12,
            range: range(0, 0, 0, 1),
            selection: range(0, 0, 0, 1),
            encoding: .unknown
        )
        let outOfBounds = symbol(
            name: "x",
            kind: 12,
            range: range(0, 0, 9, 1),
            selection: range(0, 0, 0, 1)
        )

        #expect(
            LSPDocumentSymbolProvider.normalize(
                [unknown],
                snapshot: snapshot("x")
            ) == nil
        )
        #expect(
            LSPDocumentSymbolProvider.normalize(
                [outOfBounds],
                snapshot: snapshot("x")
            ) == nil
        )
    }

    @Test("Invalid child range is dropped without blanking parent")
    func invalidChildDoesNotBlankParent() throws {
        let child = symbol(
            name: "outside",
            kind: 12,
            range: range(1, 0, 1, 1),
            selection: range(1, 0, 1, 1)
        )
        let parent = symbol(
            name: "root",
            kind: 5,
            range: range(0, 0, 0, 4),
            selection: range(0, 0, 0, 4),
            children: [child]
        )

        let node = try #require(
            LSPDocumentSymbolProvider.normalize(
                [parent],
                snapshot: snapshot("root\nx")
            )?.first
        )

        #expect(node.name == "root")
        #expect(node.children.isEmpty)
    }

    @Test("Provider defers on nil, empty, and all-invalid results")
    func providerDefers() async {
        let snapshot = snapshot("func local() {}")
        let nilProvider = LSPDocumentSymbolProvider { _ in nil }
        let emptyProvider = LSPDocumentSymbolProvider { _ in [] }
        let invalidSymbol = symbol(
            name: "bad",
            kind: 12,
            range: range(10, 0, 11, 0),
            selection: range(10, 0, 10, 1)
        )
        let invalidProvider = LSPDocumentSymbolProvider { _ in
            [invalidSymbol]
        }

        #expect(await nilProvider.symbols(for: snapshot) == nil)
        #expect(await emptyProvider.symbols(for: snapshot) == nil)
        #expect(await invalidProvider.symbols(for: snapshot) == nil)
    }

    @Test("LSP symbol kinds map deterministically")
    func mapsKinds() {
        #expect(SymbolKind(lspKind: 2) == .namespace)
        #expect(SymbolKind(lspKind: 5) == .class)
        #expect(SymbolKind(lspKind: 6) == .function)
        #expect(SymbolKind(lspKind: 7) == .property)
        #expect(SymbolKind(lspKind: 10) == .enum)
        #expect(SymbolKind(lspKind: 11) == .interface)
        #expect(SymbolKind(lspKind: 13) == .variable)
        #expect(SymbolKind(lspKind: 23) == .struct)
        #expect(SymbolKind(lspKind: 999) == .other)
    }

    @Test("Document-symbol capability accepts boolean and options object")
    func decodesCapability() {
        #expect(
            LSPServerCapabilities(
                json: ["documentSymbolProvider": true]
            ).documentSymbolProvider
        )
        #expect(
            LSPServerCapabilities(
                json: ["documentSymbolProvider": ["label": "symbols"]]
            ).documentSymbolProvider
        )
        #expect(
            !LSPServerCapabilities(
                json: ["documentSymbolProvider": false]
            ).documentSymbolProvider
        )
    }

    private func snapshot(_ text: String) -> DocumentSnapshot {
        DocumentSnapshot(
            uri: "file:///test.swift",
            text: text,
            revision: DocumentRevision(1)
        )
    }

    private func symbol(
        name: String,
        kind: Int,
        range: LSPRange,
        selection: LSPRange,
        children: [LSPDocumentSymbol] = [],
        encoding: LSPPositionEncoding = .utf16
    ) -> LSPDocumentSymbol {
        LSPDocumentSymbol(
            name: name,
            kind: kind,
            range: range,
            selectionRange: selection,
            children: children,
            positionEncoding: encoding
        )
    }

    private func range(
        _ startLine: Int,
        _ startCharacter: Int,
        _ endLine: Int,
        _ endCharacter: Int
    ) -> LSPRange {
        LSPRange(
            start: LSPPosition(
                line: startLine,
                character: startCharacter
            ),
            end: LSPPosition(
                line: endLine,
                character: endCharacter
            )
        )
    }

    private func rangeJSON(
        _ startLine: Int,
        _ startCharacter: Int,
        _ endLine: Int,
        _ endCharacter: Int
    ) -> [String: Any] {
        [
            "start": [
                "line": startLine,
                "character": startCharacter
            ],
            "end": [
                "line": endLine,
                "character": endCharacter
            ]
        ]
    }
}
