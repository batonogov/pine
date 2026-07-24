//
//  StructuralBracketProviderTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Structural Bracket Provider Tests")
struct StructuralBracketProviderTests {
    @Test("Matches nested brackets from an immutable snapshot")
    func matchesNestedBrackets() {
        let provider = BoundedBracketProvider()
        let document = snapshot("outer(inner())")
        let request = BracketSnapshot(
            document: document,
            cursorPosition: 6,
            skipRanges: []
        )

        #expect(
            provider.highlight(for: request)
                == .matched(BracketMatch(opener: 5, closer: 13))
        )
        #expect(request.document.revision == DocumentRevision(7))
    }

    @Test("Structural comment and string ranges are ignored")
    func ignoresSyntaxRanges() {
        let provider = BoundedBracketProvider()
        let text = "(\"ignored )\" real)"
        let ignored = NSRange(location: 1, length: 11)
        let request = BracketSnapshot(
            document: snapshot(text),
            cursorPosition: 1,
            skipRanges: [ignored]
        )

        #expect(
            provider.highlight(for: request)
                == .matched(BracketMatch(opener: 0, closer: 17))
        )
    }

    @Test("Bracket inside a skipped range has no highlight")
    func skippedAdjacentBracketIsIgnored() {
        let provider = BoundedBracketProvider()
        let request = BracketSnapshot(
            document: snapshot("\"(\""),
            cursorPosition: 2,
            skipRanges: [NSRange(location: 0, length: 3)]
        )

        #expect(provider.highlight(for: request) == nil)
    }

    @Test("Malformed source reports an unmatched bracket")
    func malformedSourceRemainsUseful() {
        let provider = BoundedBracketProvider()
        let request = BracketSnapshot(
            document: snapshot("func broken("),
            cursorPosition: 12,
            skipRanges: []
        )

        #expect(
            provider.highlight(for: request)
                == .unmatched(position: 11)
        )
    }

    @Test("UTF-16 cursor positions remain stable around emoji and CJK")
    func unicodePositions() {
        let provider = BoundedBracketProvider()
        let text = "😀日本(foo)"
        let request = BracketSnapshot(
            document: snapshot(text),
            cursorPosition: 5,
            skipRanges: []
        )

        #expect(
            provider.highlight(for: request)
                == .matched(BracketMatch(opener: 4, closer: 8))
        )
    }

    @Test("Out-of-bounds cursor fails closed")
    func outOfBoundsCursor() {
        let provider = BoundedBracketProvider()
        let document = snapshot("()")

        #expect(
            provider.highlight(
                for: BracketSnapshot(
                    document: document,
                    cursorPosition: -1,
                    skipRanges: []
                )
            ) == nil
        )
        #expect(
            provider.highlight(
                for: BracketSnapshot(
                    document: document,
                    cursorPosition: 3,
                    skipRanges: []
                )
            ) == nil
        )
    }

    @Test("Language capabilities derive from provider and server registries")
    func derivedLanguageCapabilities() {
        let swift = StructuralLanguageRegistry.capabilities(
            for: URL(fileURLWithPath: "/project/App.swift")
        )
        let unsupported = StructuralLanguageRegistry.capabilities(
            for: URL(fileURLWithPath: "/project/file.unknown")
        )

        #expect(swift.hasConfiguredLSPServer)
        #expect(swift.hasRegexSymbols)
        #expect(swift.hasBoundedBracketMatching)
        #expect(!unsupported.hasConfiguredLSPServer)
        #expect(!unsupported.hasRegexSymbols)
        #expect(unsupported.hasBoundedBracketMatching)
        #expect(
            StructuralLanguageRegistry.lspLanguages
                == LanguageServerRegistry.supportedLanguages.sorted()
        )
    }

    private func snapshot(_ text: String) -> DocumentSnapshot {
        DocumentSnapshot(
            uri: "file:///test.unknown",
            text: text,
            revision: DocumentRevision(7)
        )
    }
}
