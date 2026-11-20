//
//  DefaultTerminalStartupIsolationTests.swift
//  PineTests
//
//  Issue #1792: the default isolated terminal must not invoke
//  user-selected startup hooks, while explicitly configured owned
//  fixtures keep their exact argv contract.
//
//  This file deliberately uses only base APIs so the same test proves
//  RED-on-base / GREEN-on-candidate: on the base build the default
//  terminal honors the user-selected shell argv and sources the rcfile
//  hook, so the owned marker file appears; the candidate's test-host
//  override must prevent it. Inherited-env hook vectors are covered
//  without process-global mutation by TestChildStartupPolicyTests.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Default test terminal startup isolation (#1792)", .serialized)
@MainActor
struct DefaultTerminalStartupIsolationTests {
    @Test("default terminal ignores user-selected startup hooks on a real PTY")
    func defaultTerminalIgnoresUserStartupHooks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pine-startup-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appending(path: "startup.sh")
        let marker = directory.appending(path: "startup.marker")
        // The marker path is baked into the owned hook: the test must not
        // mutate the process-global environment (cross-suite flake window).
        try "printf 'hooked:%s\\n' \"${1:-prompt}\" > \"\(marker.path)\"\n"
            .write(to: hook, atomically: true, encoding: .utf8)

        let defaultsDomain = "StartupIsolationSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let settings = ShellSettings(defaults: defaults)
        // A user-selected startup hook: the base build's default terminal
        // honors this argv and reads the rcfile.
        settings.shellPath = "/bin/bash"
        settings.shellArgs = ["--rcfile", hook.path]

        let tab = TerminalTab(
            name: "Startup isolation", shellSettings: settings
        )
        defer { tab.stop() }
        tab.configure(workingDirectory: directory)
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.startIfNeeded()
        #expect(
            await waitUntilMainActor { tab.isProcessRunning },
            "the real owned PTY must start the default test terminal"
        )
        let controller = try #require(tab.processTreeControllerForTesting)
        let rootIdentity = controller.rootIdentity

        // The live PTY must accept controlled commands.
        try #require(tab.sendText("printf 'pine-startup-probe-1792'\n"))
        #expect(
            await waitForTerminalMarker(tab, "pine-startup-probe-1792"),
            "the default test terminal must echo controlled input"
        )
        // shortcut: 300ms prompt-cycle settle before the negative marker
        // check; replace with a controlled second command if base-RED
        // ever flakes.
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "user-selected startup hooks must not be invoked by the default test terminal"
        )

        // Generation-qualified ownership must clean up the exact process.
        // The bounded phase may legitimately escalate to the deferred KILL,
        // so assert the termination contract (bounded or deferred), not the
        // bounded phase's truth within a short window (#1792 CI).
        tab.stop()
        #expect(
            await Task.detached(priority: .utility) {
                controller.waitForApplicationTermination(timeout: 5)
            }.value,
            "the owned PTY process tree must terminate"
        )
        #expect(
            UserTaskProcessInspector.identity(for: rootIdentity.processID)
                != rootIdentity,
            "the exact shell generation must be gone"
        )
        #expect(!tab.hasAcknowledgedPTYLeaseForTesting)
    }

    @Test("explicit owned fixture keeps its argv contract on a real PTY")
    func explicitFixtureKeepsArgvContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pine-startup-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appending(path: "fixture.sh")
        let marker = directory.appending(path: "fixture.marker")
        // Marker path baked into the owned hook: no process-global
        // environment mutation (same flake-window rule as test 1).
        try "printf 'hooked:%s\\n' \"$1\" > \"\(marker.path)\"\n"
            .write(to: hook, atomically: true, encoding: .utf8)

        let tab = TerminalTab(name: "Owned fixture")
        defer { tab.stop() }
        let explicit = TerminalInitialProcess(
            executablePath: "/bin/bash",
            arguments: [hook.path, "fixture-arg"]
        )
        tab.configure(workingDirectory: directory, initialProcess: explicit)
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.startIfNeeded()
        #expect(
            tab.configuredInitialProcess == explicit,
            "the explicit owned process must be preserved"
        )
        #expect(
            await waitUntilMainActor { tab.isTerminated },
            "the owned fixture must run and exit on its own"
        )
        #expect(
            try String(contentsOf: marker, encoding: .utf8)
                == "hooked:fixture-arg\n",
            "the explicit fixture must execute its owned script with its argument"
        )
        #expect(!tab.hasAcknowledgedPTYLeaseForTesting)
    }

    private func waitForTerminalMarker(
        _ tab: TerminalTab,
        _ marker: String,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = DispatchTime.now() + timeout
        repeat {
            await tab.search(for: marker)
            if !tab.searchMatches.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while DispatchTime.now() < deadline
        return false
    }
}
