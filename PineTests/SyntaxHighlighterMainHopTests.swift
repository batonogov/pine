//
//  SyntaxHighlighterMainHopTests.swift
//  PineTests
//
//  Regression tests for issue #790:
//  `SyntaxHighlighter.applyMatches` crashed with
//  `NSInvalidArgumentException: object cannot be nil` inside
//  `-[__NSDictionaryM setObject:forKey:]` when multiple tabs highlighted
//  concurrently and NSTextStorage was mutated from a background thread.
//
//  The fix routes `applyMatches`/`resetAttributes` through the main thread
//  via `DispatchQueue.main.sync`. These tests exercise the hop from
//  deliberately non-main contexts to verify no crash and correct colors.
//

import Testing
import AppKit
@testable import Pine

/// Reference wrapper so we can mark it `@unchecked Sendable` and send it
/// across task boundaries. Each instance is exclusively owned by one task at
/// a time, so the lack of synchronization on its fields is safe.
///
/// We use a class (not a struct) because Swift 6 does not propagate
/// `@unchecked Sendable` through a struct's non-Sendable stored properties:
/// even if the wrapper type conforms, the compiler still refuses to send its
/// individual `NSTextStorage`/`NSFont` fields across isolation boundaries.
private final class StorageBox: @unchecked Sendable {
    nonisolated(unsafe) let storage: NSTextStorage
    nonisolated(unsafe) let font: NSFont
    init(storage: NSTextStorage, font: NSFont) {
        self.storage = storage
        self.font = font
    }
}

@Suite(.serialized)
struct SyntaxHighlighterMainHopTests {

    nonisolated(unsafe) private static let font =
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let swiftGrammar = Grammar(
        name: "MainHopTestSwift",
        extensions: ["mhtestswift"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
        ]
    )

    /// Grammar that emits a rule for a scope with NO theme color. This is
    /// the code path that historically could have put a nil value into the
    /// attribute dict — verifies the early guard in `computeMatchesWithRules`.
    private let unknownScopeGrammar = Grammar(
        name: "MainHopUnknownScope",
        extensions: ["mhunknown"],
        rules: [
            GrammarRule(pattern: "\\bxyz\\b", scope: "totally.unregistered.scope"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")
        ]
    )

    private func register() {
        SyntaxHighlighter.shared.registerGrammar(swiftGrammar)
        SyntaxHighlighter.shared.registerGrammar(unknownScopeGrammar)
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    // MARK: - 1. highlightAsync from a detached task (non-main executor)

    /// Reproduces the #790 crash shape: `highlightAsync` invoked from outside
    /// the main actor. Pre-fix, the continuation resumed on the generic
    /// executor and mutated NSTextStorage off the main thread — that race is
    /// what surfaced as "object cannot be nil".
    @Test func highlightAsyncFromDetachedTaskDoesNotCrash() async {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let box = StorageBox(
            storage: NSTextStorage(string: "func detached() { /* hi */ }"),
            font: Self.font
        )

        await Task.detached {
            await hl.highlightAsync(
                textStorage: box.storage,
                language: "mhtestswift",
                font: box.font
            )
        }.value

        #expect(foregroundColor(in: box.storage, at: 0) == keywordColor)
    }

    // MARK: - 2. Many detached concurrent highlights on independent storages

    @Test func manyDetachedConcurrentHighlightsComplete() async {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let tabCount = 12

        let boxes: [StorageBox] = (0..<tabCount).map { i in
            StorageBox(
                storage: NSTextStorage(string: "func tab\(i)() { /* c */ }"),
                font: Self.font
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for box in boxes {
                group.addTask {
                    await hl.highlightAsync(
                        textStorage: box.storage,
                        language: "mhtestswift",
                        font: box.font
                    )
                }
            }
        }

        for box in boxes {
            #expect(foregroundColor(in: box.storage, at: 0) == keywordColor)
        }
    }

    // MARK: - 3. Unknown scope never crashes / never writes nil

    /// The early `guard theme.color(for: rule.scope) != nil else { continue }`
    /// in `computeMatchesWithRules` must skip rules whose scope has no
    /// registered theme color. Otherwise a nil could reach `addAttribute`.
    @Test func unknownScopeDoesNotCrashAndDoesNotColorMatchedToken() async {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // `xyz` matches the unknown-scope rule; `func` matches keyword.
        let box = StorageBox(
            storage: NSTextStorage(string: "xyz func"),
            font: Self.font
        )
        await hl.highlightAsync(
            textStorage: box.storage,
            language: "mhunknown",
            font: box.font
        )

        // `func` must still be keyword-colored.
        let funcPos = (box.storage.string as NSString).range(of: "func").location
        #expect(foregroundColor(in: box.storage, at: funcPos) == keywordColor)

        // `xyz` must NOT carry the keyword color and must not have crashed.
        let xyzColor = foregroundColor(in: box.storage, at: 0)
        #expect(xyzColor != keywordColor)
    }

    // MARK: - 4. Stale generation token discards result (from detached task)

    @Test func staleGenerationIsDiscardedFromDetachedTask() async throws {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let lines = (0..<5_000).map { "func line\($0)()" }
        let box = StorageBox(
            storage: NSTextStorage(string: lines.joined(separator: "\n")),
            font: Self.font
        )

        let gen = HighlightGeneration()
        gen.increment()

        let task = Task.detached {
            await hl.highlightAsync(
                textStorage: box.storage,
                language: "mhtestswift",
                font: box.font,
                generation: gen
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        gen.increment() // mark stale
        _ = await task.value

        let deep = box.storage.length - 10
        #expect(foregroundColor(in: box.storage, at: deep) != keywordColor)
    }

    // MARK: - 5. Sync + async on independent storages — no crash

    /// Mirrors the Thread-0-main vs Thread-10-background pattern in the
    /// original crash dump: one storage processed synchronously on main,
    /// another asynchronously off-main, interleaving main-thread work.
    @Test func syncHighlightMixedWithDetachedAsyncHighlight() async {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let asyncBox = StorageBox(
            storage: NSTextStorage(string: "func asyncTab() { /* a */ }"),
            font: Self.font
        )

        let asyncTask = Task.detached {
            for _ in 0..<20 {
                await hl.highlightAsync(
                    textStorage: asyncBox.storage,
                    language: "mhtestswift",
                    font: asyncBox.font
                )
            }
        }

        // On the current (test) task — which is on main — hammer the sync
        // entry point on an independent storage. Pre-fix the combination
        // crashed; post-fix both entry points serialize via main thread.
        let syncStorage = NSTextStorage(string: "func syncTab() { /* s */ }")
        for _ in 0..<20 {
            hl.highlightVisibleRange(
                textStorage: syncStorage,
                visibleCharRange: NSRange(location: 0, length: syncStorage.length),
                language: "mhtestswift",
                font: Self.font
            )
        }
        #expect(foregroundColor(in: syncStorage, at: 0) == keywordColor)

        await asyncTask.value
        #expect(foregroundColor(in: asyncBox.storage, at: 0) == keywordColor)
    }

    // MARK: - 6. highlightEditedAsync + highlightVisibleRangeAsync from detached

    @Test func editedAndViewportAsyncFromDetachedTaskDoNotCrash() async {
        register()
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let lines = (0..<100).map { "func line\($0)() { /* x */ }" }
        let box = StorageBox(
            storage: NSTextStorage(string: lines.joined(separator: "\n")),
            font: Self.font
        )

        await Task.detached {
            await hl.highlightAsync(
                textStorage: box.storage,
                language: "mhtestswift",
                font: box.font
            )
        }.value

        await Task.detached {
            await hl.highlightEditedAsync(
                textStorage: box.storage,
                editedRange: NSRange(location: 0, length: 4),
                language: "mhtestswift",
                font: box.font
            )
        }.value

        await Task.detached {
            await hl.highlightVisibleRangeAsync(
                textStorage: box.storage,
                visibleCharRange: NSRange(location: 0, length: min(500, box.storage.length)),
                language: "mhtestswift",
                font: box.font
            )
        }.value

        #expect(foregroundColor(in: box.storage, at: 0) == keywordColor)
    }
}
