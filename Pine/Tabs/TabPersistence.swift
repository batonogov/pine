//
//  TabPersistence.swift
//  Pine
//
//  Extracted from TabManager.swift — file I/O for opening, saving, and reloading tabs.
//

import os
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Bundles file system query closures to reduce parameter count.
struct FileProviders {
    let modDate: (URL) -> Date?
    let fileSize: (URL) -> Int?

    /// Default providers using FileManager.
    static let `default` = FileProviders(
        modDate: { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        },
        fileSize: { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return nil }
            return size
        }
    )
}

/// Bundles save-time configuration to reduce parameter count.
struct SaveConfig {
    let editorSettings: EditorSettings
    let formatters: FileFormatterRegistry
}

/// Handles disk I/O for editor tabs: opening files, saving content,
/// large file handling, and preview file detection.
@MainActor
enum TabPersistence {
    private static let logger = Logger.editor

    /// File size threshold (in bytes) above which a warning is shown before opening.
    static let largeFileThreshold = FileSizeConstants.oneMB

    /// File size threshold (in bytes) above which only a partial load is performed.
    static let hugeFileThreshold = FileSizeConstants.tenMB

    /// Number of bytes to load from the beginning of a huge file.
    static let hugeFilePartialLoadSize = FileSizeConstants.oneMB

    // MARK: - File info

    /// Returns the modification date of a file, or nil on error.
    static func modDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Returns the file size in bytes, or nil on error.
    static func fileSize(url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// Returns true if the file at the given URL is larger than `largeFileThreshold`.
    static func isLargeFile(url: URL) -> Bool {
        guard let size = fileSize(url: url) else { return false }
        return size >= largeFileThreshold
    }

    /// Determines if a file should be opened as a Quick Look preview.
    static func isPreviewFile(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf)
            || type.conforms(to: .font)
    }

    // MARK: - Open tab

    /// Creates a text tab by reading file content from disk.
    static func createTextTab(
        url: URL,
        syntaxHighlightingDisabled: Bool,
        providers: FileProviders = .default
    ) -> EditorTab {
        let content: String
        let encoding: String.Encoding
        do {
            let data = try Data(contentsOf: url)
            (content, encoding) = String.Encoding.detect(from: data)
        } catch {
            content = "// Error: \(error.localizedDescription)"
            encoding = .utf8
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = providers.modDate(url)
        tab.syntaxHighlightingDisabled = syntaxHighlightingDisabled
        tab.encoding = encoding
        tab.fileSizeBytes = providers.fileSize(url)
        tab.recomputeContentCaches()
        return tab
    }

    /// Creates a preview tab for binary files.
    static func createPreviewTab(
        url: URL,
        providers: FileProviders = .default
    ) -> EditorTab {
        var tab = EditorTab(url: url, kind: .preview)
        tab.lastModDate = providers.modDate(url)
        return tab
    }

    /// Creates a tab for a huge file with partial load.
    static func createHugeFileTab(
        url: URL,
        totalSize: Int,
        modDateProvider: @MainActor @Sendable (URL) -> Date? = modDate(for:)
    ) -> EditorTab {
        let content: String
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }
            let partialData = handle.readData(ofLength: hugeFilePartialLoadSize)
            let (decoded, _) = String.Encoding.detect(from: partialData)
            let sizeString = ByteCountFormatter.string(
                fromByteCount: Int64(totalSize), countStyle: .file
            )
            content = decoded + Strings.fileTruncatedNotice(sizeString)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDateProvider(url)
        tab.syntaxHighlightingDisabled = true
        tab.isTruncated = true
        tab.fileSizeBytes = totalSize
        return tab
    }

    // MARK: - Resolve open

    /// Decision result for opening a tab.
    enum OpenDecision {
        case activateExisting(UUID)
        case openNew(EditorTab)
        case cancel
    }

    /// Resolves what to do when opening a file: activate existing tab, create new, or cancel.
    /// When `syntaxHighlightingDisabled` is nil, the large file alert is shown for large files.
    /// When it's non-nil (session restore), the alert is skipped.
    static func resolveOpen(
        url: URL,
        existingTabs: [EditorTab],
        syntaxHighlightingDisabled: Bool?
    ) -> OpenDecision {
        if let existing = existingTabs.first(where: { $0.url == url }) {
            return .activateExisting(existing.id)
        }

        if isPreviewFile(url: url) {
            return .openNew(createPreviewTab(url: url))
        }

        if let size = fileSize(url: url), size >= hugeFileThreshold {
            return .openNew(createHugeFileTab(url: url, totalSize: size))
        }

        // Only show large file alert when not restoring a session
        if syntaxHighlightingDisabled == nil, let size = fileSize(url: url), size >= largeFileThreshold {
            let sizeMB = Double(size) / Double(FileSizeConstants.oneMB)
            switch showLargeFileAlert(fileName: url.lastPathComponent, sizeMB: sizeMB) {
            case .cancel:
                return .cancel
            case .openWithoutHighlighting:
                return .openNew(createTextTab(url: url, syntaxHighlightingDisabled: true))
            case .openWithHighlighting:
                break
            }
        }

        return .openNew(createTextTab(url: url, syntaxHighlightingDisabled: syntaxHighlightingDisabled ?? false))
    }

    // MARK: - Save

    /// Result of the large file warning alert.
    enum LargeFileAlertResult {
        case openWithHighlighting
        case openWithoutHighlighting
        case cancel
    }

    /// Shows a warning alert for large files. Returns the user's choice.
    @discardableResult
    static func showLargeFileAlert(fileName: String, sizeMB: Double) -> LargeFileAlertResult {
        let response = AlertTemplate.largeFileWarning.runModal(
            messageText: Strings.largeFileWarningTitle,
            informativeText: Strings.largeFileWarningMessage(fileName, sizeMB)
        )
        switch response {
        case .alertFirstButtonReturn:
            return .openWithoutHighlighting
        case .alertSecondButtonReturn:
            return .openWithHighlighting
        default:
            return .cancel
        }
    }

    /// Saves tab content to disk. Returns true on success.
    /// Posts `.tabReloadedFromDisk` when save-time transforms changed the text.
    static func saveTabContent(
        at index: Int,
        tabs: inout [EditorTab],
        config: SaveConfig,
        providers: FileProviders
    ) throws -> Bool {
        assert(tabs.indices.contains(index), "saveTabContent called with out-of-bounds index \(index)")
        let tab = tabs[index]
        guard tab.kind == .text else { return false }
        if tab.isTruncated {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot save: file was partially loaded (truncated). Saving would corrupt the original file."
            ])
        }
        let trimmed = TabFormatter.contentPreparedForSave(
            tab.content,
            url: tab.url,
            settings: config.editorSettings,
            formatters: config.formatters
        )
        try trimmed.write(to: tab.url, atomically: true, encoding: tab.encoding)
        let contentChanged = trimmed != tab.content
        tabs[index].content = trimmed
        tabs[index].savedContent = trimmed
        tabs[index].lastModDate = providers.modDate(tab.url)
        tabs[index].fileSizeBytes = providers.fileSize(tab.url)

        if contentChanged {
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: ["url": tab.url, "text": trimmed]
            )
        }
        return true
    }

    /// Save As — writes content to a new URL and updates tab in-place.
    static func saveTabAs(
        at index: Int,
        tabs: inout [EditorTab],
        newURL: URL,
        config: SaveConfig,
        providers: FileProviders
    ) throws -> Bool {
        let tab = tabs[index]
        let trimmed = TabFormatter.contentPreparedForSave(
            tab.content,
            url: newURL,
            settings: config.editorSettings,
            formatters: config.formatters
        )
        try trimmed.write(to: newURL, atomically: true, encoding: tab.encoding)
        let contentChanged = trimmed != tab.content
        tabs[index].content = trimmed
        tabs[index].url = newURL
        tabs[index].savedContent = trimmed
        tabs[index].lastModDate = providers.modDate(newURL)
        if contentChanged {
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: ["url": newURL, "text": trimmed]
            )
        }
        return true
    }
}
