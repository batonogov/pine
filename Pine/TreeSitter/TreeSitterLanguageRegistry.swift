//
//  TreeSitterLanguageRegistry.swift
//  Pine
//
//  Resolves Pine file extensions/names to tree-sitter `Language` values.
//  Issue #1008 — structural code intelligence (folding, symbols, brackets).
//

import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterPython
import TreeSitterRust
import TreeSitterTypeScript

/// The four languages with first-class tree-sitter support in Pine.
///
/// Issue #1008 acceptance criteria: Swift, TypeScript, Python, Rust.
/// All other languages keep using regex highlighting/folding unchanged.
enum TreeSitterLanguage: String, CaseIterable, Sendable {
    case swift
    case typescript
    case tsx
    case python
    case rust

    /// The C entry-point symbol for this grammar (e.g. `tree_sitter_swift`).
    var languagePointer: OpaquePointer {
        switch self {
        case .swift:
            return tree_sitter_swift()
        case .typescript:
            return tree_sitter_typescript()
        case .tsx:
            return tree_sitter_tsx()
        case .python:
            return tree_sitter_python()
        case .rust:
            return tree_sitter_rust()
        }
    }
}

/// Resolves a Pine file (by extension / file name) to a tree-sitter `Language`.
///
/// `nonisolated` + `Sendable`: this type holds no mutable state and is safe
/// to use from any thread, including the background `com.pine.syntax-highlight`
/// queue. The underlying `Language` struct is `Sendable` (wraps an immutable
/// `OpaquePointer` to a statically-allocated grammar).
nonisolated enum TreeSitterLanguageRegistry {

    /// Map of lowercased file extension → supported language.
    private static let extensionMap: [String: TreeSitterLanguage] = [
        "swift": .swift,
        "py": .python,
        "pyw": .python,
        "rs": .rust,
        "ts": .typescript,
        "tsx": .tsx,
    ]

    /// Resolves a language for a Pine file. Returns nil for unsupported types.
    /// - Parameters:
    ///   - fileExtension: lowercased extension without the dot (e.g. `"swift"`).
    ///   - fileName: optional file name — not currently used for disambiguation
    ///     since all 4 grammars are unambiguous by extension.
    static func resolve(
        fileExtension: String,
        fileName: String? = nil
    ) -> TreeSitterLanguage? {
        extensionMap[fileExtension.lowercased()]
    }

    /// Returns a `Language` ready to hand to a `Parser`, or nil if unsupported.
    static func language(
        for ext: String,
        fileName: String? = nil
    ) -> Language? {
        guard let lang = resolve(fileExtension: ext, fileName: fileName) else {
            return nil
        }
        return Language(language: lang.languagePointer)
    }

    /// Convenience: returns true when Pine has a tree-sitter grammar for `ext`.
    static func isSupported(_ ext: String) -> Bool {
        resolve(fileExtension: ext) != nil
    }
}
