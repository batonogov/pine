//
//  ProgressIndicatorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct ProgressIndicatorTests {

    // MARK: - Initial state

    @Test func initialStateIsIdle() {
        let tracker = ProgressTracker()
        #expect(!tracker.isLoading)
        #expect(tracker.message == "")
        #expect(tracker.activeOperationCount == 0)
    }

    // MARK: - Single operation

    @Test func startOperationSetsLoading() {
        let tracker = ProgressTracker()
        let id = tracker.beginOperation("Loading project…")
        #expect(tracker.isLoading)
        #expect(tracker.message == "Loading project…")
        #expect(tracker.activeOperationCount == 1)
        // Suppress unused variable warning
        _ = id
    }

    @Test func endOperationClearsLoading() {
        let tracker = ProgressTracker()
        let id = tracker.beginOperation("Loading project…")
        tracker.endOperation(id)
        #expect(!tracker.isLoading)
        #expect(tracker.message == "")
        #expect(tracker.activeOperationCount == 0)
    }

    // MARK: - Concurrent operations

    @Test func concurrentOperationsDoNotConflict() {
        let tracker = ProgressTracker()
        let id1 = tracker.beginOperation("Loading files…")
        let id2 = tracker.beginOperation("Git status…")

        #expect(tracker.isLoading)
        #expect(tracker.activeOperationCount == 2)
        // Most recent operation message is shown
        #expect(tracker.message == "Git status…")

        tracker.endOperation(id2)
        #expect(tracker.isLoading)
        #expect(tracker.activeOperationCount == 1)
        #expect(tracker.message == "Loading files…")

        tracker.endOperation(id1)
        #expect(!tracker.isLoading)
        #expect(tracker.message == "")
        #expect(tracker.activeOperationCount == 0)
    }

    @Test func endingAlreadyEndedOperationIsNoOp() {
        let tracker = ProgressTracker()
        let id = tracker.beginOperation("Test")
        tracker.endOperation(id)
        tracker.endOperation(id) // second call is no-op
        #expect(!tracker.isLoading)
        #expect(tracker.activeOperationCount == 0)
    }

    @Test func endingUnknownOperationIsNoOp() {
        let tracker = ProgressTracker()
        tracker.endOperation(UUID()) // unknown ID
        #expect(!tracker.isLoading)
        #expect(tracker.activeOperationCount == 0)
    }

    // MARK: - Message ordering

    @Test func messageShowsMostRecentOperation() {
        let tracker = ProgressTracker()
        let id1 = tracker.beginOperation("First")
        _ = tracker.beginOperation("Second")
        _ = tracker.beginOperation("Third")

        #expect(tracker.message == "Third")

        // End first — message stays at most recent
        tracker.endOperation(id1)
        #expect(tracker.message == "Third")
    }

    @Test func messageFallsBackWhenLatestEnds() {
        let tracker = ProgressTracker()
        _ = tracker.beginOperation("First")
        let id2 = tracker.beginOperation("Second")

        tracker.endOperation(id2)
        #expect(tracker.message == "First")
    }
}
