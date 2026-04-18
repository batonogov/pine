//
//  EditorSettings.swift
//  Pine
//

import Foundation

/// Centralised editor save-time formatting preferences.
///
/// `insertFinalNewline` and `stripTrailingWhitespace` default to `true` to match common
/// editor behaviour (VS Code, Xcode, vim with `fixendofline`); `formatOnSave` defaults to
/// `false` because the JSON formatter is lossy. Settings are persisted in `UserDefaults`
/// and may be toggled via the Editor menu. `UserDefaults` injection enables isolated unit
/// testing.
@MainActor
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    enum Keys {
        static let insertFinalNewline = "editor.insertFinalNewline"
        static let stripTrailingWhitespace = "editor.stripTrailingWhitespace"
        static let formatOnSave = "editor.formatOnSave"
        static let smartListContinuation = "editor.smartListContinuation"
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
    /// Default `false`; JSON formatting via `JSONSerialization` is lossy and reorders keys.
    var formatOnSave: Bool {
        didSet { defaults.set(formatOnSave, forKey: Keys.formatOnSave) }
    }

    /// When `true`, pressing Return inside a Markdown list automatically continues the
    /// bullet/number/task on the next line. Default `true` to match VS Code, Obsidian, iA Writer.
    var smartListContinuation: Bool {
        didSet { defaults.set(smartListContinuation, forKey: Keys.smartListContinuation) }
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
        // On by default — matches VS Code, Obsidian, iA Writer behaviour.
        self.smartListContinuation = (defaults.object(forKey: Keys.smartListContinuation) as? Bool) ?? true
    }
}
