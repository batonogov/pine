//
//  ShellAutosuggestions.swift
//  Pine
//
//  Provides opt-in ghost-text autosuggestions in the built-in terminal by
//  installing a small bundled ZDOTDIR that sources the user's real `.zshrc`
//  and then enables `zsh-autosuggestions` if it can be located on the host.
//
//  Design notes (Apple way — be a good guest on the user's machine):
//  - Opt-in. Default is OFF. We never modify the user's real dotfiles.
//  - Scoped to zsh. Bash/fish/nushell users keep their native setup.
//  - We write a tiny bootstrap `.zshrc` under Application Support and point
//    the child shell at it via `ZDOTDIR`. The bootstrap first sources the
//    user's real `~/.zshrc` (so every alias, prompt, plugin keeps working —
//    oh-my-zsh, starship, direnv, nvm, etc.) and only then adds
//    `zsh-autosuggestions` from whichever standard location has it.
//  - Bright-black slot (ghost-text color) was already fixed for palette
//    parity in #765, so no palette changes are needed here.
//  - TUI apps (vim, htop, k9s) are completely unaffected: `zsh-autosuggestions`
//    is a line-editor widget, it only runs while zle is active at the prompt.
//

import Foundation

/// Builds and manages a bundled ZDOTDIR used to enable ghost-text
/// autosuggestions in Pine's terminal.
///
/// This type is intentionally `nonisolated` and side-effect-free except for
/// its explicit filesystem calls, so it can be unit-tested without touching
/// the real Application Support directory.
struct ShellAutosuggestionsProvider {

    // MARK: - Configuration

    /// Directory where the bootstrap `.zshrc` will be written.
    /// Typically `~/Library/Application Support/Pine/shell`.
    let directory: URL

    /// File manager used for all I/O (injectable for tests).
    let fileManager: FileManager

    /// Candidate locations of `zsh-autosuggestions.zsh` checked at shell
    /// startup, in priority order. Kept as plain strings so the generated
    /// `.zshrc` can iterate over them with a simple `for` loop.
    ///
    /// Covers:
    /// - Homebrew on Apple Silicon and Intel
    /// - MacPorts
    /// - oh-my-zsh custom plugin directory
    /// - System-wide `/usr/share` (some Linux-flavoured setups)
    static let candidateAutosuggestionPaths: [String] = [
        "/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
        "/usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
        "/opt/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
        "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh",
        "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh",
        "/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
    ]

    // MARK: - Init

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default provider rooted at `~/Library/Application Support/Pine/shell`.
    static func defaultProvider(fileManager: FileManager = .default) -> ShellAutosuggestionsProvider {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine", isDirectory: true)
            .appendingPathComponent("shell", isDirectory: true)
        return ShellAutosuggestionsProvider(directory: base, fileManager: fileManager)
    }

    // MARK: - API

    /// Full path to the bootstrap `.zshrc` inside `directory`.
    var zshrcURL: URL {
        directory.appendingPathComponent(".zshrc", isDirectory: false)
    }

    /// Generates the bootstrap `.zshrc` contents.
    ///
    /// The script:
    ///   1. Sources the user's real `~/.zshrc` if present, so everything the
    ///      user already configured (prompt, plugins, functions) keeps working.
    ///   2. Tries each candidate path for `zsh-autosuggestions.zsh` and sources
    ///      the first one that exists.
    ///   3. Tweaks the highlight style to use the bright-black ANSI slot so it
    ///      inherits Pine's Terminal.app-matched palette from #765.
    ///
    /// Kept as `static` so tests can assert on the generated text without
    /// touching the filesystem.
    static func generateZshrc() -> String {
        var lines: [String] = []
        lines.append("# Pine — bootstrap ZDOTDIR for shell autosuggestions.")
        lines.append("# Generated automatically. Do not edit — toggle from the Terminal menu.")
        lines.append("")
        lines.append("# 1. Source the user's real ~/.zshrc so their environment is preserved.")
        lines.append("if [ -f \"$HOME/.zshrc\" ]; then")
        lines.append("  ZDOTDIR=\"$HOME\" . \"$HOME/.zshrc\"")
        lines.append("fi")
        lines.append("")
        lines.append("# 2. Enable zsh-autosuggestions from the first location that has it.")
        lines.append("__pine_autosuggest_candidates=(")
        for path in candidateAutosuggestionPaths {
            lines.append("  \"\(path)\"")
        }
        lines.append(")")
        lines.append("for __pine_candidate in \"${__pine_autosuggest_candidates[@]}\"; do")
        lines.append("  __pine_expanded=\"${__pine_candidate/#\\$HOME/$HOME}\"")
        lines.append("  if [ -f \"$__pine_expanded\" ]; then")
        lines.append("    . \"$__pine_expanded\"")
        lines.append("    break")
        lines.append("  fi")
        lines.append("done")
        lines.append("unset __pine_autosuggest_candidates __pine_candidate __pine_expanded")
        lines.append("")
        lines.append("# 3. Use bright-black (ANSI slot 8) so the ghost text matches Pine's palette (#765).")
        lines.append("ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Writes (or rewrites) the bootstrap `.zshrc` on disk and returns the
    /// directory path suitable for use as `ZDOTDIR`.
    ///
    /// Idempotent: safe to call on every terminal launch — it only rewrites
    /// the file when the content differs, so we don't churn mtime for nothing.
    @discardableResult
    func install() throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let contents = Self.generateZshrc()
        let target = zshrcURL
        if let existing = try? String(contentsOf: target, encoding: .utf8), existing == contents {
            return directory
        }
        try contents.write(to: target, atomically: true, encoding: .utf8)
        return directory
    }

    /// Deletes the bootstrap directory (used when the user disables the feature
    /// or for test cleanup). Never throws on a missing directory.
    func uninstall() throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}
