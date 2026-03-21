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

    var toggled: FileSortDirection {
        self == .ascending ? .descending : .ascending
    }
}
