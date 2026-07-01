//
//  LanguageServerRegistry.swift
//  Pine
//
//  Phase 1 of LSP support (issue #1010).
//
//  Maps a language id (e.g. "swift", "typescript", "python") to the
//  command + arguments used to spawn its language server, and discovers
//  whether the server binary is actually installed. Discovery reuses the
//  project's `ExternalToolResolver` (PATH + well-known locations) so the
//  behaviour is identical to formatters and validators.
//
//  When a server binary is not installed, the registry reports it as absent
//  and the manager performs a graceful no-op (no crash, no hang) per the
//  acceptance criteria.
//

import Foundation

/// Describes how to launch a single language server.
struct LanguageServerConfig: Sendable, Equatable {
    /// The language id this server serves (e.g. "swift", "typescript").
    let language: String
    /// File extensions (lowercased, without dot) this server handles.
    let fileExtensions: Set<String>
    /// The executable name to resolve on PATH, or an absolute path.
    let command: String
    /// Arguments to pass to the server binary.
    let arguments: [String]

    init(language: String, fileExtensions: Set<String>, command: String, arguments: [String]) {
        self.language = language
        self.fileExtensions = fileExtensions
        self.command = command
        self.arguments = arguments
    }
}

/// Static registry of the language servers Pine knows how to drive.
///
/// Phase 1 targets the three languages from the issue: Swift
/// (`sourcekit-lsp`), TypeScript (`typescript-language-server`), and Python
/// (`pyright`). Adding a new language is purely additive — append a config
/// and the manager picks it up.
nonisolated enum LanguageServerRegistry {

    /// The bundled server definitions. Order does not matter; languages are
    /// keyed by `language` id.
    static let allServers: [LanguageServerConfig] = [
        LanguageServerConfig(
            language: "swift",
            fileExtensions: ["swift"],
            command: "sourcekit-lsp",
            arguments: []
        ),
        LanguageServerConfig(
            language: "typescript",
            // .ts/.tsx handled by the typescript-language-server; .js/.jsx ride along.
            fileExtensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
            command: "typescript-language-server",
            arguments: ["--stdio"]
        ),
        LanguageServerConfig(
            language: "python",
            fileExtensions: ["py", "pyw"],
            command: "pyright-langserver",
            arguments: ["--stdio"]
        )
    ]

    /// Looks up the server config for a language id.
    static func server(forLanguage language: String) -> LanguageServerConfig? {
        allServers.first { $0.language == language }
    }

    /// Looks up the server config for a file extension (lowercased, no dot).
    static func server(forExtension ext: String) -> LanguageServerConfig? {
        allServers.first { $0.fileExtensions.contains(ext.lowercased()) }
    }

    /// Looks up the server config for a file URL, using its path extension.
    static func server(for url: URL) -> LanguageServerConfig? {
        server(forExtension: url.pathExtension)
    }

    /// The list of language ids Pine supports via LSP.
    static var supportedLanguages: [String] {
        allServers.map(\.language)
    }
}

// MARK: - Discovery

/// Resolves whether a language server binary is installed and returns its
/// absolute path. Wraps `ExternalToolResolver` so discovery follows the same
/// PATH + well-known-location logic as formatters/validators.
///
/// `nonisolated` + `Sendable` so it can be used from background tasks.
nonisolated final class LanguageServerResolver: Sendable {

    private let resolver: ExternalToolResolver

    init(resolver: ExternalToolResolver) {
        self.resolver = resolver
    }

    /// Convenience default resolver using the current process PATH.
    static var defaultResolver: LanguageServerResolver {
        LanguageServerResolver(resolver: ExternalToolResolver.fromEnvironment())
    }

    /// Returns the absolute path to the server binary, or `nil` if it is not
    /// installed. Results are cached by the underlying `ExternalToolResolver`.
    func resolvePath(for config: LanguageServerConfig) -> String? {
        resolver.resolve(tool: config.command)
    }

    /// Returns `true` if the server binary for `config` is installed.
    func isInstalled(_ config: LanguageServerConfig) -> Bool {
        resolvePath(for: config) != nil
    }
}
