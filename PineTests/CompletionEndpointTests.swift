//
//  CompletionEndpointTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("CompletionEndpoint", .serialized)
@MainActor
struct CompletionEndpointTests {

    @Test func returnsEmptyListWithoutAHandler() async {
        let endpoint = CompletionEndpoint.shared
        endpoint.handler = nil

        let result = await endpoint.completion(
            url: URL(fileURLWithPath: "/tmp/example.swift"),
            offset: 4,
            text: "prin"
        )

        #expect(result.isEmpty)
        #expect(!result.isIncomplete)
    }

    @Test func forwardsTheRequestAndReturnsTheHandlerResult() async {
        let endpoint = CompletionEndpoint.shared
        let expectedURL = URL(fileURLWithPath: "/tmp/example.swift")
        let expected = LSPCompletionList(
            items: [LSPCompletionItem(label: "print")],
            isIncomplete: true
        )
        var receivedURL: URL?
        var receivedOffset: Int?
        var receivedText: String?
        endpoint.handler = { url, offset, text in
            receivedURL = url
            receivedOffset = offset
            receivedText = text
            return expected
        }
        defer { endpoint.handler = nil }

        let result = await endpoint.completion(
            url: expectedURL,
            offset: 4,
            text: "prin"
        )

        #expect(result == expected)
        #expect(receivedURL == expectedURL)
        #expect(receivedOffset == 4)
        #expect(receivedText == "prin")
    }

    @Test func evaluatesIdentifierAndTriggerCharacterInsertions() {
        let identifier = CompletionTrigger.evaluate(
            editedRange: NSRange(location: 2, length: 0),
            cursor: 3,
            source: "foo" as NSString
        )
        #expect(identifier.shouldTrigger)
        #expect(!identifier.fireImmediately)
        #expect(identifier.prefix == "foo")

        let trigger = CompletionTrigger.evaluate(
            editedRange: NSRange(location: 6, length: 1),
            cursor: 7,
            source: "object." as NSString
        )
        #expect(trigger.shouldTrigger)
        #expect(trigger.fireImmediately)
        #expect(trigger.prefix.isEmpty)

        let multiCharacterTrigger = CompletionTrigger.evaluate(
            editedRange: NSRange(location: 5, length: 2),
            cursor: 7,
            source: "value->" as NSString
        )
        #expect(multiCharacterTrigger.shouldTrigger)
        #expect(multiCharacterTrigger.fireImmediately)
        #expect(multiCharacterTrigger.prefix.isEmpty)
    }

    @Test func rejectsMissingInvalidAndNonIdentifierEdits() {
        let source = "value " as NSString
        let decisions = [
            CompletionTrigger.evaluate(
                editedRange: nil,
                cursor: source.length,
                source: source
            ),
            CompletionTrigger.evaluate(
                editedRange: NSRange(location: source.length, length: 0),
                cursor: source.length,
                source: source
            ),
            CompletionTrigger.evaluate(
                editedRange: NSRange(location: source.length, length: 2),
                cursor: source.length,
                source: source
            ),
            CompletionTrigger.evaluate(
                editedRange: NSRange(location: source.length - 1, length: 1),
                cursor: source.length,
                source: source
            )
        ]

        for decision in decisions {
            #expect(!decision.shouldTrigger)
            #expect(!decision.fireImmediately)
            #expect(decision.prefix.isEmpty)
        }
    }

    @Test func handlesUnicodeCodeUnitsWithoutInventingACompletion() {
        let source = "😀" as NSString
        let decision = CompletionTrigger.evaluate(
            editedRange: NSRange(location: 0, length: 0),
            cursor: source.length,
            source: source
        )

        #expect(!decision.shouldTrigger)
        #expect(!decision.fireImmediately)
        #expect(decision.prefix.isEmpty)
        #expect(CompletionTrigger.wordPrefix(at: source.length, in: source).isEmpty)
    }

    @Test func extractsAndClampsIdentifierPrefixes() {
        let source = "let foo42_bar" as NSString

        #expect(CompletionTrigger.wordPrefix(at: -10, in: source).isEmpty)
        #expect(CompletionTrigger.wordPrefix(at: 7, in: source) == "foo")
        #expect(CompletionTrigger.wordPrefix(at: 10_000, in: source) == "foo42_bar")
        #expect(CompletionTrigger.wordPrefix(at: 4, in: source).isEmpty)

        #expect(CompletionTrigger.isIdentifierChar("A"))
        #expect(CompletionTrigger.isIdentifierChar("7"))
        #expect(CompletionTrigger.isIdentifierChar("_"))
        #expect(!CompletionTrigger.isIdentifierChar("-"))

        #expect(CompletionTrigger.defaultTriggerCharacters == [".", "->", "::", ":"])
        #expect(CompletionTrigger.defaultTriggerCharsScalar == [".", "-", ">", ":"])
    }

    @Test func buildsInsertionsForPlainTextAndSnippets() {
        let plain = CompletionInsertion.fromSnippet(LSPSnippet("😀 value"))
        #expect(plain == CompletionInsertion(
            text: "😀 value",
            finalCursorOffset: 8
        ))

        let snippet = CompletionInsertion.fromSnippet(
            LSPSnippet("func ${1:name}() {$0}")
        )
        #expect(snippet.text == "func name() {}")
        #expect(snippet.finalCursorOffset == 5)
    }

    @Test func computesClampedIdentifierReplacementRanges() {
        let source = "let foo42_bar." as NSString

        #expect(CompletionInsertion.wordRange(
            endingAt: -1,
            in: source
        ) == NSRange(location: 0, length: 0))
        #expect(CompletionInsertion.wordRange(
            endingAt: 7,
            in: source
        ) == NSRange(location: 4, length: 3))
        #expect(CompletionInsertion.wordRange(
            endingAt: 10_000,
            in: source
        ) == NSRange(location: source.length, length: 0))
        #expect(CompletionInsertion.wordRange(
            endingAt: source.length - 1,
            in: source
        ) == NSRange(location: 4, length: 9))

        let emoji = "😀name" as NSString
        #expect(CompletionInsertion.wordRange(
            endingAt: emoji.length,
            in: emoji
        ) == NSRange(location: 2, length: 4))
    }
}
