//
//  TreeSitterBracketMatcher.swift
//  Pine
//
//  Structural bracket matching via tree-sitter node context.
//  Issue #1008 — better bracket matching.
//
//  Pine's existing `BracketMatcher` already skips brackets inside strings and
//  comments by consuming precomputed `commentAndStringRanges`. Tree-sitter
//  makes this *structural*: a bracket is "string-like" or "comment-like" when
//  its tree-sitter node type says so, which is more robust than regex ranges
//  for multi-line constructs, interpolated strings, and nested comments.
//
//  This provider produces the string/comment ranges directly from the AST;
//  `BracketMatcher` consumes them as `skipRanges` unchanged.
//

import Foundation

/// Produces string/comment ranges from a tree-sitter AST, for consumption by
/// `BracketMatcher` and `FoldRangeCalculator` as `skipRanges`.
///
/// `nonisolated`: pure static functions, safe to call from any thread.
nonisolated enum TreeSitterBracketMatcher {

    /// Tree-sitter node types that represent strings (and should be skipped
    /// when scanning for brackets). Covers the 4 supported languages.
    private static let stringTypes: Set<String> = [
        // Swift
        "line_string_literal",
        "multi_line_string_literal",
        "raw_str_interpolation",
        "string_literal",
        "interpolated_string_literal",
        "simple_multiline_string",
        "simple_string",
        // Python
        "string",
        "concatenated_string",
        "fstring",
        // Rust
        "string_literal",
        "raw_string_literal",
        "byte_string_literal",
        // TypeScript
        "string",
        "template_string",
        "template_literal_type",
    ]

    /// Tree-sitter node types that represent comments.
    private static let commentTypes: Set<String> = [
        // Swift
        "comment",
        "multiline_comment",
        "doc_comment",
        // Python
        "comment",
        // Rust
        "line_comment",
        "block_comment",
        // TypeScript
        "comment",
    ]

    /// Returns the union of string + comment ranges in the parsed tree, as
    /// `NSRange`s suitable for use as `BracketMatcher` / `FoldRangeCalculator`
    /// `skipRanges`. Sorted by location for binary-search consumption.
    static func skipRanges(
        from result: TreeSitterParseResult
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        for node in result.nodes {
            if stringTypes.contains(node.nodeType)
                || commentTypes.contains(node.nodeType) {
                ranges.append(node.range)
            }
        }
        ranges.sort { $0.location < $1.location }
        return ranges
    }

    /// Returns only the comment ranges (useful for fold calculations that
    /// want to fold block comments but not strings).
    static func commentRanges(
        from result: TreeSitterParseResult
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        for node in result.nodes where commentTypes.contains(node.nodeType) {
            ranges.append(node.range)
        }
        ranges.sort { $0.location < $1.location }
        return ranges
    }
}
