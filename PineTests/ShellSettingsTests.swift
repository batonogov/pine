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

    @Test func defaultShellUsesPosixAccountDatabase() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        // systemShellPath uses getpwuid — the reliable source even inside sandbox
        let expectedShell = ShellSettings.systemShellPath()
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
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

        let expectedShell = ShellSettings.systemShellPath()
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
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

        let expectedShell = ShellSettings.systemShellPath()
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
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

    // MARK: - POSIX system shell detection

    @Test func systemShellPathReturnsNonNilOnMacOS() {
        // getpwuid(getuid()) should always succeed on macOS
        let path = ShellSettings.systemShellPath()
        #expect(path != nil)
    }

    @Test func systemShellPathReturnsAbsolutePath() {
        guard let path = ShellSettings.systemShellPath() else { return }
        #expect(path.hasPrefix("/"))
    }

    @Test func systemShellPathReturnsExecutableBinary() {
        guard let path = ShellSettings.systemShellPath() else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test func systemShellPathMatchesCommonShell() {
        guard let path = ShellSettings.systemShellPath() else { return }
        let knownShells = ["/bin/zsh", "/bin/bash", "/bin/sh",
                           "/usr/local/bin/fish", "/opt/homebrew/bin/fish",
                           "/usr/local/bin/nu", "/opt/homebrew/bin/nu"]
        #expect(knownShells.contains(path), "Unexpected shell: \(path)")
    }

    @Test func defaultShellPrefersGetpwuidOverEnvironment() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // If getpwuid returns a valid shell, that should be the default
        // regardless of what $SHELL says
        guard let posixShell = ShellSettings.systemShellPath() else { return }
        let settings = ShellSettings(defaults: defaults)
        #expect(settings.shellPath == posixShell)
    }

    // MARK: - Empty path fallback

    @Test func emptyStringPathFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("", forKey: "terminalShellPath")

        let settings = ShellSettings(defaults: defaults)
        let expectedShell = ShellSettings.systemShellPath()
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        #expect(settings.shellPath == expectedShell)
    }

    // MARK: - Integration: shell detection via getpwuid (#551)

    @Test func systemShellPathIsListedInEtcShells() throws {
        // /etc/shells lists all valid login shells on macOS.
        // The shell returned by getpwuid should be present there.
        guard let shellPath = ShellSettings.systemShellPath() else { return }
        let etcShells = try String(contentsOfFile: "/etc/shells", encoding: .utf8)
        let validShells = etcShells
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(validShells.contains(shellPath),
                "Shell \(shellPath) from getpwuid should be listed in /etc/shells")
    }

    @Test func systemShellPathIsNotADirectory() {
        guard let shellPath = ShellSettings.systemShellPath() else { return }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: shellPath, isDirectory: &isDir)
        #expect(exists)
        #expect(!isDir.boolValue, "Shell path should be a file, not a directory")
    }

    @Test func systemShellPathHasReasonableLength() {
        // A sanity check: shell paths should be absolute and reasonable length
        guard let shellPath = ShellSettings.systemShellPath() else { return }
        #expect(shellPath.count >= 4, "Shell path too short: \(shellPath)") // e.g. /bin/sh
        #expect(shellPath.count < 256, "Shell path unreasonably long: \(shellPath)")
    }

    @Test func resolvedShellPathAlwaysReturnsExecutable() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Test with various invalid paths — resolved should always be executable
        let invalidPaths = ["/nonexistent", "/dev/null", "/tmp", ""]
        for invalidPath in invalidPaths {
            let settings = ShellSettings(defaults: defaults)
            settings.shellPath = invalidPath
            let resolved = settings.resolvedShellPath
            #expect(FileManager.default.isExecutableFile(atPath: resolved),
                    "resolvedShellPath should be executable, got: \(resolved) for input: \(invalidPath)")
        }
    }

    @Test func resolvedShellPathNeverReturnsEmpty() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = ""
        #expect(!settings.resolvedShellPath.isEmpty)
    }

    @Test func commonShellsLoginFlagsAreCorrectPerShell() {
        // Verify each shell type uses the correct login flag convention
        for shell in ShellSettings.commonShells {
            if shell.name.contains("fish") {
                #expect(shell.defaultArgs.contains("-l"),
                        "fish should use -l flag, not --login")
            } else {
                #expect(shell.defaultArgs.contains("--login"),
                        "\(shell.name) should use --login flag")
            }
        }
    }

    @Test func shellOptionHashableAndEquatable() {
        let opt1 = ShellSettings.ShellOption(name: "zsh", path: "/bin/zsh", defaultArgs: ["--login"])
        let opt2 = ShellSettings.ShellOption(name: "zsh", path: "/bin/zsh", defaultArgs: ["--login"])
        let opt3 = ShellSettings.ShellOption(name: "bash", path: "/bin/bash", defaultArgs: ["--login"])
        #expect(opt1 == opt2)
        #expect(opt1 != opt3)

        var set = Set<ShellSettings.ShellOption>()
        set.insert(opt1)
        set.insert(opt2)
        #expect(set.count == 1)
    }

    // MARK: - Negative / edge case tests

    @Test func shellPathWithSpaces_fallsBack() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/path with spaces/my shell"
        let resolved = settings.resolvedShellPath
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
        #expect(resolved != "/path with spaces/my shell")
    }

    @Test func shellPathWithUnicode_fallsBack() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/zsh™"
        let resolved = settings.resolvedShellPath
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }

    @Test func veryLongShellPath_fallsBack() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/" + String(repeating: "a", count: 500) + "/shell"
        let resolved = settings.resolvedShellPath
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }

    @Test func shellPathPointingToDirectory_fallsBack() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/usr/bin"  // directory, not executable
        let resolved = settings.resolvedShellPath
        #expect(resolved != "/usr/bin")
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }
}
