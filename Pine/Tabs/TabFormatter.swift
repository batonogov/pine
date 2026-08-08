//
//  TabFormatter.swift
//  Pine
//
//  Extracted from TabManager.swift — pure save-time content transformations.
//

import Foundation

nonisolated struct EditorSaveSettingsSnapshot: Sendable {
    let insertFinalNewline: Bool
    let stripTrailingWhitespace: Bool
    let formatOnSave: Bool
}

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
        contentPreparedForSave(
            content,
            url: url,
            settings: EditorSaveSettingsSnapshot(
                insertFinalNewline: settings.insertFinalNewline,
                stripTrailingWhitespace: settings.stripTrailingWhitespace,
                formatOnSave: settings.formatOnSave
            ),
            formatters: formatters,
            formatterMaximumDuration: nil
        )
    }

    nonisolated static func contentPreparedForSave(
        _ content: String,
        url: URL,
        settings: EditorSaveSettingsSnapshot,
        formatters: FileFormatterRegistry,
        formatterMaximumDuration: TimeInterval?
    ) -> String {
        var result = content
        if settings.formatOnSave {
            if let formatterMaximumDuration {
                result = formatters.format(
                    content: result,
                    url: url,
                    maximumDuration: formatterMaximumDuration
                )
            } else {
                result = formatters.format(content: result, url: url)
            }
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
