//
//  StructuralLanguageRegistry.swift
//  Pine
//
//  Derived structural-language capability reporting for #1008.
//

import Foundation

/// Capabilities derived from Pine's actual provider and server registries.
/// No language total or parallel extension list is maintained here.
nonisolated struct StructuralLanguageCapabilities:
    Equatable,
    Sendable {

    let hasConfiguredLSPServer: Bool
    let hasRegexSymbols: Bool
    let hasBoundedBracketMatching: Bool
}

nonisolated enum StructuralLanguageRegistry {
    static func capabilities(
        for url: URL
    ) -> StructuralLanguageCapabilities {
        StructuralLanguageCapabilities(
            hasConfiguredLSPServer:
                LanguageServerRegistry.server(for: url) != nil,
            hasRegexSymbols: SymbolParser.supports(
                fileExtension: url.pathExtension
            ),
            hasBoundedBracketMatching: true
        )
    }

    /// Language identifiers come directly from launchable server configs.
    static var lspLanguages: [String] {
        LanguageServerRegistry.supportedLanguages.sorted()
    }
}
