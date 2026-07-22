//
//  TabAutoSaveTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabAutoSave Tests")
@MainActor
struct TabAutoSaveTests {

    @Test("schedule fires save after delay")
    func scheduleFires() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.1

        var saved = false
        coordinator.schedule(
            isStillDirty: { true },
            saveAction: { saved = true }
        )

        #expect(coordinator.hasScheduledSave == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(saved == true)
        #expect(coordinator.hasScheduledSave == false)
    }

    @Test("schedule skips save when no longer dirty")
    func scheduleSkipsWhenClean() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.1

        var saved = false
        coordinator.schedule(
            isStillDirty: { false },
            saveAction: { saved = true }
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(saved == false)
    }

    @Test("cancel prevents pending save")
    func cancelPreventsSave() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.2

        var saved = false
        coordinator.schedule(
            isStillDirty: { true },
            saveAction: { saved = true }
        )

        coordinator.cancel()
        #expect(coordinator.hasScheduledSave == false)

        try await Task.sleep(for: .milliseconds(400))
        #expect(saved == false)
    }

    @Test("schedule debounces — only last call fires")
    func scheduleDebounces() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.1

        var saveCount = 0
        for _ in 0..<5 {
            coordinator.schedule(
                isStillDirty: { true },
                saveAction: { saveCount += 1 }
            )
        }

        try await Task.sleep(for: .milliseconds(400))
        #expect(saveCount == 1)
    }

    @Test("different tab keys save independently while each key still debounces")
    func keyedSchedulesAreIndependent() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.1
        let firstKey = UUID()
        let secondKey = UUID()
        var firstSaveCount = 0
        var secondSaveCount = 0

        coordinator.schedule(
            for: firstKey,
            isStillDirty: { true },
            saveAction: { firstSaveCount += 1 }
        )
        coordinator.schedule(
            for: secondKey,
            isStillDirty: { true },
            saveAction: { secondSaveCount += 1 }
        )
        coordinator.schedule(
            for: firstKey,
            isStillDirty: { true },
            saveAction: { firstSaveCount += 1 }
        )

        #expect(coordinator.hasScheduledSave(for: firstKey))
        #expect(coordinator.hasScheduledSave(for: secondKey))
        try await Task.sleep(for: .milliseconds(300))

        #expect(firstSaveCount == 1)
        #expect(secondSaveCount == 1)
        #expect(!coordinator.hasScheduledSave)
    }

    @Test("isSaving is true during save action")
    func isSavingDuringAction() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.05

        var wasSavingDuringAction = false
        coordinator.schedule(
            isStillDirty: { true },
            saveAction: { wasSavingDuringAction = coordinator.isSaving }
        )

        try await Task.sleep(for: .milliseconds(200))
        #expect(wasSavingDuringAction == true)
        #expect(coordinator.isSaving == false)
    }

    @Test("schedule catches errors silently")
    func scheduleCatchesErrors() async throws {
        let coordinator = TabAutoSave()
        coordinator.delay = 0.05

        coordinator.schedule(
            isStillDirty: { true },
            saveAction: { throw CocoaError(.fileReadUnknown) }
        )

        try await Task.sleep(for: .milliseconds(200))
        // Should not crash; isSaving resets
        #expect(coordinator.isSaving == false)
    }

    @Test("autoSaveKey has expected value")
    func autoSaveKey() {
        #expect(TabAutoSave.autoSaveKey == "autoSaveEnabled")
    }
}
