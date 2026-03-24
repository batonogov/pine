//
//  ShellSettings.swift
//  Pine
//

import Foundation

@Observable
final class ShellSettings {
    static let shared = ShellSettings()

    struct ShellOption: Identifiable, Hashable {
        let name: String
        let path: String
        let defaultArgs: [String]

        var id: String { path }
    }

    static let commonShells: [ShellOption] = [
        ShellOption(name: "zsh", path: "/bin/zsh", defaultArgs: ["--login"]),
        ShellOption(name: "bash", path: "/bin/bash", defaultArgs: ["--login"]),
        ShellOption(name: "fish", path: "/usr/local/bin/fish", defaultArgs: ["-l"]),
        ShellOption(name: "fish (Homebrew)", path: "/opt/homebrew/bin/fish", defaultArgs: ["-l"]),
        ShellOption(name: "nushell", path: "/usr/local/bin/nu", defaultArgs: ["--login"]),
        ShellOption(name: "nushell (Homebrew)", path: "/opt/homebrew/bin/nu", defaultArgs: ["--login"]),
    ]

    private static let shellPathKey = "terminalShellPath"
    private static let shellArgsKey = "terminalShellArgs"

    private static var defaultShellPath: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static let defaultShellArgs = ["--login"]

    private let defaults: UserDefaults
    private let fileManager: FileManager

    var shellPath: String {
        didSet {
            defaults.set(shellPath, forKey: Self.shellPathKey)
        }
    }

    var shellArgs: [String] {
        didSet {
            defaults.set(shellArgs, forKey: Self.shellArgsKey)
        }
    }

    /// Validated shell path — falls back to `$SHELL`, then `/bin/zsh` if configured path is not executable.
    var resolvedShellPath: String {
        if fileManager.isExecutableFile(atPath: shellPath) { return shellPath }
        let fallback = Self.defaultShellPath
        if fileManager.isExecutableFile(atPath: fallback) { return fallback }
        return "/bin/zsh"
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager

        let storedPath = defaults.string(forKey: Self.shellPathKey)
        if let storedPath, !storedPath.isEmpty {
            self.shellPath = storedPath
        } else {
            self.shellPath = Self.defaultShellPath
        }

        if let storedArgs = defaults.stringArray(forKey: Self.shellArgsKey) {
            self.shellArgs = storedArgs
        } else {
            self.shellArgs = Self.defaultShellArgs
        }
    }

    func reset() {
        shellPath = Self.defaultShellPath
        shellArgs = Self.commonShells.first { $0.path == shellPath }?.defaultArgs ?? Self.defaultShellArgs
    }

    /// Applies a shell option, updating both path and args.
    func applyShellOption(_ option: ShellOption) {
        shellPath = option.path
        shellArgs = option.defaultArgs
    }

    /// Returns shells from `commonShells` that are actually installed (executable on disk),
    /// plus any shells from `/etc/shells` that are executable but not in `commonShells`.
    func availableShells() -> [ShellOption] {
        var result: [ShellOption] = []
        var seenPaths = Set<String>()

        // First, add common shells that exist on this machine
        for shell in Self.commonShells where fileManager.isExecutableFile(atPath: shell.path) {
            result.append(shell)
            seenPaths.insert(shell.path)
        }

        // Then, add any extra shells from /etc/shells
        if let content = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for path in Self.parseEtcShells(content) where !seenPaths.contains(path) {
                if fileManager.isExecutableFile(atPath: path) {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    result.append(ShellOption(name: name, path: path, defaultArgs: ["--login"]))
                    seenPaths.insert(path)
                }
            }
        }

        return result
    }

    /// Parses `/etc/shells` content: filters comments and empty lines, returns shell paths.
    static func parseEtcShells(_ content: String) -> [String] {
        content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
