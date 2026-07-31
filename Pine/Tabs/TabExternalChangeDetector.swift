//
//  TabExternalChangeDetector.swift
//  Pine
//
//  Extracted from TabManager.swift — external file change detection and reload.
//

import os
import Foundation

/// Detects external changes to open files and handles silent reload or conflict reporting.
@MainActor
enum TabExternalChangeDetector {
    private static let logger = Logger.editor

    /// Describes an external change that requires user action (dirty tab conflict).
    struct ExternalConflict {
        let tabID: UUID
        let url: URL
        let kind: Kind
        enum Kind: Equatable { case modified, deleted }
    }

    /// Result of checking external changes — includes conflicts, silently reloaded files,
    /// and IDs of clean-deleted tabs that should be closed by the caller.
    struct ExternalChangeResult {
        let conflicts: [ExternalConflict]
        let reloadedFileNames: [String]
        let cleanDeletedIDs: [UUID]
        let reloadedTabs: [ReloadedTab]

        init(
            conflicts: [ExternalConflict],
            reloadedFileNames: [String],
            cleanDeletedIDs: [UUID],
            reloadedTabs: [ReloadedTab] = []
        ) {
            self.conflicts = conflicts
            self.reloadedFileNames = reloadedFileNames
            self.cleanDeletedIDs = cleanDeletedIDs
            self.reloadedTabs = reloadedTabs
        }
    }

    /// Checks open tabs against disk state. Silently reloads clean tabs that were
    /// modified externally. Returns conflicts for dirty tabs, names of reloaded files,
    /// and IDs of clean-deleted tabs that the caller should close.
    ///
    /// - Parameters:
    ///   - tabs: The current tab array (mutated in place for silent reloads).
    ///   - modDateProvider: Returns the modification date for a URL.
    ///   - fileSizeProvider: Returns the file size for a URL.
    static func checkExternalChanges(
        tabs: inout [EditorTab],
        providers: FileProviders
    ) -> ExternalChangeResult {
        var conflicts: [ExternalConflict] = []
        var cleanDeletedIDs: [UUID] = []
        var reloadedNames: [String] = []
        var reloadedTabs: [ReloadedTab] = []

        for index in tabs.indices {
            let tab = tabs[index]
            guard let fileURL = tab.fileURL else { continue }

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                if tab.isDirty {
                    conflicts.append(.init(tabID: tab.id, url: fileURL, kind: .deleted))
                } else {
                    cleanDeletedIDs.append(tab.id)
                }
                continue
            }

            guard let diskMod = providers.modDate(fileURL),
                  let lastMod = tab.lastModDate,
                  diskMod > lastMod
            else { continue }

            if tab.kind == .preview {
                tabs[index].lastModDate = diskMod
            } else if tab.isDirty {
                conflicts.append(.init(tabID: tab.id, url: fileURL, kind: .modified))
                tabs[index].lastModDate = diskMod
            } else {
                // Safe to reload silently
                do {
                    let content = try String(
                        contentsOf: fileURL,
                        encoding: tab.encoding
                    )
                    tabs[index].content = content
                    tabs[index].savedContent = content
                    tabs[index].lastModDate = diskMod
                    tabs[index].fileSizeBytes = providers.fileSize(fileURL)
                    tabs[index].cachedHighlightResult = nil
                    tabs[index].recomputeContentCaches()
                    reloadedNames.append(fileURL.lastPathComponent)
                    reloadedTabs.append(.init(url: fileURL, text: content))
                } catch {
                    logger.error(
                        "Failed to reload tab \(fileURL.lastPathComponent): \(error)"
                    )
                }
            }
        }

        return ExternalChangeResult(
            conflicts: conflicts,
            reloadedFileNames: reloadedNames,
            cleanDeletedIDs: cleanDeletedIDs,
            reloadedTabs: reloadedTabs
        )
    }

    /// Reloads a tab's content from disk (used after user chooses "reload" in conflict dialog).
    /// Posts `.tabReloadedFromDisk` so the editor view can forcibly resync NSTextView.
    static func reloadTab(
        url: URL,
        tabs: inout [EditorTab],
        providers: FileProviders
    ) -> ReloadedTab? {
        guard let index = tabs.firstIndex(where: {
            $0.fileURL == url
        }) else {
            return nil
        }
        do {
            let content = try String(contentsOf: url, encoding: tabs[index].encoding)
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].lastModDate = providers.modDate(url)
            tabs[index].fileSizeBytes = providers.fileSize(url)
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
            return .init(url: url, text: content)
        } catch {
            logger.error("Failed to reload tab from disk \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
