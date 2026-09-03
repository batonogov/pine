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
///
/// Light values must clear WCAG AA (4.5:1) against the light editor
/// background — `ThemeContrastTests` enforces this per scope (#1540).
/// The ten scopes named in #1540 were darkened from their original values
/// to clear the threshold; hue direction is preserved.
nonisolated struct Theme {
    let colors: [String: NSColor]

    static let `default` = Theme(colors: [
        "comment": dynamicColor(light: (0.32, 0.50, 0.30), dark: (0.42, 0.68, 0.40)),
        "string": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.89, 0.49, 0.33)),
        "keyword": dynamicColor(light: (0.72, 0.20, 0.45), dark: (0.89, 0.36, 0.60)),
        "number": dynamicColor(light: (0.51, 0.46, 0.16), dark: (0.82, 0.76, 0.42)),
        "type": dynamicColor(light: (0.20, 0.49, 0.54), dark: (0.40, 0.78, 0.82)),
        "attribute": dynamicColor(light: (0.52, 0.35, 0.70), dark: (0.68, 0.51, 0.85)),
        "function": dynamicColor(light: (0.25, 0.42, 0.75), dark: (0.40, 0.60, 0.90)),
        "markdown.heading.1": dynamicColor(light: (0.82, 0.18, 0.22), dark: (0.95, 0.42, 0.45)),
        "markdown.heading.2": dynamicColor(light: (0.74, 0.34, 0.10), dark: (0.96, 0.58, 0.26)),
        "markdown.heading.3": dynamicColor(light: (0.58, 0.43, 0.05), dark: (0.92, 0.78, 0.30)),
        "markdown.heading.4": dynamicColor(light: (0.19, 0.51, 0.28), dark: (0.42, 0.82, 0.52)),
        "markdown.heading.5": dynamicColor(light: (0.18, 0.45, 0.70), dark: (0.42, 0.70, 0.95)),
        "markdown.heading.6": dynamicColor(light: (0.42, 0.32, 0.72), dark: (0.66, 0.58, 0.92)),
        "markdown.bold": dynamicColor(light: (0.72, 0.20, 0.45), dark: (0.92, 0.46, 0.66)),
        "markdown.italic": dynamicColor(light: (0.52, 0.35, 0.70), dark: (0.78, 0.62, 0.92)),
        "markdown.code": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.95, 0.58, 0.40)),
        "markdown.code.fenced": dynamicColor(light: (0.58, 0.22, 0.10), dark: (0.99, 0.72, 0.52)),
        "markdown.code.double": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.95, 0.58, 0.40)),
        "markdown.link": dynamicColor(light: (0.10, 0.45, 0.78), dark: (0.36, 0.68, 0.98)),
        "markdown.image": dynamicColor(light: (0.11, 0.50, 0.56), dark: (0.38, 0.82, 0.88)),
        "markdown.list": dynamicColor(light: (0.20, 0.49, 0.54), dark: (0.46, 0.82, 0.86)),
        "markdown.quote": dynamicColor(light: (0.39, 0.48, 0.41), dark: (0.58, 0.72, 0.60)),
        "markdown.rule": dynamicColor(light: (0.45, 0.45, 0.45), dark: (0.62, 0.62, 0.62)),
    ])

    private static func dynamicColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        // All four variants — including the WCAG-high-contrast ones, which
        // require an iterative search — are computed once, here, while the
        // palette table is built. The provider below only picks a ready
        // NSColor, so no contrast search runs per color resolution (the
        // minimap resolves theme colors per segment per frame, #1540).
        func solid(_ rgb: (Double, Double, Double)) -> NSColor {
            NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        let lightBase = (Double(light.0), Double(light.1), Double(light.2))
        let darkBase = (Double(dark.0), Double(dark.1), Double(dark.2))
        let lightColor = solid(lightBase)
        let darkColor = solid(darkBase)
        let lightHighContrastColor = solid(
            increasedContrastVariant(of: lightBase, isDarkAppearance: false)
        )
        let darkHighContrastColor = solid(
            increasedContrastVariant(of: darkBase, isDarkAppearance: true)
        )
        return NSColor(name: nil) { appearance in
            switch Self.paletteVariant(for: appearance) {
            case .light:
                return lightColor
            case .dark:
                return darkColor
            case .lightHighContrast:
                return lightHighContrastColor
            case .darkHighContrast:
                return darkHighContrastColor
            }
        }
    }

    /// The four palette entries a dynamic theme colour can resolve to.
    enum PaletteVariant: Hashable {
        case light, dark
        case lightHighContrast, darkHighContrast
    }

    /// Maps an appearance to its palette variant. High-contrast appearances
    /// are recognized through the dedicated accessibility appearance names:
    /// `NSAppearance(named: .accessibilityHighContrastAqua)` canonicalizes
    /// itself to plain `.aqua`, so a high-contrast appearance cannot be
    /// fabricated in a unit test — `resolvedVariant` covers that logic
    /// purely instead (#1540).
    nonisolated static func paletteVariant(for appearance: NSAppearance) -> PaletteVariant {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua,
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        switch match {
        case .darkAqua:
            return .dark
        case .accessibilityHighContrastAqua:
            return .lightHighContrast
        case .accessibilityHighContrastDarkAqua:
            return .darkHighContrast
        default:
            return .light
        }
    }

    // MARK: - Contrast (Increase Contrast support, #1540)

    /// Backgrounds the increased-contrast variants are tuned against. The
    /// editor paints syntax on `NSColor.textBackgroundColor` — white in light
    /// mode, #1E1E1E under dark aqua.
    nonisolated static let increasedContrastBackgrounds = (
        light: (1.0, 1.0, 1.0),
        dark: (30.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0)
    )

    /// WCAG contrast-ratio target of the increased-contrast variants (AAA).
    nonisolated static let increasedContrastTarget = 7.0

    /// The palette entry an appearance resolves to. Pure so the appearance /
    /// contrast selection is unit-testable without fabricating a
    /// high-contrast `NSAppearance` (AppKit exposes no public initializer).
    nonisolated static func resolvedVariant(
        light: (Double, Double, Double),
        dark: (Double, Double, Double),
        isDarkAppearance: Bool,
        increasedContrast: Bool
    ) -> (Double, Double, Double) {
        let base = isDarkAppearance ? dark : light
        guard increasedContrast else { return base }
        return increasedContrastVariant(of: base, isDarkAppearance: isDarkAppearance)
    }

    /// Scales a colour toward black (light mode) or white (dark mode) along
    /// the line to the reference background until the WCAG contrast reaches
    /// `target`. Hue direction is preserved; a colour that already clears
    /// the target is returned unchanged.
    nonisolated static func increasedContrastVariant(
        of rgb: (Double, Double, Double),
        isDarkAppearance: Bool,
        target: Double = Theme.increasedContrastTarget
    ) -> (Double, Double, Double) {
        let background = isDarkAppearance
            ? increasedContrastBackgrounds.dark
            : increasedContrastBackgrounds.light
        let pole = isDarkAppearance
            ? (1.0, 1.0, 1.0)
            : (0.0, 0.0, 0.0)
        if contrastRatio(rgb, background) >= target { return rgb }
        var step = 0.0
        while step < 1.0 {
            step += 0.01
            let candidate = (
                rgb.0 + (pole.0 - rgb.0) * step,
                rgb.1 + (pole.1 - rgb.1) * step,
                rgb.2 + (pole.2 - rgb.2) * step
            )
            if contrastRatio(candidate, background) >= target { return candidate }
        }
        return pole
    }

    /// WCAG 2.x relative luminance of an sRGB colour with components in 0...1.
    nonisolated static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    /// WCAG 2.x contrast ratio (1...21) between two sRGB colours.
    nonisolated static func contrastRatio(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double)
    ) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
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

        for url in files.sorted(by: { $0.path < $1.path }) { // deterministic order
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
