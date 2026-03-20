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

    /// Validated shell path — falls back to default if the configured path is not executable.
    var resolvedShellPath: String {
        fileManager.isExecutableFile(atPath: shellPath) ? shellPath : Self.defaultShellPath
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
        shellArgs = Self.defaultShellArgs
    }
}
