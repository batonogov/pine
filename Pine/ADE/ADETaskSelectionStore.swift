//
//  ADETaskSelectionStore.swift
//  Pine
//
//  Which task each project window showed, across navigation and relaunch
//  (#1760). Task IDs keyed by project path, and nothing else.
//

import Foundation

struct ADETaskSelectionRecord: Codable, Equatable, Sendable {
    let projectPath: String
    let taskID: UUID
}

/// Remembers the selected task per project. Bounded metadata only: a task ID
/// never carries text, so restoring a selection can replay nothing.
@MainActor
final class ADETaskSelectionStore {
    static let key = "ade.workspace.selectedTasks"
    /// Newest last; the oldest selection is forgotten beyond this.
    static let maximumRecords = 64

    private let defaults: UserDefaults

    init(defaults: UserDefaults = PineStorageContext.defaults) {
        self.defaults = defaults
    }

    var count: Int { records().count }

    var isEmpty: Bool { records().isEmpty }

    func taskID(forProject path: String) -> UUID? {
        records().last { $0.projectPath == path }?.taskID
    }

    /// Remembers `taskID` for `path`, or forgets the project's selection when `nil`.
    func set(_ taskID: UUID?, forProject path: String) {
        var updated = records().filter { $0.projectPath != path }
        if let taskID {
            updated.append(ADETaskSelectionRecord(projectPath: path, taskID: taskID))
        }
        if updated.count > Self.maximumRecords {
            updated.removeFirst(updated.count - Self.maximumRecords)
        }
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(encoded, forKey: Self.key)
        }
    }

    /// An unreadable or foreign record is discarded rather than guessed from.
    private func records() -> [ADETaskSelectionRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ADETaskSelectionRecord].self, from: data) else {
            return []
        }
        return decoded
    }
}
