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
    struct ExternalConflict: Equatable, Sendable {
        let tabID: UUID
        let url: URL
        let kind: Kind
        let observedState: BackingFileState

        enum Kind: Equatable, Sendable { case modified, deleted }
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
                    guard tab.pendingExternalFileState != .missing else {
                        continue
                    }
                    conflicts.append(.init(
                        tabID: tab.id,
                        url: fileURL,
                        kind: .deleted,
                        observedState: .missing
                    ))
                    tabs[index].pendingExternalFileState = .missing
                } else {
                    cleanDeletedIDs.append(tab.id)
                }
                continue
            }

            let diskMod = providers.modDate(fileURL)
            let diskIdentity = try? providers.fileIdentity(fileURL)
            let identityChanged = tab.backingFileRevision?.fileIdentity.map {
                $0 != diskIdentity
            }
            let modificationDateChanged = diskMod != tab.lastModDate
            guard identityChanged ?? modificationDateChanged else { continue }

            if case .present(let pendingRevision) =
                tab.pendingExternalFileState,
               pendingRevision.fileIdentity == diskIdentity {
                continue
            }

            if tab.kind == .preview {
                tabs[index].lastModDate = diskMod
                continue
            }

            guard let diskRevision = try? providers.fileRevision(fileURL)
            else { continue }
            if diskRevision.contentDigest
                == tab.backingFileRevision?.contentDigest {
                tabs[index].backingFileRevision = diskRevision
                tabs[index].lastModDate = diskMod
                tabs[index].pendingExternalFileState = nil
                continue
            }

            if tab.isDirty {
                let diskState = BackingFileState.present(diskRevision)
                guard tab.pendingExternalFileState != diskState else {
                    continue
                }
                conflicts.append(.init(
                    tabID: tab.id,
                    url: fileURL,
                    kind: .modified,
                    observedState: diskState
                ))
                tabs[index].lastModDate = diskMod
                tabs[index].pendingExternalFileState = diskState
            } else {
                // Safe to reload silently
                do {
                    let data = try Data(contentsOf: fileURL)
                    guard let content = String(
                        data: data,
                        encoding: tab.encoding
                    ) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    tabs[index].content = content
                    tabs[index].savedContent = content
                    tabs[index].lastModDate = providers.modDate(fileURL)
                    tabs[index].fileSizeBytes = providers.fileSize(fileURL)
                    tabs[index].backingFileRevision = BackingFileRevision(
                        data: data,
                        fileIdentity: try? providers.fileIdentity(fileURL)
                    )
                    tabs[index].pendingExternalFileState = nil
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
        providers: FileProviders,
        expectedState: BackingFileState? = nil
    ) -> ReloadedTab? {
        guard let index = tabs.firstIndex(where: {
            $0.fileURL == url
        }) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let revision = BackingFileRevision(
                data: data,
                fileIdentity: try? providers.fileIdentity(url)
            )
            if let expectedState,
               expectedState != .present(revision) {
                return nil
            }
            guard let content = String(
                data: data,
                encoding: tabs[index].encoding
            ) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].lastModDate = providers.modDate(url)
            tabs[index].fileSizeBytes = providers.fileSize(url)
            tabs[index].backingFileRevision = revision
            tabs[index].pendingExternalFileState = nil
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
            return .init(url: url, text: content)
        } catch {
            logger.error("Failed to reload tab from disk \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func authorizeExternalChange(
        _ conflict: ExternalConflict,
        tabs: inout [EditorTab],
        providers: FileProviders
    ) -> Bool {
        guard conflict.kind == .modified,
              let index = tabs.firstIndex(where: {
                  $0.id == conflict.tabID && $0.fileURL == conflict.url
              }),
              currentFileState(at: conflict.url, providers: providers)
                == conflict.observedState,
              case .present(let revision) = conflict.observedState else {
            return false
        }
        tabs[index].backingFileRevision = revision
        tabs[index].pendingExternalFileState = nil
        tabs[index].lastModDate = providers.modDate(conflict.url)
        return true
    }

    private static func currentFileState(
        at url: URL,
        providers: FileProviders
    ) -> BackingFileState? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let revision = try? providers.fileRevision(url) else {
            return nil
        }
        return .present(revision)
    }
}
