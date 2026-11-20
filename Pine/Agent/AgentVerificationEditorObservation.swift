import Foundation
import Observation
import Synchronization

extension AgentVerificationEditorPreflight {
    /// Observe the complete editor-owner collection as well as its tabs, so
    /// opening a split/project or editing after preflight revokes the witness.
    @MainActor
    static func observing(_ tabs: () -> [EditorTab]) -> Self {
        let current = Mutex(true)
        let clean = withObservationTracking {
            tabs().allSatisfy { !$0.isDirty }
        } onChange: {
            current.withLock { $0 = false }
        }
        // shortcut: any unsaved buffer blocks checks, until scoped alias-safe editor coverage exists.
        guard clean else { return .unavailable }
        return .available([], isCurrent: { current.withLock { $0 } })
    }
}

extension ProjectRegistry {
    /// Runtime-only; never saves buffers or persists editor contents.
    @MainActor
    func verificationEditorPreflight() -> AgentVerificationEditorPreflight {
        .observing {
            openProjects.values.flatMap { project in
                project.paneManager.allTabManagers.flatMap(\.tabs)
            }
        }
    }
}
