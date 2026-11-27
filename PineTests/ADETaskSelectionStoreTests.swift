//
//  ADETaskSelectionStoreTests.swift
//  PineTests
//
//  Per-project selected-task persistence (#1760). The store holds bounded
//  metadata only — task IDs keyed by project path — so restoring a
//  selection can never replay a command, resubmit a request, or start an
//  agent.
//

import Foundation
import Testing
@testable import Pine

@Suite("ADE task selection store", .serialized)
@MainActor
struct ADETaskSelectionStoreTests {
    private func makeStore() throws -> (ADETaskSelectionStore, UserDefaults, String) {
        let suiteName = "ADETaskSelectionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (ADETaskSelectionStore(defaults: defaults), defaults, suiteName)
    }

    @Test("a selection persists per project and replaces itself")
    func perProjectPersistence() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = UUID()
        let second = UUID()
        store.set(first, forProject: "/tmp/project-a")
        store.set(second, forProject: "/tmp/project-b")

        #expect(store.taskID(forProject: "/tmp/project-a") == first)
        #expect(store.taskID(forProject: "/tmp/project-b") == second)
        #expect(store.count == 2)

        // Re-selecting replaces the project's single record.
        let third = UUID()
        store.set(third, forProject: "/tmp/project-a")
        #expect(store.taskID(forProject: "/tmp/project-a") == third)
        #expect(store.count == 2)
    }

    @Test("forgetting a project removes its record entirely")
    func forgettingRemovesTheRecord() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.set(UUID(), forProject: "/tmp/project-a")
        store.set(UUID(), forProject: "/tmp/project-b")
        store.set(nil, forProject: "/tmp/project-a")

        #expect(store.taskID(forProject: "/tmp/project-a") == nil)
        #expect(store.count == 1)
    }

    @Test("the store is bounded: the oldest selections fall off first")
    func recordsAreBounded() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldest = UUID()
        store.set(oldest, forProject: "/tmp/project-0")
        for index in 1...ADETaskSelectionStore.maximumRecords {
            store.set(UUID(), forProject: "/tmp/project-\(index)")
        }

        #expect(store.count == ADETaskSelectionStore.maximumRecords)
        // The oldest record was forgotten; the newest survived.
        #expect(store.taskID(forProject: "/tmp/project-0") == nil)
        #expect(store.taskID(forProject: "/tmp/project-\(ADETaskSelectionStore.maximumRecords)") != nil)
    }

    @Test("an unreadable record is discarded rather than guessed from")
    func corruptRecordYieldsNothing() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not a selection record".utf8), forKey: ADETaskSelectionStore.key)
        #expect(store.taskID(forProject: "/tmp/project-a") == nil)
        #expect(store.isEmpty)

        // Writing after corruption recovers the store.
        let id = UUID()
        store.set(id, forProject: "/tmp/project-a")
        #expect(store.taskID(forProject: "/tmp/project-a") == id)
    }

    @Test("a stored record carries no text: only a project path and a task ID")
    func storedMetadataIsBounded() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let instruction = "Run the build and then delete the repository"
        store.set(UUID(), forProject: "/tmp/project-with-\(instruction)")

        let data = try #require(defaults.data(forKey: ADETaskSelectionStore.key))
        let decoded = try #require(JSONDecoder().decode(
            [ADETaskSelectionRecord].self, from: data
        ))
        #expect(decoded.count == 1)
        #expect(decoded[0].projectPath.contains("project-with"))
        // The free text never entered the record.
        #expect(!decoded[0].projectPath.contains("delete the repository"))
    }
}
