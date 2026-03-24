//
//  BreadcrumbProvider.swift
//  Pine
//
//  Decomposes a file URL relative to the project root into breadcrumb segments
//  and lists sibling files/folders for each segment.
//

import Foundation

/// A single segment in the breadcrumb path.
struct BreadcrumbSegment: Identifiable, Equatable {
    let id: URL
    let name: String
    let isDirectory: Bool
    /// The directory this segment lives in (used to list siblings).
    let parentURL: URL?
    /// Full URL of the item.
    var url: URL { id }
}

/// Provides breadcrumb data by decomposing file paths relative to a project root.
enum BreadcrumbProvider {

    /// Decomposes `fileURL` into path segments relative to `projectRoot`.
    /// Returns an array of segments from the project root down to the file.
    /// If `fileURL` is not inside `projectRoot`, returns just the filename.
    static func segments(for fileURL: URL, relativeTo projectRoot: URL) -> [BreadcrumbSegment] {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let rootPath = projectRoot.standardizedFileURL.path(percentEncoded: false)

        guard filePath.hasPrefix(rootPath) else {
            // File is outside the project — show just the filename
            return [BreadcrumbSegment(
                id: fileURL,
                name: fileURL.lastPathComponent,
                isDirectory: false,
                parentURL: fileURL.deletingLastPathComponent()
            )]
        }

        // Build relative path components
        let relativePath = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relativePath.split(separator: "/").map(String.init)

        guard !components.isEmpty else {
            return [BreadcrumbSegment(
                id: projectRoot,
                name: projectRoot.lastPathComponent,
                isDirectory: true,
                parentURL: nil
            )]
        }

        var result: [BreadcrumbSegment] = []

        // First segment: the project root itself
        result.append(BreadcrumbSegment(
            id: projectRoot,
            name: projectRoot.lastPathComponent,
            isDirectory: true,
            parentURL: nil
        ))

        // Middle segments (directories)
        var currentURL = projectRoot
        for (index, component) in components.enumerated() {
            let parentURL = currentURL
            currentURL = currentURL.appendingPathComponent(component)
            let isLast = index == components.count - 1
            result.append(BreadcrumbSegment(
                id: currentURL,
                name: component,
                isDirectory: !isLast,
                parentURL: parentURL
            ))
        }

        return result
    }

    /// Lists sibling items (files and folders) in the same directory as the given segment.
    /// For the project root segment, lists the root directory contents.
    static func siblings(for segment: BreadcrumbSegment, projectRoot: URL) -> [BreadcrumbSegment] {
        let directoryURL: URL
        if segment.isDirectory {
            // For a directory segment, list its contents
            directoryURL = segment.url
        } else if let parent = segment.parentURL {
            directoryURL = parent
        } else {
            return []
        }

        return listDirectory(at: directoryURL)
    }

    /// Lists directory contents as breadcrumb segments, sorted: folders first, then alphabetical.
    private static func listDirectory(at url: URL) -> [BreadcrumbSegment] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .compactMap { itemURL -> BreadcrumbSegment? in
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return BreadcrumbSegment(
                    id: itemURL,
                    name: itemURL.lastPathComponent,
                    isDirectory: isDir,
                    parentURL: url
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Truncates segments from the left if count exceeds maxVisible, keeping the last segments.
    /// Returns (shouldShowEllipsis, visibleSegments).
    static func truncate(_ segments: [BreadcrumbSegment], maxVisible: Int) -> (ellipsis: Bool, segments: [BreadcrumbSegment]) {
        guard segments.count > maxVisible, maxVisible > 0 else {
            return (false, segments)
        }
        let visible = Array(segments.suffix(maxVisible))
        return (true, visible)
    }
}
