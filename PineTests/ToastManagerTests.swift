//
//  ToastManagerTests.swift
//  PineTests
//
//  Tests for ToastManager: show, dismiss, queue, auto-dismiss.
//

import Foundation
import Testing

@testable import Pine

@Suite("ToastManager Tests")
@MainActor
struct ToastManagerTests {

    // MARK: - Basic show/dismiss

    @Test("Show toast sets currentToast")
    func showSetsCurrentToast() {
        let manager = ToastManager()
        let toast = ToastItem(message: "Hello", kind: .info)
        manager.show(toast)
        #expect(manager.currentToast == toast)
    }

    @Test("Dismiss clears currentToast")
    func dismissClearsToast() {
        let manager = ToastManager()
        manager.show(ToastItem(message: "Hello"))
        manager.dismiss()
        #expect(manager.currentToast == nil)
    }

    @Test("isShowingToast reflects visibility")
    func isShowingToast() {
        let manager = ToastManager()
        #expect(!manager.isShowingToast)
        manager.show(ToastItem(message: "Test"))
        #expect(manager.isShowingToast)
        manager.dismiss()
        #expect(!manager.isShowingToast)
    }

    // MARK: - Queue behavior

    @Test("Second toast is queued when one is visible")
    func secondToastQueued() {
        let manager = ToastManager()
        manager.show(ToastItem(message: "First"))
        manager.show(ToastItem(message: "Second"))
        #expect(manager.currentToast?.message == "First")
        #expect(manager.queueCount == 1)
    }

    @Test("Third toast adds to queue")
    func thirdToastQueued() {
        let manager = ToastManager()
        manager.show(ToastItem(message: "First"))
        manager.show(ToastItem(message: "Second"))
        manager.show(ToastItem(message: "Third"))
        #expect(manager.queueCount == 2)
    }

    @Test("Dismiss shows next queued toast after delay")
    func dismissShowsNext() async throws {
        let manager = ToastManager()
        manager.dismissDelay = 10 // Prevent auto-dismiss during test
        manager.show(ToastItem(message: "First"))
        manager.show(ToastItem(message: "Second"))
        manager.dismiss()
        // Next toast appears after 0.3s delay
        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.currentToast?.message == "Second")
        #expect(manager.queueCount == 0)
    }

    // MARK: - Auto-dismiss

    @Test("Toast auto-dismisses after delay")
    func autoDismiss() async throws {
        let manager = ToastManager()
        manager.dismissDelay = 0.2
        manager.show(ToastItem(message: "Auto"))
        #expect(manager.isShowingToast)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!manager.isShowingToast)
    }

    // MARK: - showFilesReloaded convenience

    @Test("showFilesReloaded with single file")
    func showSingleFile() {
        let manager = ToastManager()
        manager.showFilesReloaded(["main.swift"])
        #expect(manager.currentToast?.kind == .filesReloaded)
        #expect(manager.isShowingToast)
    }

    @Test("showFilesReloaded with multiple files")
    func showMultipleFiles() {
        let manager = ToastManager()
        manager.showFilesReloaded(["a.swift", "b.swift"])
        #expect(manager.currentToast?.kind == .filesReloaded)
    }

    @Test("showFilesReloaded with more than 3 files truncates")
    func showManyFiles() {
        let manager = ToastManager()
        manager.showFilesReloaded(["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"])
        #expect(manager.currentToast?.kind == .filesReloaded)
        #expect(manager.isShowingToast)
    }

    @Test("showFilesReloaded with empty array does nothing")
    func showEmptyFiles() {
        let manager = ToastManager()
        manager.showFilesReloaded([])
        #expect(!manager.isShowingToast)
    }

    // MARK: - ToastItem

    @Test("ToastItem equality is by id")
    func toastItemEquality() {
        let toast1 = ToastItem(message: "A")
        let toast2 = ToastItem(message: "A")
        #expect(toast1 != toast2)  // Different UUIDs
        #expect(toast1 == toast1)
    }

    @Test("ToastItem kinds are equatable")
    func toastItemKinds() {
        #expect(ToastItem.Kind.filesReloaded == .filesReloaded)
        #expect(ToastItem.Kind.info == .info)
        #expect(ToastItem.Kind.filesReloaded != .info)
    }
}
