//
//  RegexSymbolProvider.swift
//  Pine
//
//  Off-main adapter for the existing SymbolParser fallback (#1008).
//

import Foundation

/// Exposes Pine's existing declaration regexes through the normalized symbol
/// provider seam. Results remain flat, preserving unsupported/offline behavior
/// while LSP supplies hierarchy when available.
nonisolated struct RegexSymbolProvider: SymbolProviding {
    let fileExtension: String

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        SymbolParser.supports(fileExtension: fileExtension)
    }

    func symbols(
        for snapshot: DocumentSnapshot
    ) async -> [DocumentSymbolNode]? {
        guard canProvide(for: snapshot) else { return nil }
        let fileExtension = fileExtension
        let symbols = await Task.detached {
            SymbolParser.parse(
                content: snapshot.text,
                fileExtension: fileExtension
            )
        }.value
        let length = (snapshot.text as NSString).length
        let normalized = symbols.compactMap { symbol -> DocumentSymbolNode? in
            guard let location = symbol.selectionOffset,
                  location >= 0,
                  location <= length else {
                return nil
            }
            let nameLength = (symbol.name as NSString).length
            guard nameLength <= length - location else { return nil }
            let selectionRange = NSRange(
                location: location,
                length: nameLength
            )
            return DocumentSymbolNode(
                name: symbol.name,
                kind: SymbolKind(regexKind: symbol.kind),
                range: selectionRange,
                selectionRange: selectionRange,
                children: []
            )
        }
        return normalized.isEmpty ? nil : normalized
    }
}

nonisolated extension SymbolKind {
    init(regexKind: PineSymbolKind) {
        switch regexKind {
        case .class:
            self = .class
        case .struct:
            self = .struct
        case .enum:
            self = .enum
        case .protocol, .interface:
            self = .interface
        case .function:
            self = .function
        case .property:
            self = .property
        }
    }
}
