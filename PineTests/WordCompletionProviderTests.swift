//
//  WordCompletionProviderTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct WordCompletionProviderTests {

    init() {
        // Clear cache before each test for isolation
        WordCompletionProvider.clearCache()
    }

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
        for lineNum in 0..<10_000 {
            lines.append("func method_\(lineNum)(param_\(lineNum): Int) -> String")
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

    // MARK: - Unicode support

    @Test func cyrillicWords() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "let переменная = значение\nfunc вычислить() {}",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.contains("переменная"))
        #expect(words.contains("значение"))
        #expect(words.contains("вычислить"))
    }

    @Test func cjkWords() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "let 変数名 = 値設定\nfunc 計算する() {}",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.contains("変数名"))
        #expect(words.contains("値設定"))
        #expect(words.contains("計算する"))
    }

    @Test func germanUmlauts() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "let größe = überprüfung\nvar Ärger = Öffnung",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.contains("größe"))
        #expect(words.contains("überprüfung"))
        #expect(words.contains("Ärger"))
        #expect(words.contains("Öffnung"))
    }

    @Test func mixedUnicodeAndAsciiIdentifiers() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "let café_count = наш_проект123",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.contains("café_count"))
        #expect(words.contains("наш_проект123"))
    }

    // MARK: - Edge cases

    @Test func emptyFileReturnsEmpty() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/empty.swift"),
            content: "",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.isEmpty)
    }

    @Test func whitespaceOnlyFileReturnsEmpty() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/whitespace.swift"),
            content: "   \n\t\t\n   \n",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.isEmpty)
    }

    @Test func differentCasesOfSameWordPreserved() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "myVar MyVar MYVAR myvar",
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // All case variants should be separate entries
        #expect(words.contains("myVar"))
        #expect(words.contains("MyVar"))
        #expect(words.contains("MYVAR"))
        #expect(words.contains("myvar"))
        #expect(words.count == 4)
    }

    @Test func veryLongWord() {
        let longWord = String(repeating: "a", count: 5000)
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: longWord,
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words.count == 1)
        #expect(words.first == longWord)
    }

    @Test func singleWordRepeatedManyTimes() {
        let content = Array(repeating: "repeated", count: 1000).joined(separator: " ")
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: content,
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // Should deduplicate — only one entry
        #expect(words.count == 1)
        #expect(words.first == "repeated")
    }

    // MARK: - Caching

    @Test func cacheReturnsConsistentResults() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "hello world test",
            savedContent: ""
        )
        let words1 = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        let words2 = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words1 == words2)
    }

    @Test func cacheInvalidatesOnContentChange() {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "hello world",
            savedContent: ""
        )
        let words1 = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words1.contains("hello"))
        #expect(!words1.contains("newword"))

        // Mutate content — contentVersion increments
        tab.content = "hello newword"
        let words2 = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        #expect(words2.contains("newword"))
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

    @Test func emptyPrefixReturnsAllUpToLimit() {
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

    // MARK: - Completion limit

    @Test func completionsLimitedToMax() {
        // Create more words than maxCompletions, all matching prefix "word"
        var words: [String] = []
        for num in 0..<200 {
            words.append("word\(num)")
        }
        let results = WordCompletionProvider.completions(for: "word", in: words)
        #expect(results.count == WordCompletionProvider.maxCompletions)
    }

    @Test func completionsUnderLimitReturnsAll() {
        let words = ["word1", "word2", "word3"]
        let results = WordCompletionProvider.completions(for: "word", in: words)
        #expect(results.count == 3)
    }

    // MARK: - Project isolation (С3)

    @Test func differentProjectIDsIsolateCache() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/shared.swift"),
            content: "func sharedWord() {}",
            savedContent: ""
        )
        // Collect for project A
        let wordsA = WordCompletionProvider.collectWords(
            from: [tab], excluding: "", projectID: "/projectA"
        )
        #expect(wordsA.contains("sharedWord"))

        // Collect for project B with a different tab
        let tabB = EditorTab(
            url: URL(fileURLWithPath: "/other.swift"),
            content: "var uniqueWord = true",
            savedContent: ""
        )
        let wordsB = WordCompletionProvider.collectWords(
            from: [tabB], excluding: "", projectID: "/projectB"
        )
        #expect(wordsB.contains("uniqueWord"))
        #expect(!wordsB.contains("sharedWord"))
    }

    // MARK: - maxScanSize (С2)

    @Test func largeFileScansOnlyMaxScanSize() {
        // Create content larger than maxScanSize
        // Each word "word_XXXX " is ~11 chars, so 500_000 / 11 ≈ 45_000 words fit in scan window
        let wordBeforeCutoff = "beforeCutoff"
        let wordAfterCutoff = "afterCutoff_unique_marker"
        // Build: fill up to maxScanSize with repeated short words, then add unique word after
        let filler = String(repeating: "fillerword ", count: WordCompletionProvider.maxScanSize / 11)
        let content = filler + " " + wordAfterCutoff + " " + wordBeforeCutoff
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/huge.swift"),
            content: content,
            savedContent: ""
        )
        let words = WordCompletionProvider.collectWords(from: [tab], excluding: "")
        // The filler word should be found
        #expect(words.contains("fillerword"))
        // Words beyond maxScanSize should be excluded
        // (afterCutoff_unique_marker is placed after the scan window)
        #expect(!words.contains(wordAfterCutoff))
    }

    // MARK: - Thread safety (С4)

    @Test func concurrentCollectWordsDoesNotCrash() async {
        // Create several tabs
        let tabs = (0..<10).map { idx in
            EditorTab(
                url: URL(fileURLWithPath: "/file\(idx).swift"),
                content: "func method\(idx)() { let value\(idx) = \(idx) }",
                savedContent: ""
            )
        }

        // Run collectWords concurrently from multiple threads
        await withTaskGroup(of: [String].self) { group in
            for iteration in 0..<20 {
                group.addTask {
                    WordCompletionProvider.collectWords(
                        from: tabs,
                        excluding: "method\(iteration % 10)",
                        projectID: "/testProject"
                    )
                }
            }
            for await result in group {
                // Just verify it returned without crashing and has some words
                #expect(!result.isEmpty)
            }
        }
    }

    @Test func concurrentCacheAccessDoesNotCrash() async {
        // Stress test: concurrent reads and writes to the cache
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/stress.swift"),
            content: "alpha beta gamma delta epsilon",
            savedContent: ""
        )

        await withTaskGroup(of: Void.self) { group in
            // Concurrent collectors
            for _ in 0..<10 {
                group.addTask {
                    _ = WordCompletionProvider.collectWords(
                        from: [tab], excluding: "", projectID: "/stress"
                    )
                }
            }
            // Concurrent cache clears
            for _ in 0..<5 {
                group.addTask {
                    WordCompletionProvider.clearCache()
                }
            }
            // More concurrent collectors
            for _ in 0..<10 {
                group.addTask {
                    _ = WordCompletionProvider.collectWords(
                        from: [tab], excluding: "", projectID: "/stress"
                    )
                }
            }
        }
        // If we got here without a crash, the test passes
    }

    // MARK: - completionsFromCache (async path)

    @Test func completionsFromCacheReturnsCachedResults() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/test.swift"),
            content: "func hello world test",
            savedContent: ""
        )
        // Prime the cache via collectWords
        _ = WordCompletionProvider.collectWords(from: [tab], excluding: "", projectID: "/test")

        // Now use completionsFromCache — should return from cache immediately
        let snapshot = WordCompletionProvider.TabSnapshot(
            id: tab.id,
            content: tab.content,
            contentVersion: tab.contentVersion,
            kind: tab.kind
        )
        let results = WordCompletionProvider.completionsFromCache(
            tabSnapshots: [snapshot],
            excluding: "",
            projectID: "/test"
        )
        #expect(results.contains("hello"))
        #expect(results.contains("world"))
        #expect(results.contains("func"))
        #expect(results.contains("test"))
    }

    @Test func completionsFromCacheReturnsEmptyOnFirstCallForNewProject() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/new.swift"),
            content: "func brand_new_word() {}",
            savedContent: ""
        )
        let snapshot = WordCompletionProvider.TabSnapshot(
            id: tab.id,
            content: tab.content,
            contentVersion: tab.contentVersion,
            kind: tab.kind
        )
        // First call with no cache — returns empty (or last known) and schedules background scan
        let results = WordCompletionProvider.completionsFromCache(
            tabSnapshots: [snapshot],
            excluding: "",
            projectID: "/brand_new_project"
        )
        // May be empty on first call since cache is cold
        // This is expected behavior — next call will have results
        #expect(results.isEmpty || results.contains("brand_new_word"))
    }
}
