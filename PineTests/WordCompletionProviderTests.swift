//
//  WordCompletionProviderTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct WordCompletionProviderTests {

    // MARK: - collectWords

    @Test func emptyTabsReturnsEmpty() {
        let words = WordCompletionProvider.collectWords(from: [], excluding: "")
        #expect(words.isEmpty)
    }

    @Test func singleTabReturnsUniqueWords() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "let hello = world\nlet hello = swift",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // "let" has 3 chars, "hello" appears twice, "world" once, "swift" once
        #expect(words.contains("hello"))
        #expect(words.contains("world"))
        #expect(words.contains("swift"))
        #expect(words.contains("let"))
        // No duplicates
        #expect(words.filter { $0 == "hello" }.count == 1)
    }

    @Test func multipleTabsCollectFromAll() {
        let tab1 = EditorTab(
            url: URL(fileURLWithPath: "/a.swift"),
            content: "func alpha() {}",
            savedContent: ""
        )
        let tab2 = EditorTab(
            url: URL(fileURLWithPath: "/b.swift"),
            content: "var beta = 42",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab1, tab2], excluding: "")
        #expect(words.contains("func"))
        #expect(words.contains("alpha"))
        #expect(words.contains("var"))
        #expect(words.contains("beta"))
    }

    @Test func wordsUnderThreeCharsExcluded() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "a ab abc abcd",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(!words.contains("a"))
        #expect(!words.contains("ab"))
        #expect(words.contains("abc"))
        #expect(words.contains("abcd"))
    }

    @Test func currentWordExcluded() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "hello world",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "hello")
        #expect(!words.contains("hello"))
        #expect(words.contains("world"))
    }

    @Test func currentWordExclusionIsCaseInsensitive() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "Hello world",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "hello")
        #expect(!words.contains("Hello"))
        #expect(words.contains("world"))
    }

    @Test func duplicatesAcrossTabsDeduplicated() {
        let tab1 = EditorTab(
            url: URL(fileURLWithPath: "/a.swift"),
            content: "import Foundation",
            savedContent: ""
        )
        let tab2 = EditorTab(
            url: URL(fileURLWithPath: "/b.swift"),
            content: "import Foundation",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab1, tab2], excluding: "")
        #expect(words.filter { $0 == "import" }.count == 1)
        #expect(words.filter { $0 == "Foundation" }.count == 1)
    }

    @Test func specialCharactersUnderscoresAndNumbers() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "_privateVar my_func var123 __init__",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.contains("_privateVar"))
        #expect(words.contains("my_func"))
        #expect(words.contains("var123"))
        #expect(words.contains("__init__"))
    }

    @Test func sortedByFrequencyDescending() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "aaa bbb aaa ccc aaa bbb",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // aaa: 3, bbb: 2, ccc: 1
        #expect(words.first == "aaa")
        guard let bbbIdx = words.firstIndex(of: "bbb"),
              let cccIdx = words.firstIndex(of: "ccc") else {
            Issue.record("Expected bbb and ccc in words")
            return
        }
        #expect(bbbIdx < cccIdx)
    }

    @Test func previewTabsSkipped() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/image.png"),
            kind: .preview
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.isEmpty)
    }

    @Test func largeTextPerformance() {
        // Build a large text with many words
        var lines: [String] = []
        for i in 0..<10_000 {
            lines.append("func method_\(i)(param_\(i): Int) -> String")
        }
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/large.swift"),
            content: lines.joined(separator: "\n"),
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // Should complete without issues and contain expected words
        #expect(words.contains("func"))
        #expect(words.contains("Int"))
        #expect(words.contains("String"))
        #expect(words.count > 100)
    }

    // MARK: - completions (prefix matching)

    @Test func prefixMatchingWorks() {
        let words = ["hello", "help", "world", "Heaven"]
        let results = WordCompletionProvider.completions(for: "hel", in: words)
        #expect(results.contains("hello"))
        #expect(results.contains("help"))
        #expect(!results.contains("world"))
    }

    @Test func prefixMatchingIsCaseInsensitive() {
        let words = ["Hello", "HELP", "world"]
        let results = WordCompletionProvider.completions(for: "hel", in: words)
        #expect(results.contains("Hello"))
        #expect(results.contains("HELP"))
        #expect(!results.contains("world"))
    }

    @Test func emptyPrefixReturnsAll() {
        let words = ["alpha", "beta", "gamma"]
        let results = WordCompletionProvider.completions(for: "", in: words)
        #expect(results.count == 3)
    }

    @Test func noMatchReturnsEmpty() {
        let words = ["alpha", "beta"]
        let results = WordCompletionProvider.completions(for: "xyz", in: words)
        #expect(results.isEmpty)
    }

    @Test func preservesInputOrder() {
        let words = ["zebra", "apple", "mango"]
        let results = WordCompletionProvider.completions(for: "", in: words)
        #expect(results == ["zebra", "apple", "mango"])
    }
}
