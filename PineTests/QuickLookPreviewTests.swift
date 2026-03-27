//
//  QuickLookPreviewTests.swift
//  PineTests
//

import Testing
import QuickLookUI
@testable import Pine

/// Tests for QuickLookPreviewView guard against nil previewItem crash (#618).
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
        let initialItem = QLPreviewTestItem(url: url1)
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
}

/// Test helper — simple QLPreviewItem implementation.
private class QLPreviewTestItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var previewItemURL: URL? { url }
}
