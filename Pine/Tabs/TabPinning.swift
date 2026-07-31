//
//  TabPinning.swift
//  Pine
//
//  Extracted from TabManager.swift — pin/unpin and pin-state restoration.
//

import Foundation

/// Manages pinned tab state: toggling pins, sorting pinned tabs to the left,
/// and restoring pinned state during session restoration.
@MainActor
enum TabPinning {
    /// Toggles the pinned state of a tab. Pinned tabs are moved to the left;
    /// unpinned tabs are moved to the right of the pinned group.
    static func togglePin(id: UUID, in tabs: inout [EditorTab]) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()

        if tabs[index].isPinned {
            // Move to the end of the pinned group
            let pinnedCount = tabs.prefix(index).filter(\.isPinned).count
            if index != pinnedCount {
                let tab = tabs.remove(at: index)
                tabs.insert(tab, at: pinnedCount)
            }
        } else {
            // Move to the start of the unpinned group (right after last pinned tab)
            let pinnedCount = tabs.filter(\.isPinned).count
            if index != pinnedCount {
                let tab = tabs.remove(at: index)
                tabs.insert(tab, at: pinnedCount)
            }
        }
    }

    /// Number of currently pinned tabs.
    static func pinnedTabCount(in tabs: [EditorTab]) -> Int {
        tabs.filter(\.isPinned).count
    }

    /// Restores pinned state for tabs matching the given file paths.
    /// Called during session restoration. Re-sorts: pinned tabs first,
    /// preserving relative order within each group.
    static func restorePinnedState(pinnedPaths: Set<String>, in tabs: inout [EditorTab]) {
        for index in tabs.indices
        where tabs[index].fileURL.map({
            pinnedPaths.contains($0.path)
        }) == true {
            tabs[index].isPinned = true
        }
        let pinned = tabs.filter(\.isPinned)
        let unpinned = tabs.filter { !$0.isPinned }
        tabs = pinned + unpinned
    }
}
