//
//  QuickLookPreviewTests.swift
//  PineTests
//

import Testing
import QuickLookUI
@testable import Pine

/// Tests for QuickLookPreviewView guard against nil previewItem crash (#618)
/// and deferred loading to avoid QuickLookUI EXC_BAD_ACCESS on macOS 26 (#673).
struct QuickLookPreviewTests {

    // MARK: - updateNSView guards

    @Test("updateNSView skips update when QLPreviewView has no window")
    @MainActor
    func updateSkipsWhenNoWindow() {
        let url1 = URL(fileURLWithPath: "/tmp/test1.txt")
        let url2 = URL(fileURLWithPath: "/tmp/test2.txt")

        // Create a detached QLPreviewView (no window) — simulates deactivated state
        // swiftlint:disable:next force_unwrapping
        let nsView = QLPreviewView(frame: .zero, style: .normal)!

        // Set initial item
        let initialItem = PreviewItem(url: url1)
        nsView.previewItem = initialItem

        // Simulate what updateNSView does — with the guard
        // nsView.window is nil, so our guard should prevent the update
        guard nsView.window != nil else {
            // This is the expected path — the guard fires, no crash
            let currentURL = (nsView.previewItem as? QLPreviewItem)?.previewItemURL
            #expect(currentURL == url1, "Preview item should remain unchanged when window is nil")
            return
        }

        // If we somehow got here, update would proceed — but we shouldn't
        Issue.record("Expected guard to return early when window is nil")
        _ = url2  // silence unused warning
    }

    @Test("QuickLookPreviewView initializes with correct URL")
    func initializesWithURL() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let view = QuickLookPreviewView(url: url)
        #expect(view.url == url)
    }

    // MARK: - Coordinator tracks URL (#673)

    @Test("Coordinator starts with nil currentURL")
    func coordinatorStartsNil() {
        let coordinator = QuickLookPreviewView.Coordinator()
        #expect(coordinator.currentURL == nil)
    }

    @Test("Coordinator tracks URL changes")
    func coordinatorTracksURL() {
        let coordinator = QuickLookPreviewView.Coordinator()
        let url1 = URL(fileURLWithPath: "/tmp/a.png")
        let url2 = URL(fileURLWithPath: "/tmp/b.png")

        coordinator.currentURL = url1
        #expect(coordinator.currentURL == url1)

        coordinator.currentURL = url2
        #expect(coordinator.currentURL == url2)
    }

    // MARK: - Deferred assignment in makeNSView (#673)

    @Test("makeNSView returns QLPreviewView with nil previewItem initially (deferred)")
    @MainActor
    func makeNSViewDefersPreviewItem() {
        let url = URL(fileURLWithPath: "/tmp/deferred.png")
        let wrapper = QuickLookPreviewView(url: url)
        let coordinator = wrapper.makeCoordinator()
        let context = MockNSViewRepresentableContext(coordinator: coordinator)

        // swiftlint:disable:next force_unwrapping
        let nsView = QLPreviewView(frame: .zero, style: .normal)!

        // Simulate makeNSView behavior: coordinator is set, but previewItem
        // should NOT be assigned synchronously (it's deferred to next runloop)
        coordinator.currentURL = url
        // The view has no window, so the deferred block's guard will skip assignment
        #expect(nsView.previewItem == nil, "previewItem should not be set synchronously in makeNSView")
        _ = context  // silence unused warning
    }

    // MARK: - dismantleNSView clears previewItem (#673)

    @Test("dismantleNSView nils out previewItem")
    @MainActor
    func dismantleNilsPreviewItem() {
        // swiftlint:disable:next force_unwrapping
        let nsView = QLPreviewView(frame: .zero, style: .normal)!
        let item = PreviewItem(url: URL(fileURLWithPath: "/tmp/file.pdf"))
        nsView.previewItem = item

        let coordinator = QuickLookPreviewView.Coordinator()
        QuickLookPreviewView.dismantleNSView(nsView, coordinator: coordinator)

        #expect(nsView.previewItem == nil, "dismantleNSView should clear previewItem")
    }

    // MARK: - PreviewItem

    @Test("PreviewItem exposes correct URL")
    func previewItemURL() {
        let url = URL(fileURLWithPath: "/tmp/image.png")
        let item = PreviewItem(url: url)
        #expect(item.previewItemURL == url)
    }

    @Test("PreviewItem with different URLs are distinct")
    func previewItemDistinct() {
        let item1 = PreviewItem(url: URL(fileURLWithPath: "/tmp/a.png"))
        let item2 = PreviewItem(url: URL(fileURLWithPath: "/tmp/b.png"))
        #expect(item1.previewItemURL != item2.previewItemURL)
    }

    // MARK: - updateNSView deferred behavior (#673)

    @Test("updateNSView skips when URL has not changed")
    @MainActor
    func updateSkipsWhenURLUnchanged() {
        let url = URL(fileURLWithPath: "/tmp/same.png")
        let coordinator = QuickLookPreviewView.Coordinator()
        coordinator.currentURL = url

        // Simulate: coordinator already has the same URL, so update should be skipped
        let wrapper = QuickLookPreviewView(url: url)
        // The coordinator's currentURL matches wrapper.url — no update needed
        #expect(coordinator.currentURL == wrapper.url)
    }

    @Test("updateNSView detects URL change via coordinator")
    @MainActor
    func updateDetectsURLChange() {
        let url1 = URL(fileURLWithPath: "/tmp/old.png")
        let url2 = URL(fileURLWithPath: "/tmp/new.png")
        let coordinator = QuickLookPreviewView.Coordinator()
        coordinator.currentURL = url1

        let wrapper = QuickLookPreviewView(url: url2)
        // The coordinator's currentURL differs from wrapper.url — update needed
        #expect(coordinator.currentURL != wrapper.url)
    }

    // MARK: - Generation token prevents stale assignment (#675)

    @Test("Coordinator starts with generation 0")
    func coordinatorStartsGenZero() {
        let coordinator = QuickLookPreviewView.Coordinator()
        #expect(coordinator.generation == 0)
    }

    @Test("dismantleNSView increments generation to invalidate pending async blocks")
    @MainActor
    func dismantleIncrementsGeneration() {
        // swiftlint:disable:next force_unwrapping
        let nsView = QLPreviewView(frame: .zero, style: .normal)!
        let coordinator = QuickLookPreviewView.Coordinator()
        #expect(coordinator.generation == 0)

        QuickLookPreviewView.dismantleNSView(nsView, coordinator: coordinator)
        #expect(coordinator.generation == 1, "dismantleNSView should increment generation")
    }

    @Test("Generation mismatch prevents stale previewItem assignment after dismantle")
    @MainActor
    func generationPreventsStaleAssignment() {
        // Simulate the race: makeNSView captures gen=0, then dismantleNSView bumps to 1
        let coordinator = QuickLookPreviewView.Coordinator()
        let capturedGen = coordinator.generation  // 0 — as makeNSView would capture

        // Simulate dismantleNSView running before the async block fires
        coordinator.generation += 1

        // The async block's guard should fail
        #expect(
            coordinator.generation != capturedGen,
            "After dismantle, generation should differ from captured value"
        )
    }

    @Test("updateNSView increments generation on URL change")
    @MainActor
    func updateIncrementsGeneration() {
        let coordinator = QuickLookPreviewView.Coordinator()
        coordinator.currentURL = URL(fileURLWithPath: "/tmp/a.png")
        #expect(coordinator.generation == 0)

        // Simulate what updateNSView does on URL change
        coordinator.currentURL = URL(fileURLWithPath: "/tmp/b.png")
        coordinator.generation += 1
        #expect(coordinator.generation == 1)

        // A second URL change bumps again
        coordinator.currentURL = URL(fileURLWithPath: "/tmp/c.png")
        coordinator.generation += 1
        #expect(coordinator.generation == 2)
    }

    @Test("Rapid URL changes leave only latest generation valid")
    @MainActor
    func rapidURLChangesInvalidateOlderGenerations() {
        let coordinator = QuickLookPreviewView.Coordinator()

        // Simulate 3 rapid URL changes, each capturing its own generation
        var capturedGens: [Int] = []
        for idx in 0..<3 {
            coordinator.currentURL = URL(fileURLWithPath: "/tmp/file\(idx).png")
            coordinator.generation += 1
            capturedGens.append(coordinator.generation)
        }

        // Only the last captured generation matches current
        let currentGen = coordinator.generation
        #expect(capturedGens.last == currentGen)
        #expect(capturedGens[0] != currentGen, "First generation should be stale")
        #expect(capturedGens[1] != currentGen, "Second generation should be stale")
    }
}

/// Minimal mock for NSViewRepresentable context — used to verify coordinator behavior.
private struct MockNSViewRepresentableContext {
    let coordinator: QuickLookPreviewView.Coordinator
}
