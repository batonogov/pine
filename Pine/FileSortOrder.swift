//
//  FileSortOrder.swift
//  Pine
//

import Foundation

/// The attribute by which sidebar file tree entries are sorted.
enum FileSortOrder: String, CaseIterable {
    case name
    case dateModified
    case size
    case type

    /// UserDefaults key used to persist the user's sort order preference.
    static let storageKey = "fileSortOrder"
}

/// The direction in which sidebar file tree entries are sorted.
enum FileSortDirection: String {
    case ascending
    case descending

    /// UserDefaults key used to persist the user's sort direction preference.
    static let storageKey = "fileSortDirection"
}

// MARK: - Sorting helpers

extension Array where Element == FileNode {
    /// Returns a copy sorted with directories first, then by the given order and direction.
    func sorted(by order: FileSortOrder, direction: FileSortDirection) -> [FileNode] {
        sorted { lhs, rhs in
            // Directories always come before files regardless of sort order.
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let ascending: Bool
            switch order {
            case .name:
                ascending = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .dateModified:
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                ascending = lDate < rDate
            case .size:
                let lSize = lhs.fileSize ?? 0
                let rSize = rhs.fileSize ?? 0
                if lSize == rSize {
                    ascending = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                } else {
                    ascending = lSize < rSize
                }
            case .type:
                let lExt = lhs.url.pathExtension.lowercased()
                let rExt = rhs.url.pathExtension.lowercased()
                if lExt == rExt {
                    ascending = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                } else {
                    ascending = lExt.localizedCaseInsensitiveCompare(rExt) == .orderedAscending
                }
            }
            return direction == .ascending ? ascending : !ascending
        }
    }

    /// Recursively sorts this array and all nested children in-place.
    func recursiveSorted(by order: FileSortOrder, direction: FileSortDirection) -> [FileNode] {
        let result = sorted(by: order, direction: direction)
        for node in result where node.isDirectory {
            if let children = node.children, !children.isEmpty {
                node.children = children.recursiveSorted(by: order, direction: direction)
            }
        }
        return result
    }
}
