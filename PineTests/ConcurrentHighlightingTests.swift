//
//  ConcurrentHighlightingTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Sendable hand-off wrapper for non-`Sendable` AppKit types used in
/// concurrent-highlighting tests.
///
/// Each `HighlightWorkItem` is created on the main actor and then sent into
/// exactly one detached task via `TaskGroup.addTask`. After the task finishes
/// the main actor reads the storage attributes again. Because:
///
/// 1. `NSFont` (`monospacedSystemFont`) is immutable, and
/// 2. each `NSTextStorage` instance is exclusively owned by one task during
///    highlighting (no two tasks share the same storage),
///
/// this wrapper is safe to mark `@unchecked Sendable` — the unsafety is
/// centralized here and documented, instead of scattered `nonisolated(unsafe)`
/// locals.
private struct HighlightWorkItem: @unchecked Sendable {
    let storage: NSTextStorage
    let font: NSFont
    let language: String

    /// Run a full async highlight on this item's storage. Marked `nonisolated`
    /// so it can be invoked from a `TaskGroup.addTask` closure without
    /// transferring its non-`Sendable` fields across an isolation boundary
    /// at the call site.
    func runFullHighlight(using highlighter: SyntaxHighlighter) async {
        await highlighter.highlightAsync(
            textStorage: storage,
            language: language,
            font: font
        )
    }

    /// Run an async incremental edit highlight on this item's storage.
    func runEditedHighlight(
        using highlighter: SyntaxHighlighter,
        editedRange: NSRange
    ) async {
        await highlighter.highlightEditedAsync(
            textStorage: storage,
            editedRange: editedRange,
            language: language,
            font: font
        )
    }

    /// Run an async viewport highlight on this item's storage.
    func runViewportHighlight(
        using highlighter: SyntaxHighlighter,
        visibleCharRange: NSRange
    ) async {
        await highlighter.highlightVisibleRangeAsync(
            textStorage: storage,
            visibleCharRange: visibleCharRange,
            language: language,
            font: font
        )
    }
}

/// Tests for concurrent syntax highlighting across multiple tabs.
/// Verifies that multiple tabs highlight in parallel and that
/// generation tokens prevent stale results.
@Suite(.serialized)
@MainActor
struct ConcurrentHighlightingTests {

    // NSFont is immutable but not Sendable; safe to share across actors.
    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let swiftGrammar = Grammar(
        name: "ConcTestSwift",
        extensions: ["conctestswift"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
        ]
    )

    private let pythonGrammar = Grammar(
        name: "ConcTestPython",
        extensions: ["conctestpy"],
        rules: [
            GrammarRule(pattern: "#.*$", scope: "comment", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "\\bdef\\b", scope: "keyword"),
            GrammarRule(pattern: "'[^']*'", scope: "string")
        ]
    )

    private func register() {
        SyntaxHighlighter.shared.registerGrammar(swiftGrammar)
        SyntaxHighlighter.shared.registerGrammar(pythonGrammar)
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    // MARK: - Multiple tabs highlight in parallel

    @Test func multipleTabsHighlightConcurrently() async {
        register()

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let tabCount = 10

        // Create work items for multiple "tabs" with different content
        let items: [HighlightWorkItem] = (0..<tabCount).map { index in
            let text = "func tab\(index)() { /* comment */ }"
            return HighlightWorkItem(
                storage: NSTextStorage(string: text),
                font: font,
                language: "conctestswift"
            )
        }

        // Highlight all tabs concurrently. Each task owns one work item.
        await withTaskGroup(of: Int.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    await item.runFullHighlight(using: hl)
                    return index
                }
            }

            // Collect all completed indices
            var completed: Set<Int> = []
            for await index in group {
                completed.insert(index)
            }
            #expect(completed.count == tabCount,
                    "All \(tabCount) tabs must complete highlighting")
        }

        // Verify each tab was highlighted correctly
        for item in items {
            #expect(foregroundColor(in: item.storage, at: 0) == keywordColor,
                    "Each tab must have keyword color at 'func'")
        }
    }

    @Test func mixedLanguageTabsHighlightConcurrently() async {
        register()

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let swiftText = "func hello() { /* comment */ }"
        let pythonText = "def hello(): # comment"

        let swiftStorage = NSTextStorage(string: swiftText)
        let pythonStorage = NSTextStorage(string: pythonText)

        // Highlight both concurrently
        async let swiftHighlight: HighlightMatchResult? = hl.highlightAsync(
            textStorage: swiftStorage,
            language: "conctestswift",
            font: font
        )
        async let pythonHighlight: HighlightMatchResult? = hl.highlightAsync(
            textStorage: pythonStorage,
            language: "conctestpy",
            font: font
        )

        _ = await (swiftHighlight, pythonHighlight)

        // Both should have keyword highlighting
        #expect(foregroundColor(in: swiftStorage, at: 0) == keywordColor,
                "'func' must be keyword-colored")
        #expect(foregroundColor(in: pythonStorage, at: 0) == keywordColor,
                "'def' must be keyword-colored")
    }

    // MARK: - Generation tokens prevent stale results across concurrent tabs

    @Test func generationTokenPreventsStaleResultInConcurrentHighlighting() async throws {
        register()

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Simulate: tab A starts highlighting, then user switches tab,
        // bumping generation. Tab A's results should be discarded.
        let lines = (0..<20_000).map { "func line\($0)()" }
        let bigText = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: bigText)

        let gen = HighlightGeneration()
        gen.increment() // 1

        let task = Task {
            await hl.highlightAsync(
                textStorage: storage,
                language: "conctestswift",
                font: self.font,
                generation: gen
            )
        }

        // Let computation start then invalidate
        try await Task.sleep(for: .milliseconds(1))
        gen.increment() // 2 — stale

        _ = await task.value

        // Result must be discarded — check a line deep in the file
        let checkPos = lineOffset(10_000, in: bigText)
        #expect(foregroundColor(in: storage, at: checkPos) != keywordColor,
                "Stale highlight must not apply after generation bump")
    }

    @Test func perTabGenerationTokensAreIndependent() async {
        register()

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let genA = HighlightGeneration()
        let genB = HighlightGeneration()

        genA.increment() // 1
        genB.increment() // 1

        let storageA = NSTextStorage(string: "func tabA()")
        let storageB = NSTextStorage(string: "func tabB()")

        // Bump genA to simulate tab switch away from tab A
        genA.increment() // 2

        // Tab A highlight should be discarded (stale), tab B should apply
        async let highlightA: HighlightMatchResult? = hl.highlightAsync(
            textStorage: storageA,
            language: "conctestswift",
            font: font,
            generation: genA
        )
        // Immediately bump genA again to ensure staleness
        genA.increment() // 3

        // Tab B uses its own generation — no bump, should apply
        async let highlightB: HighlightMatchResult? = hl.highlightAsync(
            textStorage: storageB,
            language: "conctestswift",
            font: font,
            generation: genB
        )

        _ = await (highlightA, highlightB)

        // Tab B must be highlighted (generation not bumped)
        #expect(foregroundColor(in: storageB, at: 0) == keywordColor,
                "Tab B must apply highlight — its generation was not bumped")
    }

    // MARK: - Concurrent highlightEditedAsync

    @Test func concurrentEditedHighlightingDoesNotCrash() async {
        register()

        let hl = SyntaxHighlighter.shared
        let tabCount = 8

        let items: [HighlightWorkItem] = (0..<tabCount).map { i in
            HighlightWorkItem(
                storage: NSTextStorage(string: "func tab\(i)() { /* comment */ }\nfunc second\(i)()"),
                font: font,
                language: "conctestswift"
            )
        }

        // First do full highlight for each to populate caches
        for item in items {
            await hl.highlightAsync(
                textStorage: item.storage,
                language: item.language,
                font: item.font
            )
        }

        // Now simulate concurrent edits across tabs.
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask {
                    await item.runEditedHighlight(
                        using: hl,
                        editedRange: NSRange(location: 0, length: 4)
                    )
                }
            }
        }

        // No crash = success. Also verify highlighting is intact.
        let keywordColor = hl.theme.color(for: "keyword")
        for item in items {
            #expect(foregroundColor(in: item.storage, at: 0) == keywordColor,
                    "Keyword highlighting must be intact after concurrent edits")
        }
    }

    // MARK: - Concurrent viewport highlighting

    @Test func concurrentViewportHighlightingDoesNotCrash() async {
        register()

        let hl = SyntaxHighlighter.shared
        let tabCount = 6

        let items: [HighlightWorkItem] = (0..<tabCount).map { i in
            let lines = (0..<200).map { "func tab\(i)_line\($0)()" }
            return HighlightWorkItem(
                storage: NSTextStorage(string: lines.joined(separator: "\n")),
                font: font,
                language: "conctestswift"
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for item in items {
                let visibleLength = min(500, item.storage.length)
                group.addTask {
                    await item.runViewportHighlight(
                        using: hl,
                        visibleCharRange: NSRange(location: 0, length: visibleLength)
                    )
                }
            }
        }

        let keywordColor = hl.theme.color(for: "keyword")
        for item in items {
            #expect(foregroundColor(in: item.storage, at: 0) == keywordColor,
                    "Viewport highlighting must apply keyword colors")
        }
    }

    // MARK: - Max concurrency is bounded

    @Test func concurrentHighlightingCompletesWithManyTabs() async {
        register()

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let tabCount = 20

        // Generate tabs with non-trivial content
        let items: [HighlightWorkItem] = (0..<tabCount).map { i in
            let lines = (0..<100).map { "func tab\(i)_line\($0)() { /* comment */ }" }
            return HighlightWorkItem(
                storage: NSTextStorage(string: lines.joined(separator: "\n")),
                font: font,
                language: "conctestswift"
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask {
                    await item.runFullHighlight(using: hl)
                }
            }
        }

        // All must complete and be highlighted
        for item in items {
            #expect(foregroundColor(in: item.storage, at: 0) == keywordColor,
                    "All 20 tabs must be highlighted")
        }
    }

    // MARK: - Helpers

    private func lineOffset(_ line: Int, in text: String) -> Int {
        var offset = 0
        for (i, char) in text.enumerated() {
            if offset == line { return i }
            if char == "\n" { offset += 1 }
        }
        return text.count
    }
}
