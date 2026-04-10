//
//  EditorSettings.swift
//  Pine
//

import Foundation

/// Centralised editor save-time formatting preferences.
///
/// Each flag defaults to `true` to match common editor behaviour (VS Code, Xcode, vim
/// with `fixendofline`). Settings are persisted in `UserDefaults` and may be toggled via
/// the Editor menu. `UserDefaults` injection enables isolated unit testing.
@MainActor
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    enum Keys {
        static let insertFinalNewline = "editor.insertFinalNewline"
        static let stripTrailingWhitespace = "editor.stripTrailingWhitespace"
        static let formatOnSave = "editor.formatOnSave"
    }

    private let defaults: UserDefaults

    /// When `true`, `TabManager.trySaveTab` ensures the file ends with exactly one newline
    /// before writing to disk. Enabled by default because POSIX text files require it and
    /// most tools (`git`, `cat`, `wc`) warn on its absence.
    var insertFinalNewline: Bool {
        didSet { defaults.set(insertFinalNewline, forKey: Keys.insertFinalNewline) }
    }

    /// When `true`, trailing whitespace is stripped from every line on save. Default `true`
    /// to match existing Pine behaviour.
    var stripTrailingWhitespace: Bool {
        didSet { defaults.set(stripTrailingWhitespace, forKey: Keys.stripTrailingWhitespace) }
    }

    /// When `true`, a language-aware `FileFormatter` is applied on save (when available).
    /// Default `true`; safe because formatters are no-ops for unknown file types.
    var formatOnSave: Bool {
        didSet { defaults.set(formatOnSave, forKey: Keys.formatOnSave) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` returns nil for missing keys so we can distinguish "unset" from
        // "explicitly false" and default unset flags to `true`.
        self.insertFinalNewline = (defaults.object(forKey: Keys.insertFinalNewline) as? Bool) ?? true
        self.stripTrailingWhitespace = (defaults.object(forKey: Keys.stripTrailingWhitespace) as? Bool) ?? true
        // Off by default — JSON formatting via JSONSerialization is lossy for
        // numbers and reorders keys. Users opt in explicitly via menu toggle.
        self.formatOnSave = (defaults.object(forKey: Keys.formatOnSave) as? Bool) ?? false
    }
}
