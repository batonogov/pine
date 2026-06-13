//
//  TabAutoSave.swift
//  Pine
//
//  Extracted from TabManager.swift — debounced auto-save scheduling.
//

import Foundation

/// Manages debounced auto-save scheduling for editor tabs.
/// Tracks a pending work item and fires a save callback after a delay.
@MainActor
final class TabAutoSave {
    /// UserDefaults key for the auto-save toggle.
    nonisolated static let autoSaveKey = "autoSaveEnabled"

    /// Auto-save delay in seconds.
    var delay: TimeInterval = 1.0

    /// Whether auto-save is currently in progress (for UI indicator).
    private(set) var isSaving = false

    /// Debounce work item.
    private var workItem: DispatchWorkItem?

    /// Whether a pending auto-save is scheduled (for testing).
    var hasScheduledSave: Bool {
        workItem != nil
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
        saveAction: @MainActor @escaping () throws -> Void
    ) {
        workItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard isStillDirty() else {
                self.workItem = nil
                return
            }

            self.isSaving = true
            do {
                try saveAction()
            } catch {
                // Silent failure — auto-save should not show alerts
            }
            self.isSaving = false
            self.workItem = nil
        }

        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels any pending auto-save.
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
