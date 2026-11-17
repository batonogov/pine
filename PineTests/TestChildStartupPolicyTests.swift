//
//  TestChildStartupPolicyTests.swift
//  PineTests
//
//  Issue #1792: unit coverage for the private test-host startup policy.
//  Real-PTY owned-marker coverage lives in
//  DefaultTerminalStartupIsolationTests.
//

import Foundation
import Testing

@testable import Pine

@Suite("Private test child startup policy")
struct TestChildStartupPolicyTests {
    @Test func sanitizesOnlyChildStartupConfiguration() {
        let inherited = [
            "HOME": "/owned/home", "PATH": "/usr/bin:/bin", "LANG": "C",
            "BASH_ENV": "/owned/hook", "ENV": "/owned/hook",
            "INPUTRC": "/owned/inputrc", "ZDOTDIR": "/owned/zsh",
            "PROMPT_COMMAND": "unexpected", "PS1": "$(unexpected)",
            "SHELLOPTS": "xtrace", "BASHOPTS": "extdebug",
            "BASH_FUNC_hook%%": "() { unexpected; }",
            "HISTFILE": "/owned/history",
        ]
        let environment = TestChildStartupPolicy.environment(from: inherited)
        for key in ["HOME", "PATH", "LANG"] {
            #expect(environment[key] == inherited[key])
        }
        for key in ["BASH_ENV", "ENV", "INPUTRC", "ZDOTDIR", "PROMPT_COMMAND",
                    "SHELLOPTS", "BASHOPTS", "BASH_FUNC_hook%%"] {
            #expect(environment[key] == nil)
        }
        #expect(environment["PS1"] == "")
        #expect(environment["HISTFILE"] == "/dev/null")
        #expect(environment["HISTSIZE"] == "0")
        #expect(inherited["HISTFILE"] == "/owned/history")
    }

    @Test @MainActor func defaultDoesNotMutateShellPreferences() throws {
        let suite = "TestChildStartupPolicy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/zsh"
        settings.shellArgs = ["--login"]
        let tab = TerminalTab(name: "Controlled default", shellSettings: settings)
        defer { tab.stop() }
        // The private test host overrides the default child without
        // touching the user's stored selection.
        #expect(tab.resolvedInitialProcess == TerminalInitialProcess(
            executablePath: "/bin/bash",
            arguments: ["--noprofile", "--norc", "--noediting", "-i"]
        ))
        #expect(settings.shellPath == "/bin/zsh")
        #expect(settings.shellArgs == ["--login"])
        #expect(defaults.stringArray(forKey: "terminalShellArgs") == ["--login"])
        #expect(tab.buildEnvironment()["HISTFILE"] == "/dev/null")
        #expect(tab.buildEnvironment()["PROMPT_COMMAND"] == nil)
    }
}
