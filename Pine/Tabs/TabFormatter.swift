//
//  TabFormatter.swift
//  Pine
//
//  Extracted from TabManager.swift — pure save-time content transformations.
//

import Foundation

/// Applies all enabled save-time transformations in the canonical order:
/// 1. Language-aware formatter (e.g. JSON pretty-print), when `formatOnSave` is on
///    and a formatter claims this file type.
/// 2. Strip trailing whitespace from every line.
/// 3. Ensure a single final newline.
///
/// Order matters: formatters run first because they may rewrite the whole file,
/// after which the whitespace/newline rules normalise the result. Pure function so
/// it can be unit-tested without a `TabManager` instance.
enum TabFormatter {
    static func contentPreparedForSave(
        _ content: String,
        url: URL,
        settings: EditorSettings,
        formatters: FileFormatterRegistry
    ) -> String {
        var result = content
        if settings.formatOnSave {
            result = formatters.format(content: result, url: url)
        }
        if settings.stripTrailingWhitespace {
            result = result.trailingWhitespaceStripped()
        }
        if settings.insertFinalNewline {
            result = result.ensuringTrailingNewline()
        }
        return result
    }
}
