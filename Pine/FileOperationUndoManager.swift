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
final class FileOperationUndoManager {

    // MARK: - Delete

    /// Moves the item to Trash and registers an undo action that restores it.
    func deleteItem(at url: URL, undoManager: UndoManager) throws {
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)

        guard let restoredTrashURL = trashURL as URL? else { return }

        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileManager.default.moveItem(at: restoredTrashURL, to: url)
                // Register redo (delete again)
                undoManager.registerUndo(withTarget: target) { target in
                    try? target.deleteItem(at: url, undoManager: undoManager)
                }
            } catch {
                Logger.fileTree.error("Undo delete failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoDelete)
    }

    // MARK: - Rename

    /// Renames (moves) an item and registers an undo action that reverts the rename.
    func renameItem(from oldURL: URL, to newURL: URL, undoManager: UndoManager) throws {
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        undoManager.registerUndo(withTarget: self) { target in
            do {
                try target.renameItem(from: newURL, to: oldURL, undoManager: undoManager)
            } catch {
                Logger.fileTree.error("Undo rename failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoRename)
    }

    // MARK: - Create

    /// Creates a file or directory and registers an undo action that trashes it.
    func createItem(at url: URL, isDirectory: Bool, undoManager: UndoManager) throws {
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        undoManager.registerUndo(withTarget: self) { target in
            do {
                try target.deleteItem(at: url, undoManager: undoManager)
            } catch {
                Logger.fileTree.error("Undo create failed: \(error)")
            }
        }
        undoManager.setActionName(Strings.undoCreate)
    }

}
