//
//  PaneManagerStaleDropZoneTests.swift
//  PineTests
//
//  Tests for the defensive cleanup of stale drop-zone overlays
//  introduced for issue #710. SwiftUI's DropDelegate occasionally
//  fails to call dropExited/performDrop, leaving the blue overlay
//  visible after a sidebar file drag completes or is cancelled.
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager stale drop-zone cleanup (issue #710)")
@MainActor
struct PaneManagerStaleDropZoneTests {

    // MARK: - hasActiveDropZones

    @Test func hasActiveDropZones_falseByDefault() {
        let manager = PaneManager()
        #expect(manager.hasActiveDropZones == false)
    }

    @Test func hasActiveDropZones_trueWhenLeafZoneSet() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .center
        #expect(manager.hasActiveDropZones == true)
    }

    @Test func hasActiveDropZones_trueWhenRootZoneSet() {
        let manager = PaneManager()
        manager.rootDropZone = .left
        #expect(manager.hasActiveDropZones == true)
    }

    // MARK: - clearAllDropZones

    @Test func clearAllDropZones_clearsLeafAndRoot() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .right
        manager.rootDropZone = .top
        manager.clearAllDropZones()
        #expect(manager.dropZones.isEmpty)
        #expect(manager.rootDropZone == nil)
        #expect(manager.hasActiveDropZones == false)
    }

    @Test func clearLeafDropZones_keepsRootZone() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .right
        manager.rootDropZone = .top
        manager.clearLeafDropZones()
        #expect(manager.dropZones.isEmpty)
        #expect(manager.rootDropZone == .top)
    }

    // MARK: - clearStaleDropZonesIfNoDragActive

    @Test func clearStale_noOpWhenNoOverlays() {
        let manager = PaneManager()
        manager.isMouseButtonPressed = { false }
        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.hasActiveDropZones == false)
    }

    @Test func clearStale_clearsWhenMouseUp() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .center
        manager.rootDropZone = .left
        manager.isMouseButtonPressed = { false }

        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.hasActiveDropZones == false)
    }

    @Test func clearStale_keepsZonesWhenMouseStillPressed() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .center
        manager.isMouseButtonPressed = { true }

        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.dropZones[manager.activePaneID] == .center)
        #expect(manager.hasActiveDropZones == true)
    }

    @Test func clearStale_clearsRootOnlyWhenMouseUp() {
        let manager = PaneManager()
        manager.rootDropZone = .bottom
        manager.isMouseButtonPressed = { false }
        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.rootDropZone == nil)
    }

    // MARK: - Polling timer lifecycle

    @Test func startStaleDropPolling_isIdempotent() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .center
        manager.startStaleDropPollingIfNeeded()
        manager.startStaleDropPollingIfNeeded()
        // Should not crash; second call must be a no-op.
        #expect(manager.hasActiveDropZones == true)
    }

    /// Real timer-driven polling: schedules the timer, waits for it to fire,
    /// and verifies the overlay is cleared once the mouse is no longer down.
    /// Regression coverage for issue #710 — exercises the actual RunLoop tick
    /// rather than just the synchronous helper.
    @Test func startStaleDropPolling_clearsOverlayOnTimerTick() async {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .center
        manager.isMouseButtonPressed = { false }
        #expect(manager.hasActiveDropZones == true)

        manager.startStaleDropPollingIfNeeded()

        // Timer cadence is 0.12s; wait ~250ms to allow at least one fire and
        // the subsequent self-invalidation pass.
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(manager.hasActiveDropZones == false)
    }

    // MARK: - Edge cases

    @Test func clearStale_handlesMultipleLeafPanes() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        guard let secondID = manager.splitPane(firstID, axis: .horizontal) else {
            Issue.record("Failed to split pane")
            return
        }
        manager.dropZones[firstID] = .left
        manager.dropZones[secondID] = .right
        manager.isMouseButtonPressed = { false }

        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.dropZones.isEmpty)
    }

    @Test func clearStale_repeatedCalls_areSafe() {
        let manager = PaneManager()
        manager.dropZones[manager.activePaneID] = .top
        manager.isMouseButtonPressed = { false }
        manager.clearStaleDropZonesIfNoDragActive()
        manager.clearStaleDropZonesIfNoDragActive()
        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.hasActiveDropZones == false)
    }
}
