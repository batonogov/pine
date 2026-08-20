//
//  RecentProjectsSelection.swift
//  Pine
//

import Foundation

/// Keyboard commands supported by the Welcome window's recent-project list.
enum RecentProjectsKeyboardCommand: Sendable {
    case up
    case down
    case home
    case end
}

/// Keeps Welcome selection deterministic while filtering and removing rows.
///
/// `List(selection:)` supplies the native focused/unfocused appearance and
/// accessibility semantics. This model owns the small amount of policy that
/// AppKit doesn't know about: which result to select after a filter or removal.
struct RecentProjectsSelection: Equatable {
    var selectedURL: URL?

    mutating func normalize(for visibleProjects: [URL]) {
        guard !visibleProjects.isEmpty else {
            selectedURL = nil
            return
        }
        if let selectedURL, visibleProjects.contains(selectedURL) {
            return
        }
        selectedURL = visibleProjects.first
    }

    /// Returns the selected row that should be minimally revealed after the
    /// visible collection changes, even when normalization preserves the same
    /// selection and therefore does not emit a selection change.
    func revealTarget(in visibleProjects: [URL]) -> URL? {
        guard let selectedURL,
              visibleProjects.contains(selectedURL) else { return nil }
        return selectedURL
    }

    mutating func move(
        _ command: RecentProjectsKeyboardCommand,
        in visibleProjects: [URL]
    ) {
        guard !visibleProjects.isEmpty else {
            selectedURL = nil
            return
        }

        let currentIndex = selectedURL.flatMap {
            visibleProjects.firstIndex(of: $0)
        }
        let targetIndex: Int
        switch command {
        case .up:
            targetIndex = max(0, (currentIndex ?? 0) - 1)
        case .down:
            targetIndex = min(visibleProjects.count - 1, (currentIndex ?? -1) + 1)
        case .home:
            targetIndex = visibleProjects.startIndex
        case .end:
            targetIndex = visibleProjects.index(before: visibleProjects.endIndex)
        }
        selectedURL = visibleProjects[targetIndex]
    }

    mutating func normalizeAfterRemoving(
        _ removedURL: URL,
        from visibleProjects: [URL],
        remainingProjects: [URL]
    ) {
        guard selectedURL == removedURL else {
            normalize(for: remainingProjects)
            return
        }
        guard !remainingProjects.isEmpty else {
            selectedURL = nil
            return
        }

        let removedIndex = visibleProjects.firstIndex(of: removedURL) ?? 0
        selectedURL = remainingProjects[min(removedIndex, remainingProjects.count - 1)]
    }
}
