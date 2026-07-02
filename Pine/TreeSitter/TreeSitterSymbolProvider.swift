//
//  TreeSitterSymbolProvider.swift
//  Pine
//
//  Extracts document symbols (functions, classes, structs, ...) from a
//  tree-sitter AST. Issue #1008 — symbol navigation.
//
//  Augments (does not replace) the regex-based `SymbolParser`. For the four
//  tree-sitter-supported languages this produces symbols with correct nesting
//  and reliable name extraction; all other languages keep using `SymbolParser`.
//

import Foundation

/// A symbol extracted from a tree-sitter AST, carrying nesting depth so the
/// symbol navigator can render indentation for nested declarations
/// (e.g. a method inside a class).
nonisolated struct TreeSitterSymbol: Identifiable, Sendable, Equatable {
    /// Stable identity based on name + kind + line + depth.
    let id: String
    let name: String
    let kind: PineSymbolKind
    /// 1-based line number.
    let line: Int
    /// Nesting depth (0 = top-level, 1 = inside a type, ...).
    let depth: Int

    static func == (lhs: TreeSitterSymbol, rhs: TreeSitterSymbol) -> Bool {
        lhs.id == rhs.id
    }
}

/// Maps tree-sitter node types → Pine symbol kinds, per supported language.
///
/// The tree-sitter node-type names are language-specific but largely stable
/// across grammars (the `typeMap` keys cover the 4 supported languages).
nonisolated enum TreeSitterSymbolProvider {

    /// Node-type → PineSymbolKind. Keys are the union of the 4 grammars' type
    /// names for declarations.
    private static let typeMap: [String: PineSymbolKind] = [
        // Swift
        "class_declaration": .class,
        "struct_declaration": .struct,
        "enum_declaration": .enum,
        "protocol_declaration": .protocol,
        "function_declaration": .function,
        "method_declaration": .function,

        // Python
        "class_definition": .class,
        "function_definition": .function,

        // Rust
        "struct_item": .struct,
        "enum_item": .enum,
        "trait_item": .protocol,
        "function_item": .function,
        "function_signature_item": .function,

        // TypeScript / TSX
        "class_declaration": .class,
        "interface_declaration": .interface,
        "enum_declaration": .enum,
        "function_declaration": .function,
        "method_definition": .function,
        "function": .function,
    ]

    /// Extracts symbols from a parsed tree, preserving declaration order and
    /// nesting depth.
    ///
    /// Name extraction is grammar-aware: it looks for a `name`/`identifier`/
    /// `type_identifier` child, then falls back to the first named child, then
    /// to the node's own text. This mirrors the approach used by upstream
    /// `tree-sitter-{lang}-queries` symbol queries, without requiring a `.scm`
    /// query runtime.
    static func symbols(
        from result: TreeSitterParseResult
    ) -> [TreeSitterSymbol] {
        let lineStarts = Self.lineStarts(in: result.source)
        let source = result.source as NSString

        var symbols: [TreeSitterSymbol] = []
        // Depth is tracked via the difference between the node's start row and
        // its enclosing declaration. We compute a simple nesting level by
        // counting how many preceding *declaration* nodes contain this node.
        // For efficiency we walk nodes in document order and maintain a stack
        // of open declarations.
        var declStack: [(node: TreeSitterNodeInfo, depth: Int)] = []

        for node in result.nodes {
            guard let kind = typeMap[node.nodeType] else { continue }

            // Pop declarations whose end is before this node's start.
            while let last = declStack.last,
                  last.node.range.location + last.node.range.length
                    <= node.range.location {
                declStack.removeLast()
            }

            let depth = declStack.count
            let name = Self.extractName(
                from: node, source: source, allNodes: result.nodes
            )
            let line = Self.lineNumber(
                at: node.range.location, lineStarts: lineStarts
            )
            let id = "\(node.nodeType):\(name):\(line):\(depth)"

            symbols.append(TreeSitterSymbol(
                id: id,
                name: name,
                kind: kind,
                line: line,
                depth: depth
            ))

            // Push onto the stack so nested declarations get depth+1.
            declStack.append((node: node, depth: depth))
        }

        return symbols
    }

    /// Converts `TreeSitterSymbol`s to `PineSymbol`s for the symbol navigator.
    /// Nesting depth is dropped (the navigator renders a flat list today); the
    /// `depth` field is preserved on `TreeSitterSymbol` for a future indented
    /// outline view.
    static func toPineSymbols(
        _ symbols: [TreeSitterSymbol]
    ) -> [PineSymbol] {
        symbols.map {
            PineSymbol(name: $0.name, kind: $0.kind, line: $0.line)
        }
    }

    // MARK: - Private

    /// Extracts a human-readable name for a declaration node. Tries several
    /// heuristics in order: a child named `name`/`identifier`/`type_identifier`
    /// (approximated by scanning the full node list for a named child whose
    /// range is contained and comes right after the decl start), then the
    /// first identifier-like token in the node's own text.
    private static func extractName(
        from node: TreeSitterNodeInfo,
        source: NSString,
        allNodes: [TreeSitterNodeInfo]
    ) -> String {
        // Look for an immediate named child whose type is an identifier.
        // We approximate "immediate child" by scanning the node list for a
        // node whose range starts within `node` and is closest to the start.
        var best: TreeSitterNodeInfo?
        var bestOffset = Int.max
        for child in allNodes {
            // Skip self.
            if child.range.location == node.range.location { continue }
            // Must be contained within the declaration.
            guard child.range.location >= node.range.location,
                  NSMaxRange(child.range) <= NSMaxRange(node.range) else {
                continue
            }
            // Prefer identifier-like child types.
            let t = child.nodeType
            guard t == "identifier"
                    || t == "type_identifier"
                    || t == "name"
                    || t.hasSuffix("_identifier") else { continue }
            let offset = child.range.location - node.range.location
            if offset < bestOffset {
                bestOffset = offset
                best = child
            }
        }
        if let best {
            let text = source.substring(with: best.range)
            if !text.isEmpty { return text }
        }

        // Fallback: first identifier-like token in the node's own text.
        let own = source.substring(with: node.range)
        if let name = Self.firstIdentifier(in: own) {
            return name
        }
        return own.split(separator: "\n").first.map(String.init) ?? own
    }

    /// Returns the first identifier-like substring of `text`, or nil.
    private static func firstIdentifier(in text: String) -> String? {
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else {
                if !current.isEmpty,
                   current.first?.isLetter == true || current.first == "_" {
                    return current
                }
                current = ""
            }
        }
        return current.first?.isLetter == true || current.first == "_" ? current : nil
    }

    private static func lineStarts(in text: String) -> [Int] {
        var starts: [Int] = [0]
        let source = text as NSString
        let length = source.length
        for i in 0..<length where source.character(at: i) == ASCII.newline {
            starts.append(i + 1)
        }
        return starts
    }

    private static func lineNumber(at charIndex: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charIndex {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }
}
