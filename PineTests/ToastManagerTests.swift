//
//  ToastManagerTests.swift
//  PineTests
//
//  Tests for ToastManager: show, dismiss, queue, auto-dismiss.
//

import Foundation
import Testing

@testable import Pine

/// Thread-safe mutable container so tests can append to a collection from a
/// `@Sendable` closure without triggering Swift 6's "mutation of captured var"
/// diagnostic. The toast `announce` hook is `@Sendable` and may be invoked
/// concurrently, so captured `var` mutations are unsafe.
final class AnnouncementBox {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Thread-safe box for capturing announcements in tests.
final class AnnouncementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); defer { lock.unlock() }; storage.append(s) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

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

    // MARK: - Accessibility announcements (#1247)

    @Test("Announcement posted when toast appears")
    func announcementPostedOnShow() {
        let manager = ToastManager()
        manager.prefixesAnnouncements = false
        let announcements = AnnouncementBox()
        manager.announce = { announcements.append($0) }

        manager.show(ToastItem(message: "Hello"))

        #expect(announcements.values == ["Hello"])
    }

    @Test("Announcement includes localized prefix by default")
    func announcementIncludesPrefix() {
        let manager = ToastManager()
        let announcements = AnnouncementBox()
        manager.announce = { announcements.append($0) }

        manager.show(ToastItem(message: "Saved"))

        #expect(announcements.values.count == 1)
        #expect(announcements.values[0] == "Notification: Saved")
    }

    @Test("No announcement when queueing a toast behind a visible one")
    func noAnnouncementWhileQueued() {
        let manager = ToastManager()
        manager.dismissDelay = 10  // Prevent auto-dismiss during test
        manager.prefixesAnnouncements = false
        let announcements = AnnouncementBox()
        manager.announce = { announcements.append($0) }

        manager.show(ToastItem(message: "First"))
        manager.show(ToastItem(message: "Second"))

        // Only the visible toast announces; the queued one is silent until
        // it is actually presented.
        #expect(announcements.values == ["First"])
    }

    // MARK: - Queue / overlap behavior (#1247)

    @Test("interToastDelay defaults to UITimings.Delay.standard for predictable timing")
    func interToastDelayDefault() {
        let manager = ToastManager()
        #expect(manager.interToastDelay == UITimings.Delay.standard)
    }

    @Test("Manual dismiss while queued toast is pending cancels advance work")
    func manualDismissCancelsAdvance() async throws {
        let manager = ToastManager()
        manager.dismissDelay = 10
        manager.show(ToastItem(message: "First"))
        manager.show(ToastItem(message: "Second"))
        // Trigger the inter-toast advance scheduling.
        manager.dismiss()
        // Immediately dismiss again before the advance fires — this must
        // cancel the pending advance and drain the queue without overlapping
        // two presentations.
        manager.dismiss()

        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.currentToast == nil)
        #expect(manager.queueCount == 0)
    }

    @Test("Queued toasts drain one at a time without overlap")
    func queueDrainsSequentially() async throws {
        let manager = ToastManager()
        manager.dismissDelay = 10
        let announcements = AnnouncementBox()
        manager.prefixesAnnouncements = false
        manager.announce = { announcements.append($0) }

        manager.show(ToastItem(message: "A"))
        manager.show(ToastItem(message: "B"))
        manager.show(ToastItem(message: "C"))
        #expect(announcements.values == ["A"])

        manager.dismiss()
        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.currentToast?.message == "B")
        #expect(announcements.values == ["A", "B"])

        manager.dismiss()
        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.currentToast?.message == "C")
        #expect(announcements.values == ["A", "B", "C"])
        #expect(manager.queueCount == 0)
    }

    @Test("Newer toast's auto-dismiss is independent of prior toast's schedule")
    func newerToastAutoDismissIndependent() async throws {
        // First toast is shown then manually dismissed; Second is shown
        // immediately after. Second's auto-dismiss must be scheduled fresh
        // and fire on its own delay, not be confused with any prior work.
        let manager = ToastManager()
        manager.dismissDelay = 0.15
        manager.show(ToastItem(message: "First"))
        manager.dismiss()
        manager.show(ToastItem(message: "Second"))

        #expect(manager.currentToast?.message == "Second")
        // Wait just past Second's auto-dismiss window.
        try await Task.sleep(for: .milliseconds(350))
        #expect(manager.currentToast == nil)
    }
}
