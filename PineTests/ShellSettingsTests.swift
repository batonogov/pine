//
//  ShellSettingsTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("ShellSettings Tests")
struct ShellSettingsTests {

    private let suiteName = "PineTests.Shell.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default values

    @Test func defaultShellUsesEnvironmentVariable() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(settings.shellPath == expectedShell)
    }

    @Test func defaultArgsAreLogin() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        #expect(settings.shellArgs == ["--login"])
    }

    // MARK: - Setting shell path

    @Test func setShellPathPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/bash"

        #expect(defaults.string(forKey: "terminalShellPath") == "/bin/bash")
    }

    @Test func setShellArgsPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellArgs = ["--login", "--interactive"]

        #expect(defaults.stringArray(forKey: "terminalShellArgs") == ["--login", "--interactive"])
    }

    // MARK: - Loading from UserDefaults

    @Test func shellPathLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("/usr/local/bin/fish", forKey: "terminalShellPath")

        let settings = ShellSettings(defaults: defaults)
        #expect(settings.shellPath == "/usr/local/bin/fish")
    }

    @Test func shellArgsLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(["--login", "-c", "echo hello"], forKey: "terminalShellArgs")

        let settings = ShellSettings(defaults: defaults)
        #expect(settings.shellArgs == ["--login", "-c", "echo hello"])
    }

    // MARK: - Reset

    @Test func resetRestoresDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/bash"
        settings.shellArgs = ["-i"]

        settings.reset()

        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(settings.shellPath == expectedShell)
        #expect(settings.shellArgs == ["--login"])
    }

    // MARK: - Common shells

    @Test func commonShellsContainsExpectedEntries() {
        let shells = ShellSettings.commonShells
        #expect(shells.contains { $0.path == "/bin/zsh" })
        #expect(shells.contains { $0.path == "/bin/bash" })
    }

    @Test func commonShellsHaveNonEmptyNames() {
        for shell in ShellSettings.commonShells {
            #expect(!shell.name.isEmpty)
            #expect(!shell.path.isEmpty)
        }
    }

    // MARK: - Empty path fallback

    @Test func emptyStringPathFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("", forKey: "terminalShellPath")

        let settings = ShellSettings(defaults: defaults)
        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(settings.shellPath == expectedShell)
    }
}
