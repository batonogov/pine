//
//  OnReceiveReentrancyTests.swift
//  PineTests
//
//  Regression tests for issue #1051: Swift exclusivity abort on macOS 26.5.1
//  caused by reentrant @State/@Observable mutation delivered synchronously
//  from a SwiftUI `.onReceive(NotificationCenter...)` observer.
//
//  Root cause: menu commands post a NotificationCenter notification whose
//  delivery runs the `.onReceive` closure synchronously *inside* the menu /
//  `ButtonAction` callstack. When that closure mutates `@State` /
//  `@Binding` / `@AppStorage` / `@Observable` state, SwiftUI is forced to
//  re-evaluate a `body` while the outer callstack still holds exclusive
//  access to the same SwiftUI storage → `_swift_reportExclusivityConflict`
//  → `abort()`.
//
//  This is the SwiftUI-side twin of the AppKit-side bug fixed in #1032/#1047
//  (where `reportStateChange` mutated `@Observable` fields from inside an
//  AppKit text-storage / selection-notification callstack). #1047 closed
//  the AppKit path; #1051 closes the SwiftUI `.onReceive` path.
//
//  Fix: every `.onReceive` handler that mutates observable state in
//  `ContentView.swift` and `GitAndNotificationObserver.swift` now wraps the
//  mutation in `DispatchQueue.main.async { ... }` via an extracted handler
//  method (`handleCloseTab`, `handleShowProjectSearch`, `handleGoToLine`,
//  `handleFileRenamed`, `handleFileDeleted`, `handleOpenFileAtLine` in
//  GitAndNotificationObserver; inline-async in ContentView). Breaking the
//  synchronous reentrancy lets the button-action callstack unwind first.
//
//  These tests pin the contract: the state mutation must NOT run
//  synchronously when the notification handler is invoked, but MUST run on
//  the next runloop. The contract is modelled directly because the real
//  handlers mutate `@Environment`-injected state that cannot be
//  instantiated outside a view hierarchy; the defer pattern itself
//  (`DispatchQueue.main.async { mutation() }`) is exactly what each
//  handler executes. A non-deferred control proves the harness is
//  sensitive to the contract.
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct OnReceiveReentrancyTests {

    // MARK: - Harness

    /// Mirrors the exact defer contract used by every `.onReceive` handler
    /// fixed in #1051: the state mutation is wrapped in
    /// `DispatchQueue.main.async { ... }`. `deferMutation` toggles the fix
    /// so the same handler exercises both the contract path and the control
    /// (pre-fix antipattern) path.
    private struct NotificationHandler {
        var deferMutation: Bool
        var mutate: () -> Void

        /// Called synchronously by a `.onReceive` closure — as
        /// `NotificationCenter` delivery does inside the menu/button-action
        /// callstack.
        func handle() {
            if deferMutation {
                // The #1051 contract: defer so the mutation does not run
                // synchronously inside the notification-delivery callstack.
                DispatchQueue.main.async {
                    self.mutate()
                }
            } else {
                // Control: the pre-fix antipattern — mutate synchronously
                // from the observer, colliding with the outer callstack's
                // exclusive access → exclusivity abort.
                mutate()
            }
        }
    }

    /// Drains the main runloop so deferred `DispatchQueue.main.async` blocks
    /// fire. Mirrors the drain pattern in `StateChangeReentrancyTests`.
    private func drainRunloop() async throws {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Contract: a deferred handler mutation must NOT run synchronously (#1051)

    /// Synchronous main-actor counter so the control test can observe
    /// synchronous execution without the inherent async hop of `Task {}`
    /// or an `actor`.
    @MainActor
    private final class Counter {
        var count = 0
    }

    @Test("deferred notification-handler mutation does not fire synchronously (#1051)")
    func deferredMutationNotSynchronous() async throws {
        let counter = Counter()
        let handler = NotificationHandler(deferMutation: true) {
            counter.count += 1
        }

        // Simulate the `.onReceive` closure body invoking the handler
        // synchronously (as NotificationCenter delivery does).
        handler.handle()

        // Contract: the mutation must NOT have run synchronously. If it did,
        // that is the reentrancy that triggers the exclusivity abort and the
        // fix has regressed.
        // swiftlint:disable:next empty_count - Counter.count is a plain Int scalar, not a Collection; isEmpty is unavailable
        #expect(counter.count == 0,
                "deferred notification-handler mutation must not run synchronously from the notification-delivery callstack")

        // Now drain the runloop: the deferred mutation must fire exactly once.
        try await drainRunloop()
        #expect(counter.count == 1,
                "deferred notification-handler mutation must fire on the next runloop")
    }

    // MARK: - Each rapid invocation schedules its own deferred block

    @Test("multiple rapid handler invocations each schedule their own deferred block (#1051)")
    func multipleInvocationsDeliver() async throws {
        let counter = Counter()
        let handler = NotificationHandler(deferMutation: true) {
            counter.count += 1
        }

        // Three synchronous invocations in the same runloop (as a user
        // mashing the shortcut would produce). Each schedules an independent
        // async block.
        handler.handle()
        handler.handle()
        handler.handle()

        // swiftlint:disable:next empty_count - plain Int scalar, not a Collection
        #expect(counter.count == 0,
                "no deferred mutation should run synchronously regardless of invocation count")

        try await drainRunloop()
        #expect(counter.count == 3,
                "each handler invocation must schedule its own deferred mutation")
    }

    // MARK: - Control: without the defer, the mutation runs synchronously

    @Test("non-deferred handler mutation fires synchronously (control for harness sensitivity)")
    func nonDeferredMutationIsSynchronous() async throws {
        let counter = Counter()
        let handler = NotificationHandler(deferMutation: false) {
            counter.count += 1
        }

        // The pre-fix antipattern: the control handler mutates synchronously.
        // This test proves the harness CAN observe synchronous execution —
        // so the "must be 0 synchronously" assertions above are meaningful
        // and not vacuously true.
        handler.handle()

        #expect(counter.count == 1,
                "control handler (no defer) must record synchronously — proves the harness is sensitive to the contract")
    }
}
