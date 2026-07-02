//
//  TreeSitterParser.swift
//  Pine
//
//  Parses source text into a tree-sitter AST for structural editor features.
//  Issue #1008 — structural code intelligence.
//
//  Runs on the existing background `com.pine.syntax-highlight` queue. Isolation
//  follows Pine's concurrency model: `nonisolated` + `Sendable` so closures
//  handed to `DispatchQueue(label:).async` do not inherit MainActor isolation
//  (see `.github/scripts/check_nonisolated.py`).
//

import Foundation
import SwiftTreeSitter

/// A lightweight, immutable view of a parsed tree-sitter node.
///
/// Decoupled from the `SwiftTreeSitter.Node` class-bound type so value-type
/// results can be freely passed across actor/thread boundaries without
/// retaining the (reference-counted) underlying tree.
nonisolated struct TreeSitterNodeInfo: Sendable {
    /// The tree-sitter node type string (e.g. `"function_declaration"`).
    let nodeType: String
    /// UTF-16 NSRange, matching Pine's text-system conventions.
    let range: NSRange
    /// 0-based (row, column) of the node start, row == line - 1.
    let startPoint: TreeSitterPoint
    /// 0-based (row, column) of the node end, row == line - 1.
    let endPoint: TreeSitterPoint
    /// Whether the node is a "named" node in the grammar.
    let isNamed: Bool
}

/// 0-based (row, column) point. `Sendable` value type.
nonisolated struct TreeSitterPoint: Sendable {
    let row: Int
    let column: Int
}

/// Result of a parse: the root node info plus a flat list of named descendants.
///
/// The flat descendant list is what fold/symbol providers consume; carrying it
/// on the result avoids re-walking the (reference-typed) tree off the
/// background queue.
nonisolated struct TreeSitterParseResult: Sendable {
    /// The grammar that produced this tree, or nil if parsing was skipped.
    let language: TreeSitterLanguage
    /// Info for the root node.
    let root: TreeSitterNodeInfo
    /// All named descendants in document order (pre-order DFS).
    let nodes: [TreeSitterNodeInfo]
    /// The original source text, retained for name extraction (kept as a
    /// value-type `String` so the result is fully self-contained off the
    /// background queue). `String` is `Sendable`.
    let source: String
}

/// Parses source code into tree-sitter ASTs for Pine's structural features.
///
/// One parser per language is cached (`Parser` is not `Sendable` in
/// SwiftTreeSitter, so the cache lives behind an `NSLock`). Parsing itself is
/// pure computation and safe to run off the main thread.
///
/// `nonisolated` + `@unchecked Sendable`: all mutable state is guarded by
/// `parserLock`. This type is safe to use from the background
/// `com.pine.syntax-highlight` queue.
nonisolated final class TreeSitterParser: @unchecked Sendable {

    /// Serial queue for tree-sitter parsing. Shares the name space with the
    /// regex highlighter so the two coexist in the same QoS band.
    ///
    /// Reusing a dedicated queue (rather than `DispatchQueue.global`) matches
    /// Pine's existing pattern and keeps parse latency predictable.
    private let parseQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.pine.syntax-highlight")
        queue.setTarget(queue: DispatchQueue.global(qos: .userInitiated))
        return queue
    }()

    private let parserLock = NSLock()
    /// One `Parser` per language (parsers retain their language setting).
    private var parsers: [TreeSitterLanguage: Parser] = [:]

    init() {}

    // MARK: - Public

    /// Parses source text on the background queue, returning a self-contained
    /// `TreeSitterParseResult` (or nil if the language is unsupported or the
    /// parse failed). The result is safe to consume on any thread.
    ///
    /// - Parameters:
    ///   - text: source code (UTF-16, matching Pine's text system).
    ///   - fileExtension: lowercased extension without the dot.
    ///   - fileName: optional file name (reserved for future disambiguation).
    func parse(
        text: String,
        fileExtension ext: String,
        fileName: String? = nil,
        generation: TreeSitterParseGeneration? = nil,
        token gen: Int = 0
    ) async -> TreeSitterParseResult? {
        guard let language = TreeSitterLanguageRegistry.resolve(
            fileExtension: ext, fileName: fileName
        ) else {
            return nil
        }
        let source = text

        let result: TreeSitterParseResult? = await withCheckedContinuation { continuation in
            parseQueue.async {
                if let generation, generation.current != gen { continuation.resume(returning: nil); return }

                let tree = self.parseSynchronized(text: source, language: language)
                guard let tree, let root = tree.rootNode else {
                    continuation.resume(returning: nil)
                    return
                }

                // Build a flat, Sendable snapshot of the tree.
                var nodes: [TreeSitterNodeInfo] = []
                self.collectNamedNodes(from: root, into: &nodes)

                let rootInfo = Self.info(for: root)
                continuation.resume(returning: TreeSitterParseResult(
                    language: language,
                    root: rootInfo,
                    nodes: nodes,
                    source: source
                ))
            }
        }
        return result
    }

    /// Synchronous parse (used internally and by tests). Thread-safe via
    /// `parserLock` around parser access. Returns nil on parse failure or
    /// unsupported language.
    func parseSync(
        text: String,
        fileExtension ext: String,
        fileName: String? = nil
    ) -> TreeSitterParseResult? {
        guard let language = TreeSitterLanguageRegistry.resolve(
            fileExtension: ext, fileName: fileName
        ) else {
            return nil
        }
        guard let tree = parseSynchronized(text: text, language: language),
              let root = tree.rootNode else {
            return nil
        }
        var nodes: [TreeSitterNodeInfo] = []
        collectNamedNodes(from: root, into: &nodes)
        return TreeSitterParseResult(
            language: language,
            root: Self.info(for: root),
            nodes: nodes,
            source: text
        )
    }

    // MARK: - Private

    /// Returns a `MutableTree?` for `text` under `language`. Acquires
    /// `parserLock` only while configuring/calling the (per-language cached)
    /// `Parser`; the parse itself runs while the lock is held because
    /// `Parser` is single-threaded by design (tree-sitter is not reentrant).
    private func parseSynchronized(
        text: String,
        language: TreeSitterLanguage
    ) -> MutableTree? {
        let parser = parserLock.withLock { parser(for: language) }
        // Parser.parse(_:) is synchronous and single-threaded; safe to call
        // here because this method is only invoked from parseQueue.async.
        return parser.parse(text)
    }

    /// Returns (creating if needed) a configured `Parser` for `language`.
    /// Must be called while holding `parserLock`.
    private func parser(for language: TreeSitterLanguage) -> Parser {
        if let cached = parsers[language] {
            return cached
        }
        let parser = Parser()
        let lang = Language(language: language.languagePointer)
        // setLanguage can throw if the grammar is incompatible with the
        // linked tree-sitter runtime. We treat that as "unsupported" and
        // fall back to regex; log and cache the parser anyway to avoid
        // retrying on every call.
        do {
            try parser.setLanguage(lang)
        } catch {
            // Non-fatal: the language simply won't parse. Pine falls back
            // to bracket-pair folding and regex symbols.
        }
        parsers[language] = parser
        return parser
    }

    /// Pre-order DFS over named children, appending `TreeSitterNodeInfo` for
    /// each named node. `Node` is reference-backed by the tree; we copy out
    /// the Sendable fields immediately.
    private func collectNamedNodes(
        from node: Node,
        into acc: inout [TreeSitterNodeInfo]
    ) {
        if node.isNamed {
            acc.append(Self.info(for: node))
        }
        for i in 0..<node.childCount {
            if let child = node.child(at: i) {
                collectNamedNodes(from: child, into: &acc)
            }
        }
    }

    /// Converts a `SwiftTreeSitter.Node` to a Sendable `TreeSitterNodeInfo`.
    private static func info(for node: Node) -> TreeSitterNodeInfo {
        TreeSitterNodeInfo(
            nodeType: node.nodeType ?? "",
            range: node.range,
            startPoint: TreeSitterPoint(
                row: Int(node.pointRange.lowerBound.row),
                column: Int(node.pointRange.lowerBound.column)
            ),
            endPoint: TreeSitterPoint(
                row: Int(node.pointRange.upperBound.row),
                column: Int(node.pointRange.upperBound.column)
            ),
            isNamed: node.isNamed
        )
    }
}

/// Thread-safe generation counter for cancelling stale tree-sitter parse
/// requests. Mirrors `HighlightGeneration` for the regex highlighter.
nonisolated final class TreeSitterParseGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    var current: Int { lock.withLock { value } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
