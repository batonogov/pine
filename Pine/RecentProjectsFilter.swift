//
//  RecentProjectsFilter.swift
//  Pine
//

import Foundation

/// Filters recent project URLs by case-insensitive substring matching
/// against the project name (last path component) and full path.
enum RecentProjectsFilter {
    /// Returns URLs that match the query. Empty/whitespace query returns all URLs.
    static func filter(_ urls: [URL], query: String) -> [URL] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return urls }
        let lowered = trimmed.lowercased()
        return urls.filter { url in
            url.lastPathComponent.lowercased().contains(lowered)
                || url.path.lowercased().contains(lowered)
        }
    }
}
