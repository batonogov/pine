//
//  TreeSitterFoldProvider.swift
//  Pine
//
//  Computes foldable ranges from a tree-sitter AST.
//  Issue #1008 — structural code folding.
//
//  Tree-sitter folding augments (does not replace) the existing bracket-pair
//  `FoldRangeCalculator`. `FoldRangeCalculator.calculate` consumes tree-sitter
//  ranges when a grammar is available and falls back to bracket pairs
//  otherwise — see `CodeEditorView+Coordinator.recalculateFoldableRanges`.
//

import Foundation

/// The structural kind of a tree-sitter fold range. Carries a label so the
/// fold gutter can (in future) distinguish `func` / `class` / `block`.
enum TreeSitterFoldKind: String, Sendable, Equatable {
    case function
    case method
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case interface
    case block
    case `if`
    case `for`
    case `while`
    case `switch`
    case `case`
    case `do`
    case `try`
    case other

    /// The set of tree-sitter node types (per supported language) that map to
    /// this fold kind, used by `TreeSitterFoldProvider`.
    fileprivate static let typeMap: [String: TreeSitterFoldKind] = [
        // Swift
        "function_declaration": .function,
        "method_declaration": .method,
        "initializer_declaration": .method,
        "class_declaration": .class,
        "struct_declaration": .struct,
        "enum_declaration": .enum,
        "protocol_declaration": .protocol,
        "extension_declaration": .other,
        "code_block": .block,
        "if_statement": .if,
        "guard_statement": .other,
        "for_statement": .for,
        "while_statement": .while,
        "switch_statement": .switch,
        "do_statement": .do,
        "catch_clause": .try,

        // Python
        "function_definition": .function,
        "class_definition": .class,
        "decorated_definition": .other,
        "block": .block,
        "if_statement": .if,
        "for_statement": .for,
        "while_statement": .while,
        "try_statement": .try,
        "with_statement": .other,
        "match_statement": .switch,

        // Rust
        "function_item": .function,
        "struct_item": .struct,
        "enum_item": .enum,
        "trait_item": .protocol,
        "impl_item": .other,
        "block": .block,
        "if_expression": .if,
        "for_expression": .for,
        "while_expression": .while,
        "match_expression": .switch,
        "unsafe_block": .block,

        // TypeScript / TSX
        "function_declaration": .function,
        "method_definition": .method,
        "class_declaration": .class,
        "interface_declaration": .interface,
        "enum_declaration": .enum,
        "function": .function,
        "arrow_function": .function,
        "statement_block": .block,
        "if_statement": .if,
        "for_statement": .for,
        "while_statement": .while,
        "switch_statement": .switch,
        "try_statement": .try,
    ]
}

/// A foldable range derived from a tree-sitter AST node.
///
/// `Sendable` value type: safe to pass off the background queue. Converted to
/// `FoldableRange` on the main thread by the fold coordinator.
nonisolated struct TreeSitterFoldRange: Sendable, Equatable {
    /// 1-based line number of the fold start.
    let startLine: Int
    /// 1-based line number of the fold end.
    let endLine: Int
    /// UTF-16 offset of the fold start (the opening of the region).
    let startCharIndex: Int
    /// UTF-16 offset of the fold end (the closing of the region).
    let endCharIndex: Int
    /// Structural kind, for gutter display.
    let kind: TreeSitterFoldKind
}

/// Produces `TreeSitterFoldRange`s from a `TreeSitterParseResult`.
///
/// Pure, static, `Sendable`: no mutable state, safe to call from any thread.
nonisolated enum TreeSitterFoldProvider {

    /// Computes foldable ranges from a parsed tree.
    ///
    /// A node is foldable when:
    /// 1. Its type is in `TreeSitterFoldKind.typeMap`, AND
    /// 2. It spans more than one line (single-line regions are not foldable), AND
    /// 3. Its span is at least 2 lines (`endLine > startLine`).
    ///
    /// Nested fold ranges are preserved (e.g. a method inside a class produces
    /// both ranges); this matches the bracket-pair calculator which also emits
    /// nested ranges.
    static func foldRanges(
        from result: TreeSitterParseResult
    ) -> [TreeSitterFoldRange] {
        // Pre-compute line starts for O(log n) line-number lookups.
        let lineStarts = Self.lineStarts(in: result.source)

        var ranges: [TreeSitterFoldRange] = []
        for node in result.nodes {
            guard let kind = TreeSitterFoldKind.typeMap[node.nodeType] else {
                continue
            }
            let startLine = Self.lineNumber(
                at: node.range.location, lineStarts: lineStarts
            )
            let endLine = Self.lineNumber(
                at: NSMaxRange(node.range) - 1, lineStarts: lineStarts
            )
            // Only multi-line regions are foldable.
            guard endLine > startLine else { continue }

            ranges.append(TreeSitterFoldRange(
                startLine: startLine,
                endLine: endLine,
                startCharIndex: node.range.location,
                endCharIndex: NSMaxRange(node.range) - 1,
                kind: kind
            ))
        }

        // Sort by startLine then by endLine descending, so the most specific
        // (smallest) range at a given line sorts after the broader one — same
        // convention as `FoldRangeCalculator`.
        ranges.sort {
            if $0.startLine != $1.startLine {
                return $0.startLine < $1.startLine
            }
            return $0.endLine > $1.endLine
        }
        return ranges
    }

    /// Converts tree-sitter fold ranges to Pine's `FoldableRange` type, using
    /// `.braces` as the kind (tree-sitter structural ranges are visually
    /// equivalent to brace folds in the gutter). This is the bridge consumed
    /// by `FoldRangeCalculator` / the fold coordinator.
    static func toFoldableRanges(
        _ ranges: [TreeSitterFoldRange]
    ) -> [FoldableRange] {
        ranges.map {
            FoldableRange(
                startLine: $0.startLine,
                endLine: $0.endLine,
                startCharIndex: $0.startCharIndex,
                endCharIndex: $0.endCharIndex,
                kind: .braces
            )
        }
    }

    // MARK: - Line helpers

    /// Returns the sorted array of UTF-16 offsets where each line starts.
    private static func lineStarts(in text: String) -> [Int] {
        var starts: [Int] = [0]
        let source = text as NSString
        let length = source.length
        for i in 0..<length where source.character(at: i) == ASCII.newline {
            starts.append(i + 1)
        }
        return starts
    }

    /// 1-based line number for a UTF-16 offset, via binary search.
    /// Mirrors `FoldRangeCalculator.lineNumber`.
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
