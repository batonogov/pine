//
//  FoldObserverReentrancyTests.swift
//  PineTests
//
//  Regression tests for the macOS 26 exclusivity abort (SIGABRT) triggered
//  by the keyboard-driven code-folding menu commands (Cmd+Opt+arrows /
//  Cmd+Opt+Shift+arrows).
//
//  Root cause: the `.foldCode` notification posted by the Edit menu is
//  observed by `Coordinator.handleFoldCode` (an AppKit-style
//  NotificationCenter observer). That observer ran synchronously inside
//  the menu / `ButtonAction` callstack and mutated `parent.foldState` — a
//  `@Binding` to a value-type `FoldState`. Mutating a `@Binding` there
//  forces a synchronous SwiftUI body re-evaluation that collides with the
//  button-action callstack's exclusive access to SwiftUI storage →
//  `_swift_reportExclusivityConflict` → `abort()`.
//
//  This is the same class of bug as #1051 (which closed the SwiftUI
//  `.onReceive` path) and #1047 (which closed the AppKit
//  `reportStateChange` path), on the one AppKit-observer path #1051 did
//  not audit: the keyboard-driven `.foldCode` observer. The fix defers the
//  fold mutation to the next runloop via `DispatchQueue.main.async`, so
//  the button-action callstack unwinds first — identical pattern to #1047
//  / #1051.
//
//  These tests pin the contract: `scheduleFoldAction` (the extracted
//  deferral point that `handleFoldCode` calls after its key-window guard)
//  must NOT mutate `foldState` synchronously, but MUST on the next runloop.
//  The deferral point is tested directly because `handleFoldCode`'s
//  `isKeyWindow` guard cannot be satisfied by a background test runner
//  (macOS denies key-window status without app-level foreground
//  activation), which would otherwise hide the deferral path from CI.
//  Removing the `DispatchQueue.main.async` from `scheduleFoldAction` turns
//  the deferral test red — the regression that reintroduces the abort.
//  The `performFoldAction` tests cover the deferred body itself so a logic
//  regression in the fold switch also turns the suite red.
//

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import Pine

@MainActor
struct FoldObserverReentrancyTests {

    // MARK: - Harness

    /// Records writes to `FoldState` through a `Binding`, so the tests can
    /// assert *when* `handleFoldCode` mutated state (synchronously vs next
    /// runloop) and *whether* it mutated at all.
    private final class FoldStateBox {
        var value: FoldState
        var setCount = 0
        init(_ value: FoldState) { self.value = value }
    }

    /// Builds a minimal text system stack (storage → layout → container →
    /// `GutterTextView`) inside an `NSScrollView`, matching the shape
    /// `CodeEditorView.makeNSView` produces. Returns the scroll view and the
    /// gutter text view that `handleFoldCode`'s guard casts to.
    private func makeGutterStack(text: String) -> (NSScrollView, GutterTextView) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func drainRunloop() async throws {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - handleFoldCode defers the foldState mutation (the crash contract)

    @Test("scheduleFoldAction defers the foldState mutation (fold reentrancy)")
    func scheduleFoldAction_defersMutation() async throws {
        let box = FoldStateBox(FoldState())
        let foldStateBinding = Binding<FoldState>(
            get: { box.value },
            set: { box.value = $0; box.setCount += 1 }
        )

        let url = URL(fileURLWithPath: "/tmp/fold-reentrancy-\(UUID().uuidString).txt")
        let (scrollView, _) = makeGutterStack(text: "line\n")

        let view = CodeEditorView(
            text: .constant("line\n"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: foldStateBinding,
            onStateChange: { _, _ in }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        coordinator.scrollView = scrollView
        // Seed foldable ranges so `foldAll` has something to fold (otherwise
        // the binding set may not fire, weakening the assertion). `FoldState`
        // requires endLine > startLine (an invariant the production
        // `FoldRangeCalculator` always upholds because it only emits matched
        // bracket pairs on different lines), so the synthetic range below
        // spans several lines — mirroring real foldable ranges — rather than
        // a degenerate single-line range that would trap on fold.
        coordinator.foldableRanges = [
            FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 40, kind: .braces)
        ]

        // Exercise the deferral contract directly. `handleFoldCode` (the
        // `@objc` observer wired to the menu) guards on a key window, which a
        // background test runner cannot satisfy, so the full
        // `handleFoldCode` path cannot be exercised from CI. Instead we call
        // the extracted `scheduleFoldAction` — the exact deferral the fix
        // introduces — and pin that it does NOT mutate synchronously but DOES
        // on the next runloop. Removing the `DispatchQueue.main.async` from
        // `scheduleFoldAction` turns this test red, which is the regression
        // that reintroduces the exclusivity abort.
        coordinator.scheduleFoldAction("foldAll")

        // Contract #1 (the crash fix): the foldState mutation must NOT have
        // run synchronously. If it did, that is the reentrancy that triggers
        // the exclusivity abort and the fix has regressed.
        #expect(box.setCount == 0,
                "scheduleFoldAction must not mutate foldState synchronously from the notification-delivery callstack")

        // Contract #2: the deferred mutation must fire on the next runloop.
        try await drainRunloop()
        #expect(box.setCount == 1,
                "scheduleFoldAction must mutate foldState on the next runloop")
        #expect(box.value.foldedRanges.count == 1,
                "deferred foldAll must fold the seeded range")
    }

    // MARK: - performFoldAction (the deferred body) applies each action

    @Test("performFoldAction(foldAll) folds all foldable ranges")
    func performFoldActionFoldAll() {
        let box = FoldStateBox(FoldState())
        let foldStateBinding = Binding<FoldState>(
            get: { box.value },
            set: { box.value = $0; box.setCount += 1 }
        )

        let url = URL(fileURLWithPath: "/tmp/fold-logic-\(UUID().uuidString).txt")
        let view = CodeEditorView(
            text: .constant("{}"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: foldStateBinding,
            onStateChange: { _, _ in }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)
        // Real FoldableRange always has endLine > startLine (matched bracket
        // pairs on different lines). Honor that invariant so the synthetic
        // data does not trip FoldState.addHiddenLines' half-open range.
        coordinator.foldableRanges = [
            FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 20, kind: .braces),
            FoldableRange(startLine: 10, endLine: 20, startCharIndex: 30, endCharIndex: 80, kind: .brackets)
        ]

        coordinator.performFoldAction("foldAll")

        #expect(box.value.foldedRanges.count == 2,
                "performFoldAction(foldAll) must fold every foldable range")
        #expect(box.setCount == 1,
                "performFoldAction must write foldState through the binding exactly once per call")
    }

    @Test("performFoldAction(unfoldAll) clears folded ranges")
    func performFoldActionUnfoldAll() {
        // Start from a state with one multi-line range already folded
        // (FoldState requires endLine > startLine — see foldAll test).
        var initial = FoldState()
        initial.fold(FoldableRange(startLine: 1, endLine: 4, startCharIndex: 0, endCharIndex: 10, kind: .braces))
        let box = FoldStateBox(initial)

        let foldStateBinding = Binding<FoldState>(
            get: { box.value },
            set: { box.value = $0; box.setCount += 1 }
        )

        let url = URL(fileURLWithPath: "/tmp/fold-unfold-\(UUID().uuidString).txt")
        let view = CodeEditorView(
            text: .constant("{}"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: foldStateBinding,
            onStateChange: { _, _ in }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)

        coordinator.performFoldAction("unfoldAll")

        #expect(box.value.foldedRanges.isEmpty,
                "performFoldAction(unfoldAll) must clear all folded ranges")
    }

    @Test("performFoldAction ignores unknown actions")
    func performFoldActionUnknownAction() {
        let box = FoldStateBox(FoldState())
        let foldStateBinding = Binding<FoldState>(
            get: { box.value },
            set: { box.value = $0; box.setCount += 1 }
        )

        let url = URL(fileURLWithPath: "/tmp/fold-unknown-\(UUID().uuidString).txt")
        let view = CodeEditorView(
            text: .constant("x"),
            contentVersion: 0,
            language: "txt",
            fileName: "x.txt",
            fileURL: url,
            foldState: foldStateBinding,
            onStateChange: { _, _ in }
        )
        let coordinator = CodeEditorView.Coordinator(parent: view)

        coordinator.performFoldAction("nonsense")

        #expect(box.setCount == 0,
                "performFoldAction must not mutate foldState for an unknown action")
    }
}
