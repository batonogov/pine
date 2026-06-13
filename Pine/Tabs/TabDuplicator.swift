//
//  TabDuplicator.swift
//  Pine
//
//  Extracted from TabManager.swift — Finder-style tab duplication.
//

import Foundation

/// Handles duplicating editor tabs with Finder-style naming.
@MainActor
enum TabDuplicator {
    /// Duplicates the tab at the given index without UI. Throws on write failure.
    /// If `projectRoot` is provided, blocks duplication of files outside the project root.
    static func duplicateTab(
        atIndex index: Int,
        in tabs: inout [EditorTab],
        editorSettings: EditorSettings,
        fileFormatters: FileFormatterRegistry,
        projectRoot: URL? = nil,
        providers: FileProviders = .default
    ) throws -> UUID? {
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        let originalURL = tab.url

        if let root = projectRoot, !FileNode.isWithinProjectRoot(originalURL, projectRoot: root) {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: Strings.operationOutsideProject
            ])
        }

        guard let duplicateURL = FileNameGenerator.finderCopyURL(for: originalURL) else { return nil }

        let trimmed = TabFormatter.contentPreparedForSave(
            tab.content,
            url: duplicateURL,
            settings: editorSettings,
            formatters: fileFormatters
        )
        try trimmed.write(to: duplicateURL, atomically: true, encoding: tab.encoding)

        var newTab = EditorTab(
            url: duplicateURL,
            content: trimmed,
            savedContent: trimmed
        )
        newTab.lastModDate = providers.modDate(duplicateURL)
        newTab.encoding = tab.encoding
        tabs.insert(newTab, at: index + 1)
        return newTab.id
    }
}
