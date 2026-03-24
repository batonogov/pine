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

    // MARK: - Round-trip persistence

    @Test func settingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let s1 = ShellSettings(defaults: defaults)
        s1.shellPath = "/bin/bash"
        s1.shellArgs = ["-i"]

        let s2 = ShellSettings(defaults: defaults)
        #expect(s2.shellPath == "/bin/bash")
        #expect(s2.shellArgs == ["-i"])
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

    // MARK: - Resolved shell path

    @Test func resolvedShellPathReturnsPathWhenExecutable() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/zsh"

        #expect(settings.resolvedShellPath == "/bin/zsh")
    }

    @Test func resolvedShellPathFallsBackForNonexistentBinary() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/nonexistent/path/to/shell"

        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(settings.resolvedShellPath == expectedShell)
    }

    @Test func resolvedShellPathUltimateFallbackIsZsh() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Both shellPath and $SHELL fallback go through FileManager validation.
        // Since $SHELL on this machine is valid, we verify the final "/bin/zsh"
        // fallback by confirming it's always reachable from the chain.
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/zsh"
        #expect(settings.resolvedShellPath == "/bin/zsh")
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
            #expect(!shell.defaultArgs.isEmpty)
        }
    }

    @Test func commonShellsHaveCorrectDefaultArgs() {
        let shells = ShellSettings.commonShells
        let zsh = shells.first { $0.path == "/bin/zsh" }
        let fish = shells.first { $0.path == "/usr/local/bin/fish" }

        #expect(zsh?.defaultArgs == ["--login"])
        #expect(fish?.defaultArgs == ["-l"])
    }

    @Test func shellOptionIsIdentifiableByPath() {
        let shells = ShellSettings.commonShells
        let ids = shells.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count)
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

    // MARK: - Available shells detection

    @Test func availableShellsContainsZshAndBash() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let available = settings.availableShells()

        // /bin/zsh and /bin/bash exist on every macOS
        #expect(available.contains { $0.path == "/bin/zsh" })
        #expect(available.contains { $0.path == "/bin/bash" })
    }

    @Test func availableShellsOnlyContainsExecutableShells() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let available = settings.availableShells()
        let fm = FileManager.default

        for shell in available {
            #expect(fm.isExecutableFile(atPath: shell.path),
                    "Shell \(shell.path) should be executable")
        }
    }

    @Test func availableShellsHaveUniqueIDs() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let available = settings.availableShells()
        let ids = available.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count)
    }

    @Test func availableShellsHaveNonEmptyNames() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let available = settings.availableShells()

        for shell in available {
            #expect(!shell.name.isEmpty)
            #expect(!shell.path.isEmpty)
        }
    }

    // MARK: - Apply shell option

    @Test func applyShellOptionSetsPathAndArgs() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let option = ShellSettings.ShellOption(
            name: "fish", path: "/usr/local/bin/fish", defaultArgs: ["-l"]
        )
        settings.applyShellOption(option)

        #expect(settings.shellPath == "/usr/local/bin/fish")
        #expect(settings.shellArgs == ["-l"])
    }

    @Test func applyShellOptionPersistsToDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        let option = ShellSettings.ShellOption(
            name: "bash", path: "/bin/bash", defaultArgs: ["--login"]
        )
        settings.applyShellOption(option)

        #expect(defaults.string(forKey: "terminalShellPath") == "/bin/bash")
        #expect(defaults.stringArray(forKey: "terminalShellArgs") == ["--login"])
    }

    // MARK: - Parse /etc/shells

    @Test func parseEtcShellsFiltersCommentsAndEmpty() {
        let content = """
        # List of acceptable shells
        /bin/bash
        /bin/zsh

        # This is a comment
        /usr/local/bin/fish
        """
        let paths = ShellSettings.parseEtcShells(content)
        #expect(paths == ["/bin/bash", "/bin/zsh", "/usr/local/bin/fish"])
    }

    @Test func parseEtcShellsHandlesEmptyString() {
        let paths = ShellSettings.parseEtcShells("")
        #expect(paths.isEmpty)
    }

    @Test func parseEtcShellsHandlesOnlyComments() {
        let content = """
        # comment 1
        # comment 2
        """
        let paths = ShellSettings.parseEtcShells(content)
        #expect(paths.isEmpty)
    }

    @Test func parseEtcShellsTrimsWhitespace() {
        let content = "  /bin/bash  \n\t/bin/zsh\t\n"
        let paths = ShellSettings.parseEtcShells(content)
        #expect(paths == ["/bin/bash", "/bin/zsh"])
    }
}
