//
//  FileOperationUndoManager.swift
//  Pine
//

import Foundation
import os

/// Manages file system operations (delete, rename, create) with undo/redo support.
///
/// Uses `FileManager.trashItem` for delete so that undo restores from Trash.
/// Rename and create register inverse operations on the provided `UndoManager`.
///
/// Implemented as an enum with static methods to avoid use-after-free crashes
/// when SwiftUI recreates views that previously owned a class instance (#525).
enum FileOperationUndoManager {

    // MARK: - Delete

    /// Moves the item to Trash and registers an undo action that restores it.
    static func deleteItem(at url: URL, undoManager: UndoManager) throws {
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)

        guard let restoredTrashURL = trashURL as URL? else { return }

        undoManager.registerUndo(withTarget: undoManager) { (undoMgr: UndoManager) in
            do {
                try FileManager.default.moveItem(at: restoredTrashURL, to: url)
                // Register redo (delete again)
                undoMgr.registerUndo(withTarget: undoMgr) { (redoMgr: UndoManager) in
                    try? FileOperationUndoManager.deleteItem(at: url, undoManager: redoMgr)
                }
            } catch {
                Logger.fileTree.error("Undo delete failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoDelete)
    }

    // MARK: - Rename

    /// Renames (moves) an item and registers an undo action that reverts the rename.
    static func renameItem(from oldURL: URL, to newURL: URL, undoManager: UndoManager) throws {
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        undoManager.registerUndo(withTarget: undoManager) { (undoMgr: UndoManager) in
            do {
                try FileOperationUndoManager.renameItem(from: newURL, to: oldURL, undoManager: undoMgr)
            } catch {
                Logger.fileTree.error("Undo rename failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoRename)
    }

    // MARK: - Finalize New Item (grouped create + rename undo, #527)

    /// Optionally renames a newly created item and registers a **grouped** undo action
    /// so that a single Cmd+Z removes the item entirely.
    ///
    /// When `originalURL == finalURL` (user accepted the default name), no rename is performed.
    /// Uses `beginUndoGrouping()` / `endUndoGrouping()` to guarantee the operation
    /// is atomic from the undo stack perspective.
    static func finalizeNewItem(
        from originalURL: URL,
        to finalURL: URL,
        undoManager: UndoManager
    ) throws {
        if finalURL != originalURL {
            try FileManager.default.moveItem(at: originalURL, to: finalURL)
        }

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: undoManager) { (undoMgr: UndoManager) in
            do {
                try FileOperationUndoManager.deleteItem(at: finalURL, undoManager: undoMgr)
            } catch {
                Logger.fileTree.error("Undo create failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoCreate)
        undoManager.endUndoGrouping()
    }

    // MARK: - Create

    /// Creates a file or directory and registers an undo action that trashes it.
    static func createItem(at url: URL, isDirectory: Bool, undoManager: UndoManager) throws {
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        undoManager.registerUndo(withTarget: undoManager) { (undoMgr: UndoManager) in
            do {
                try FileOperationUndoManager.deleteItem(at: url, undoManager: undoMgr)
            } catch {
                Logger.fileTree.error("Undo create failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoCreate)
    }

}
