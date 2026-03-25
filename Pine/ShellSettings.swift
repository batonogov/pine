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

    /// Reads the user's login shell from the POSIX account database.
    /// Works reliably inside Xcode sandbox and App Sandbox where `$SHELL` may be absent or wrong.
    static func systemShellPath() -> String? {
        guard let pw = getpwuid(getuid()) else { return nil }
        guard let shell = pw.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    /// Fallback chain: `getpwuid` → `$SHELL` → `/bin/zsh`.
    private static var defaultShellPath: String {
        if let posixShell = systemShellPath() {
            return posixShell
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
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

    /// Validated shell path — falls back to system shell (via `getpwuid`), then `$SHELL`, then `/bin/zsh`.
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
}
