//
//  TabAutoSave.swift
//  Pine
//
//  Extracted from TabManager.swift — debounced auto-save scheduling.
//

import Foundation

/// Manages debounced auto-save scheduling for editor tabs.
/// Tracks pending work per tab and fires save callbacks after a delay.
@MainActor
final class TabAutoSave {
    /// UserDefaults key for the auto-save toggle.
    nonisolated static let autoSaveKey = "autoSaveEnabled"

    /// Auto-save delay in seconds.
    var delay: TimeInterval = 1.0

    /// Whether auto-save is currently in progress (for UI indicator).
    var isSaving: Bool { !activeSaveGenerations.isEmpty }

    private struct PendingSave {
        let generation: UUID
        let workItem: DispatchWorkItem
    }

    /// Compatibility key for callers that do not identify a tab.
    private let defaultKey = UUID()

    /// Independent debounce work per tab. Editing or transferring one tab
    /// must not cancel a save already scheduled for another tab.
    private var pendingSaves: [UUID: PendingSave] = [:]
    /// A replaced debounce may already be executing its async save. Track
    /// executions by generation so overlapping tabs (or a newer generation of
    /// one tab) keep the UI indicator truthful until every save has completed.
    private var activeSaveGenerations: Set<UUID> = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether a pending auto-save is scheduled (for testing).
    var hasScheduledSave: Bool {
        !pendingSaves.isEmpty
    }

    func hasScheduledSave(for key: UUID) -> Bool {
        pendingSaves[key] != nil
    }

    /// Schedules a debounced auto-save. The `saveAction` fires after `delay`
    /// seconds of inactivity. If the tab is still dirty when the timer fires,
    /// the action is executed; otherwise it's skipped.
    ///
    /// - Parameters:
    ///   - isStillDirty: Check whether the tab is still dirty when the timer fires.
    ///   - saveAction: The save operation to perform.
    func schedule(
        isStillDirty: @MainActor @escaping () -> Bool,
        saveAction: @MainActor @escaping () async throws -> Void
    ) {
        schedule(for: defaultKey, isStillDirty: isStillDirty, saveAction: saveAction)
    }

    /// Schedules a debounced save independently for `key`.
    func schedule(
        for key: UUID,
        isStillDirty: @MainActor @escaping () -> Bool,
        saveAction: @MainActor @escaping () async throws -> Void
    ) {
        cancel(for: key)

        let generation = UUID()

        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingSaves[key]?.generation == generation else { return }
            guard isStillDirty() else {
                self.pendingSaves[key] = nil
                return
            }

            self.activeSaveGenerations.insert(generation)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.activeSaveGenerations.remove(generation)
                    self.activeTasks[generation] = nil
                }
                do {
                    try await saveAction()
                } catch {
                    // Silent failure — auto-save should not show alerts
                }
                if self.pendingSaves[key]?.generation == generation {
                    self.pendingSaves[key] = nil
                }
            }
            self.activeTasks[generation] = task
        }

        pendingSaves[key] = PendingSave(generation: generation, workItem: item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels the pending auto-save for one tab without disturbing others.
    func cancel(for key: UUID) {
        guard let pending = pendingSaves.removeValue(forKey: key) else { return }
        pending.workItem.cancel()
        activeTasks.removeValue(forKey: pending.generation)?.cancel()
    }

    /// Cancels every pending auto-save.
    func cancel() {
        pendingSaves.values.forEach { pending in
            pending.workItem.cancel()
            activeTasks.removeValue(forKey: pending.generation)?.cancel()
        }
        pendingSaves.removeAll()
    }
}
