//
//  ShellSettings.swift
//  Pine
//

import Foundation

@Observable
final class ShellSettings {
    static let shared = ShellSettings()

    struct ShellOption {
        let name: String
        let path: String
    }

    static let commonShells: [ShellOption] = [
        ShellOption(name: "zsh", path: "/bin/zsh"),
        ShellOption(name: "bash", path: "/bin/bash"),
        ShellOption(name: "fish", path: "/usr/local/bin/fish"),
        ShellOption(name: "fish (Homebrew)", path: "/opt/homebrew/bin/fish"),
        ShellOption(name: "nushell", path: "/usr/local/bin/nu"),
        ShellOption(name: "nushell (Homebrew)", path: "/opt/homebrew/bin/nu"),
    ]

    private static let shellPathKey = "terminalShellPath"
    private static let shellArgsKey = "terminalShellArgs"

    private static var defaultShellPath: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static let defaultShellArgs = ["--login"]

    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

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
