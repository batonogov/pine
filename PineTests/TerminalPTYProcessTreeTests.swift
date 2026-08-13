//
//  TerminalPTYProcessTreeTests.swift
//  PineTests
//

import AppKit
import Darwin
import Foundation
import Testing

@testable import Pine

nonisolated private struct PTYFixtureEvidence: Sendable {
    let phase: String
    let processID: pid_t
    let processGroupID: pid_t
    let identity: UserTaskProcessIdentity?
}

nonisolated private enum PTYFixtureError: Error {
    case processDidNotStart
    case processOwnershipUnavailable
}

nonisolated private enum PTYFixtureTrace {
    static func wait(
        for phase: String,
        at url: URL,
        timeout: TimeInterval = 3
    ) async -> PTYFixtureEvidence? {
        await Task.detached(priority: .utility) {
            let deadline = DispatchTime.now() + timeout
            repeat {
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8),
                   let evidence = parse(phase: phase, text: text) {
                    return evidence
                }
                Darwin.usleep(10_000)
            } while DispatchTime.now() < deadline
            return nil
        }.value
    }

    static func identityIsLive(_ identity: UserTaskProcessIdentity) -> Bool {
        UserTaskProcessInspector.identity(for: identity.processID) == identity
    }

    private static func parse(
        phase: String,
        text: String
    ) -> PTYFixtureEvidence? {
        for line in text.split(whereSeparator: { $0.isNewline }) {
            var values: [Substring: Substring] = [:]
            for field in line.split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                values[pair[0]] = pair[1]
            }
            guard values["phase"] == Substring(phase),
                  let processText = values["pid"],
                  let groupText = values["pgid"],
                  let processID = pid_t(processText),
                  let processGroupID = pid_t(groupText) else {
                continue
            }
            return PTYFixtureEvidence(
                phase: phase,
                processID: processID,
                processGroupID: processGroupID,
                identity: UserTaskProcessInspector.identity(for: processID)
            )
        }
        return nil
    }
}

@MainActor
private final class TerminalPTYFixtureHarness {
    let tab: TerminalTab
    let traceURL: URL
    let directoryURL: URL
    let controller: TerminalProcessTreeController

    init(scenario: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "pine-pty-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        traceURL = directoryURL.appending(path: "process.trace")
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Terminal/pty-process-tree.sh")

        tab = TerminalTab(name: "PTY fixture")
        tab.configure(
            workingDirectory: directoryURL,
            initialProcess: TerminalInitialProcess(
                executablePath: "/bin/sh",
                arguments: [fixtureURL.path, scenario, traceURL.path]
            )
        )
        tab.terminalView.frame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 300
        )
        tab.startIfNeeded()
        guard tab.isProcessRunning else {
            tab.stop()
            try? FileManager.default.removeItem(at: directoryURL)
            throw PTYFixtureError.processDidNotStart
        }
        guard let controller = tab.processTreeControllerForTesting else {
            tab.stop()
            try? FileManager.default.removeItem(at: directoryURL)
            throw PTYFixtureError.processOwnershipUnavailable
        }
        self.controller = controller
    }

    func waitForTerminalMarker(
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

    func waitUntilTerminated(timeout: TimeInterval = 3) async -> Bool {
        let deadline = DispatchTime.now() + timeout
        repeat {
            if tab.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while DispatchTime.now() < deadline
        return tab.isTerminated
    }

    func stopAndWait(timeout: TimeInterval = 3) async -> Bool {
        tab.stop()
        return await Task.detached(priority: .utility) { [controller] in
            controller.waitForTermination(timeout: timeout)
        }.value
    }

    func cleanup() {
        tab.stop()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@Suite("Terminal PTY Process Tree", .serialized)
@MainActor
struct TerminalPTYProcessTreeTests {
    @Test("foreground PGID churn retains the terminal's process generation")
    func foregroundProcessGroupChurnRetainsOwnership() async throws {
        let harness = try TerminalPTYFixtureHarness(scenario: "churn")
        defer { harness.cleanup() }
        let ready = try #require(await PTYFixtureTrace.wait(
            for: "ready",
            at: harness.traceURL
        ))
        let child = try #require(await PTYFixtureTrace.wait(
            for: "foreground-child",
            at: harness.traceURL
        ))
        let rootIdentity = try #require(ready.identity)
        let childIdentity = try #require(child.identity)

        #expect(rootIdentity == harness.controller.rootIdentity)
        #expect(child.processGroupID > 1)
        #expect(child.processGroupID != ready.processGroupID)
        #expect(await harness.waitForTerminalMarker(
            "PINE_PTY_FIXTURE_READY:churn"
        ))
        #expect(await waitForForegroundGroup(
            child.processGroupID,
            in: harness.tab
        ))
        #expect(harness.tab.isProcessRunning)
        #expect(PTYFixtureTrace.identityIsLive(rootIdentity))
        #expect(PTYFixtureTrace.identityIsLive(childIdentity))

        try #require(harness.tab.sendText("\u{3}"))
        #expect(await harness.waitForTerminalMarker(
            "PINE_PTY_FIXTURE_FOREGROUND_RETURNED"
        ))
        #expect(harness.tab.isProcessRunning)
        #expect(await harness.stopAndWait())
        #expect(!PTYFixtureTrace.identityIsLive(rootIdentity))
        #expect(!PTYFixtureTrace.identityIsLive(childIdentity))
        #expect(!harness.tab.hasAcknowledgedPTYLeaseForTesting)
    }

    @Test("close escalates TERM to KILL for only the owned tree")
    func closeStopsExactOwnedTree() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        let unrelatedIdentity = try #require(
            UserTaskProcessInspector.identity(
                for: unrelated.processIdentifier
            )
        )
        defer {
            if unrelated.isRunning {
                unrelated.terminate()
                unrelated.waitUntilExit()
            }
        }

        let harness = try TerminalPTYFixtureHarness(scenario: "tree")
        defer { harness.cleanup() }
        let ready = try #require(await PTYFixtureTrace.wait(
            for: "ready",
            at: harness.traceURL
        ))
        let child = try #require(await PTYFixtureTrace.wait(
            for: "child",
            at: harness.traceURL
        ))
        let rootIdentity = try #require(ready.identity)
        let childIdentity = try #require(child.identity)
        #expect(child.processGroupID != ready.processGroupID)

        // Let the periodic ownership sampler observe the independent child
        // before closing the authorized terminal.
        try? await Task.sleep(for: .milliseconds(75))
        harness.tab.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(PTYFixtureTrace.identityIsLive(childIdentity))
        let controller = harness.controller
        let stopped = await Task.detached(priority: .utility) {
            controller.waitForTermination(timeout: 3)
        }.value

        #expect(stopped)
        #expect(!PTYFixtureTrace.identityIsLive(rootIdentity))
        #expect(!PTYFixtureTrace.identityIsLive(childIdentity))
        #expect(PTYFixtureTrace.identityIsLive(unrelatedIdentity))
        #expect(!harness.tab.hasAcknowledgedPTYLeaseForTesting)
    }

    @Test("replacement records a new exact process generation")
    func processReplacementChangesOwnedGeneration() async throws {
        let harness = try TerminalPTYFixtureHarness(scenario: "tree")
        defer { harness.cleanup() }
        _ = try #require(await PTYFixtureTrace.wait(
            for: "ready",
            at: harness.traceURL
        ))
        let first = try #require(await PTYFixtureTrace.wait(
            for: "child",
            at: harness.traceURL
        ))
        let firstIdentity = try #require(first.identity)

        try #require(harness.tab.sendText("replace\n"))
        #expect(await harness.waitForTerminalMarker(
            "PINE_PTY_FIXTURE_REPLACED"
        ))
        let replacement = try #require(await PTYFixtureTrace.wait(
            for: "replacement",
            at: harness.traceURL
        ))
        let replacementIdentity = try #require(replacement.identity)

        #expect(firstIdentity != replacementIdentity)
        #expect(!PTYFixtureTrace.identityIsLive(firstIdentity))
        #expect(PTYFixtureTrace.identityIsLive(replacementIdentity))
        try? await Task.sleep(for: .milliseconds(75))
        #expect(await harness.stopAndWait())
        #expect(!PTYFixtureTrace.identityIsLive(replacementIdentity))
    }

    @Test("partial UTF-8 and bounded output do not deadlock the PTY")
    func partialUTF8AndBackpressureComplete() async throws {
        let harness = try TerminalPTYFixtureHarness(scenario: "stream")
        defer { harness.cleanup() }
        let completed = try #require(await PTYFixtureTrace.wait(
            for: "stream-complete",
            at: harness.traceURL,
            timeout: 5
        ))
        let rootIdentity = try #require(completed.identity)

        #expect(await harness.waitForTerminalMarker(
            "✓STREAM",
            timeout: 5
        ))
        #expect(await harness.waitForTerminalMarker(
            "PINE_PTY_FIXTURE_STREAM_COMPLETE",
            timeout: 5
        ))
        #expect(harness.tab.isProcessRunning)
        #expect(await harness.stopAndWait())
        #expect(!PTYFixtureTrace.identityIsLive(rootIdentity))
        #expect(!harness.tab.hasAcknowledgedPTYLeaseForTesting)
    }

    @Test("natural success and failure reclaim orphan-prone children")
    func naturalExitPathsLeaveNoOwnedProcesses() async throws {
        for (command, phase) in [
            ("exit-success\n", "natural-success"),
            ("exit-failure\n", "natural-failure"),
        ] {
            let harness = try TerminalPTYFixtureHarness(scenario: "tree")
            defer { harness.cleanup() }
            let ready = try #require(await PTYFixtureTrace.wait(
                for: "ready",
                at: harness.traceURL
            ))
            let child = try #require(await PTYFixtureTrace.wait(
                for: "child",
                at: harness.traceURL
            ))
            let rootIdentity = try #require(ready.identity)
            let childIdentity = try #require(child.identity)
            try? await Task.sleep(for: .milliseconds(75))

            try #require(harness.tab.sendText(command))
            _ = try #require(await PTYFixtureTrace.wait(
                for: phase,
                at: harness.traceURL
            ))
            #expect(await harness.waitUntilTerminated())
            let controller = harness.controller
            let stopped = await Task.detached(priority: .utility) {
                controller.waitForTermination(timeout: 3)
            }.value

            #expect(stopped)
            #expect(!PTYFixtureTrace.identityIsLive(rootIdentity))
            #expect(!PTYFixtureTrace.identityIsLive(childIdentity))
            #expect(!harness.tab.hasAcknowledgedPTYLeaseForTesting)
        }
    }

    private func waitForForegroundGroup(
        _ expectedGroup: pid_t,
        in tab: TerminalTab,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = DispatchTime.now() + timeout
        repeat {
            if tab.foregroundProcessID == expectedGroup { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while DispatchTime.now() < deadline
        return tab.foregroundProcessID == expectedGroup
    }
}
