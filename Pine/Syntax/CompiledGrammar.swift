//
//  CompiledGrammar.swift
//  Pine
//
//  Extracted from SyntaxHighlighter.swift — compiled regex rules and caching.
//

import Foundation
import os

/// A compiled highlighting rule with its NSRegularExpression and metadata.
nonisolated struct CompiledRule: Sendable {
    let regex: NSRegularExpression
    let scope: String
    /// True for rules that can match across line breaks
    /// (pattern contains `[\s\S]` or option dotMatchesLineSeparators).
    let isMultiline: Bool
}

/// Thread-safe cache for compiled grammar rules, keyed by grammar name.
nonisolated final class CompiledGrammarCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiledRules: [String: [CompiledRule]] = [:]

    init() {}

    /// Returns compiled rules for a grammar name, or nil if not compiled.
    func rules(for grammarName: String) -> [CompiledRule]? {
        lock.withLock { compiledRules[grammarName] }
    }

    /// Stores compiled rules for a grammar name.
    func setRules(_ rules: [CompiledRule], for grammarName: String) {
        lock.withLock { compiledRules[grammarName] = rules }
    }

    /// Removes compiled rules for a grammar name.
    func removeRules(for grammarName: String) {
        lock.withLock { compiledRules.removeValue(forKey: grammarName) }
    }
}

/// Compiles grammar rules into NSRegularExpression instances.
/// Pure functions — no lock required; safe to call from any context.
nonisolated enum GrammarCompiler {
    /// Compiles all rules in a grammar into CompiledRule instances.
    nonisolated static func compileRules(for grammar: Grammar) -> [CompiledRule] {
        var rules: [CompiledRule] = []

        for rule in grammar.rules {
            var opts: NSRegularExpression.Options = []
            var isMultiline = false

            if let options = rule.options {
                for opt in options {
                    switch opt {
                    case "anchorsMatchLines":
                        opts.insert(.anchorsMatchLines)
                    case "caseInsensitive":
                        opts.insert(.caseInsensitive)
                    case "dotMatchesLineSeparators":
                        opts.insert(.dotMatchesLineSeparators)
                        isMultiline = true
                    default:
                        break
                    }
                }
            }

            if rule.pattern.contains("[\\s\\S]") || rule.pattern.contains("[\\S\\s]") {
                isMultiline = true
            }

            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts) {
                rules.append(CompiledRule(regex: regex, scope: rule.scope, isMultiline: isMultiline))
            } else {
                Logger.syntax.error("Invalid regex in \(grammar.name): \(rule.pattern)")
            }
        }

        return rules
    }

    /// Collects a fingerprint of multiline match lengths for structural change detection.
    /// Lengths are invariant to insertions/deletions above the token (location shifts, length doesn't).
    nonisolated static func collectMultilineFingerprint(
        rules: [CompiledRule],
        source: String,
        searchRange: NSRange
    ) -> [Int] {
        var lengths: [Int] = []
        for rule in rules where rule.isMultiline {
            rule.regex.enumerateMatches(in: source, range: searchRange) { match, _, _ in
                if let r = match?.range {
                    lengths.append(r.length)
                }
            }
        }
        return lengths
    }
}
