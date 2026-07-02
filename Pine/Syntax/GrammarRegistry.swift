//
//  GrammarRegistry.swift
//  Pine
//
//  Extracted from SyntaxHighlighter.swift — grammar loading, indexing, and lookup.
//

import AppKit
import Foundation
import os

// MARK: - Grammar Models

/// A single highlighting rule from a JSON grammar file.
nonisolated struct GrammarRule: Codable, Sendable {
    let pattern: String
    let scope: String
    var options: [String]?
}

/// Block comment delimiters (e.g. `/* */`, `<!-- -->`).
nonisolated struct BlockCommentDelimiters: Codable, Sendable {
    let open: String
    let close: String
}

/// A language grammar loaded from a JSON file.
nonisolated struct Grammar: Codable, Sendable {
    let name: String
    let extensions: [String]
    let rules: [GrammarRule]
    var fileNames: [String]?
    var filePatterns: [String]?
    var lineComment: String?
    var blockComment: BlockCommentDelimiters?
}

// MARK: - Theme (scope -> color mapping)

/// Defines colors for each scope. Separate from grammars so themes can be swapped independently.
nonisolated struct Theme {
    let colors: [String: NSColor]

    static let `default` = Theme(colors: [
        "comment": dynamicColor(light: (0.35, 0.55, 0.33), dark: (0.42, 0.68, 0.40)),
        "string": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.89, 0.49, 0.33)),
        "keyword": dynamicColor(light: (0.72, 0.20, 0.45), dark: (0.89, 0.36, 0.60)),
        "number": dynamicColor(light: (0.64, 0.58, 0.20), dark: (0.82, 0.76, 0.42)),
        "type": dynamicColor(light: (0.22, 0.55, 0.60), dark: (0.40, 0.78, 0.82)),
        "attribute": dynamicColor(light: (0.52, 0.35, 0.70), dark: (0.68, 0.51, 0.85)),
        "function": dynamicColor(light: (0.25, 0.42, 0.75), dark: (0.40, 0.60, 0.90)),
        "markdown.heading.1": dynamicColor(light: (0.82, 0.18, 0.22), dark: (0.95, 0.42, 0.45)),
        "markdown.heading.2": dynamicColor(light: (0.78, 0.36, 0.10), dark: (0.96, 0.58, 0.26)),
        "markdown.heading.3": dynamicColor(light: (0.62, 0.46, 0.05), dark: (0.92, 0.78, 0.30)),
        "markdown.heading.4": dynamicColor(light: (0.20, 0.55, 0.30), dark: (0.42, 0.82, 0.52)),
        "markdown.heading.5": dynamicColor(light: (0.18, 0.45, 0.70), dark: (0.42, 0.70, 0.95)),
        "markdown.heading.6": dynamicColor(light: (0.42, 0.32, 0.72), dark: (0.66, 0.58, 0.92)),
        "markdown.bold": dynamicColor(light: (0.72, 0.20, 0.45), dark: (0.92, 0.46, 0.66)),
        "markdown.italic": dynamicColor(light: (0.52, 0.35, 0.70), dark: (0.78, 0.62, 0.92)),
        "markdown.code": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.95, 0.58, 0.40)),
        "markdown.code.fenced": dynamicColor(light: (0.58, 0.22, 0.10), dark: (0.99, 0.72, 0.52)),
        "markdown.code.double": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.95, 0.58, 0.40)),
        "markdown.link": dynamicColor(light: (0.10, 0.45, 0.78), dark: (0.36, 0.68, 0.98)),
        "markdown.image": dynamicColor(light: (0.12, 0.56, 0.62), dark: (0.38, 0.82, 0.88)),
        "markdown.list": dynamicColor(light: (0.22, 0.55, 0.60), dark: (0.46, 0.82, 0.86)),
        "markdown.quote": dynamicColor(light: (0.40, 0.50, 0.42), dark: (0.58, 0.72, 0.60)),
        "markdown.rule": dynamicColor(light: (0.50, 0.50, 0.50), dark: (0.62, 0.62, 0.62)),
    ])

    private static func dynamicColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            } else {
                return NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
            }
        }
    }

    func color(for scope: String) -> NSColor? {
        colors[scope]
    }
}

// MARK: - GrammarRegistry

/// Loads grammar JSON files from the app bundle and provides language lookup
/// by extension, file name, and glob patterns.
///
/// Thread-safe via `NSLock`. Lock is only held during dictionary read/write,
/// never during heavy computation.
nonisolated final class GrammarRegistry: @unchecked Sendable {
    private let lock = NSLock()

    /// Grammars indexed by file extension (lowercased).
    private var grammarsByExtension: [String: Grammar] = [:]

    /// Grammars indexed by exact file name (Dockerfile, Makefile, etc.).
    private var grammarsByFileName: [String: Grammar] = [:]

    /// Grammars with glob patterns for file names.
    private var grammarsByFilePattern: [(pattern: String, grammar: Grammar)] = []

    init() {}

    // MARK: - Loading

    /// Loads all .json grammar files from the Grammars/ subdirectory in the app bundle.
    /// Returns the loaded grammars so callers can compile rules without re-reading files.
    @discardableResult
    func loadGrammarsFromBundle() -> [Grammar] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            Logger.syntax.error("No grammar files found in bundle")
            return []
        }

        let decoder = JSONDecoder()
        var loadedGrammars: [Grammar] = []

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let grammar = try decoder.decode(Grammar.self, from: data)
                registerGrammar(grammar)
                loadedGrammars.append(grammar)
            } catch {
                // Skip non-grammar JSON files (Assets, configs, etc.)
                // but log decoding errors for actual grammar files
                if url.lastPathComponent.hasSuffix(".grammar.json") || url.deletingPathExtension().pathExtension == "grammar" {
                    Logger.syntax.error("Failed to load grammar from \(url.lastPathComponent): \(error)")
                }
                continue
            }
        }

        let count = lock.withLock { Set(grammarsByExtension.values.map(\.name)).count }
        Logger.syntax.info("Loaded \(count) grammars")
        return loadedGrammars
    }

    /// Loads JSON grammar files from a user-supplied directory
    /// (`~/Library/Application Support/Pine/Grammars/` by default), merged
    /// with the bundled grammars. User grammars override bundled ones for
    /// overlapping extensions / file names (issue #1009).
    ///
    /// Malformed or undecodable files are skipped with a log line — a single
    /// bad user file never blocks the rest. Returns the successfully loaded
    /// grammars so callers can compile their rules without re-reading disk.
    @discardableResult
    func loadGrammarsFromDirectory(_ directoryURL: URL) -> [Grammar] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "json" }
        } catch {
            // Directory missing or unreadable — not an error, just no user grammars.
            Logger.syntax.info("No user grammars at \(directoryURL.path)")
            return []
        }

        guard !files.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var loadedGrammars: [Grammar] = []

        for url in files.sorted() { // deterministic order for stable override priority
            do {
                let data = try Data(contentsOf: url)
                let grammar = try decoder.decode(Grammar.self, from: data)
                registerGrammar(grammar)
                loadedGrammars.append(grammar)
            } catch {
                Logger.syntax.error(
                    "Failed to load user grammar \(url.lastPathComponent): \(error)"
                )
            }
        }

        if !loadedGrammars.isEmpty {
            Logger.syntax.info("Loaded \(loadedGrammars.count) user grammars from \(directoryURL.path)")
        }
        return loadedGrammars
    }

    // MARK: - Registration

    /// Registers a grammar and indexes it by extensions, file names, and patterns.
    /// Regex compilation is the caller's responsibility (not handled here).
    func registerGrammar(_ grammar: Grammar) {
        lock.withLock {
            for ext in grammar.extensions {
                grammarsByExtension[ext.lowercased()] = grammar
            }
            if let fileNames = grammar.fileNames {
                for name in fileNames {
                    grammarsByFileName[name] = grammar
                }
            }
            if let patterns = grammar.filePatterns {
                for pattern in patterns {
                    grammarsByFilePattern.append((pattern: pattern, grammar: grammar))
                }
            }
        }
    }

    #if DEBUG
    /// Removes a previously registered grammar (for test cleanup).
    func unregisterGrammar(_ grammar: Grammar) {
        lock.withLock {
            for ext in grammar.extensions where grammarsByExtension[ext.lowercased()]?.name == grammar.name {
                grammarsByExtension.removeValue(forKey: ext.lowercased())
            }
            if let fileNames = grammar.fileNames {
                for name in fileNames where grammarsByFileName[name]?.name == grammar.name {
                    grammarsByFileName.removeValue(forKey: name)
                }
            }
            grammarsByFilePattern.removeAll { $0.grammar.name == grammar.name }
        }
    }
    #endif

    // MARK: - Lookup

    /// Resolves a grammar by language extension and optional file name.
    /// Priority: exact file name > extension > glob pattern.
    func resolveGrammar(language: String, fileName: String?) -> Grammar? {
        lock.withLock {
            if let name = fileName, let g = grammarsByFileName[name] {
                return g
            } else if let g = grammarsByExtension[language.lowercased()] {
                return g
            } else if let name = fileName, let g = matchFilePatternUnlocked(name) {
                return g
            } else {
                return nil
            }
        }
    }

    /// Returns the line comment prefix for a file extension.
    func lineComment(forExtension ext: String) -> String? {
        lock.withLock { grammarsByExtension[ext.lowercased()]?.lineComment }
    }

    /// Returns the line comment prefix for an exact file name.
    func lineComment(forFileName name: String) -> String? {
        lock.withLock { grammarsByFileName[name]?.lineComment ?? matchFilePatternUnlocked(name)?.lineComment }
    }

    /// Resolved comment style for a file — line comment preferred, block comment as fallback.
    enum CommentStyle {
        case line(String)
        case block(open: String, close: String)
    }

    /// Returns the preferred comment style, resolving by exact name first, then extension.
    func commentStyle(forExtension ext: String?, fileName: String?) -> CommentStyle? {
        let grammar: Grammar? = lock.withLock {
            if let name = fileName, let g = grammarsByFileName[name] {
                return g
            } else if let ext, let g = grammarsByExtension[ext.lowercased()] {
                return g
            }
            return nil
        }
        guard let grammar else { return nil }

        if let lc = grammar.lineComment {
            return .line(lc)
        } else if let bc = grammar.blockComment {
            return .block(open: bc.open, close: bc.close)
        }
        return nil
    }

    /// Common language aliases used in fenced code blocks.
    private let languageAliases: [String: String] = [
        "bash": "bash",
        "sh": "sh",
        "zsh": "zsh",
        "shell": "sh",
        "javascript": "js",
        "typescript": "ts",
        "python": "py",
        "ruby": "rb",
        "rust": "rs",
        "golang": "go",
        "csharp": "cs",
        "c++": "cpp",
        "objective-c": "m",
        "yml": "yaml",
        "dockerfile": "dockerfile",
        "makefile": "mk",
        "hcl": "hcl",
        "terraform": "tf",
    ]

    /// Resolves a language tag to a grammar.
    /// Tries tag as-is first, then falls back to the alias map.
    func resolveGrammarByTag(_ tag: String) -> Grammar? {
        let lowered = tag.lowercased()
        if let grammar = resolveGrammar(language: lowered, fileName: nil) {
            return grammar
        }
        if let mapped = languageAliases[lowered] {
            return resolveGrammar(language: mapped, fileName: nil)
        }
        return nil
    }

    // MARK: - Private

    /// Matches file name against glob patterns. Must be called while lock is held.
    private func matchFilePatternUnlocked(_ fileName: String) -> Grammar? {
        for entry in grammarsByFilePattern where globMatch(pattern: entry.pattern, string: fileName) {
            return entry.grammar
        }
        return nil
    }

    /// Simple glob matching: `*` matches any non-empty character sequence.
    private func globMatch(pattern: String, string: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regexPattern = "^" + escaped + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return false }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.firstMatch(in: string, range: range) != nil
    }
}
