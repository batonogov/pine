import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Pine

@Suite("Terminal working-directory launch fences", .serialized)
@MainActor
struct TerminalWorkingDirectoryRetentionTests {
    @Test("Project-owned terminal launch remains synchronous")
    func projectOwnedLaunchIsSynchronous() {
        let directory = URL(fileURLWithPath: "/pine-sync-\(UUID())", isDirectory: true)
        let tab = TerminalTab(name: "Synchronous project launch")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.configure(workingDirectory: directory)
        var launched = false
        tab.checkedProcessLaunchForTesting = {
            launched = true
            return .failure(.forkFailed(EAGAIN))
        }
        defer { tab.stop(); tab.finishWorkingDirectoryRetentionForTesting() }
        tab.startIfNeeded()
        #expect(launched)
        #expect(!tab.isStartValidationPendingForTesting)
        #expect(!TerminalWorkingDirectoryRetention.retainsDirectory(in: directory))
    }

    @Test("Only checked fork failure proves no child", arguments: 0..<4)
    func checkedLaunchOutcome(outcome: Int) async throws {
        let directory = URL(fileURLWithPath: "/pine-launch-fence-\(UUID())", isDirectory: true)
        let tab = TerminalTab(name: "Checked launch")
        tab.configure(workingDirectory: directory)
        let result: Result<Void, LocalProcessError>
        switch outcome {
        case 0: result = .failure(.forkFailed(EAGAIN))
        case 1: result = .failure(.writeChannelFailed(EMFILE))
        case 2: result = .failure(.alreadyRunning)
        default: result = .success(())
        }
        var launched = false
        tab.checkedProcessLaunchForTesting = {
            // The real generation fence must exist before the checked call.
            #expect(TerminalWorkingDirectoryRetention.retainsDirectory(in: directory))
            launched = true
            return result
        }
        tab.startIfNeeded()
        let completed = await waitUntilMainActor { launched && !tab.isStartValidationPendingForTesting }
        #expect(completed)
        #expect(tab.terminalView.process.shellPid == 0)
        #expect(tab.processTreeControllerForTesting == nil)
        #expect(tab.requiresWorkingDirectoryRetention == (outcome != 0))
        #expect(TerminalWorkingDirectoryRetention.retainsDirectory(in: directory) == (outcome != 0))
        tab.stop()
        #expect(TerminalWorkingDirectoryRetention.retainsDirectory(in: directory) == (outcome != 0))
        // Positive test-only teardown, never production uncertainty cleanup.
        tab.finishWorkingDirectoryRetentionForTesting()
    }

    @Test("Reconfiguring a pending start permits exactly one retry", arguments: [false, true])
    func reconfigurePendingStart(changesDirectory: Bool) async throws {
        let directory = URL(fileURLWithPath: "/pine-pending-\(UUID())", isDirectory: true)
        let rebound = changesDirectory ? directory.appendingPathComponent("next") : directory
        let tab = TerminalTab(name: "Pending reconfiguration")
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.configure(workingDirectory: directory)
        tab.configureWorkingDirectoryValidation { _ in true }
        let gate = PendingDirectoryStartGate()
        tab.validationCommitSeamForTesting = { await gate.suspend() }
        var launches = 0
        tab.checkedProcessLaunchForTesting = {
            launches += 1
            return .failure(.forkFailed(EAGAIN))
        }
        defer {
            gate.release()
            tab.stop()
            tab.finishWorkingDirectoryRetentionForTesting()
        }
        tab.startIfNeeded()
        try #require(await waitUntilMainActor { gate.entered })
        tab.configure(workingDirectory: rebound)
        #expect(!tab.isStartValidationPendingForTesting)
        tab.validationCommitSeamForTesting = {}
        gate.release()
        tab.startIfNeeded()
        #expect(await waitUntilMainActor { launches == 1 && !tab.isStartValidationPendingForTesting })
        await Task.yield()
        #expect(launches == 1)
    }

    @Test("Cached identity survives alias retargeting and uses component boundaries")
    func cachedIdentityHotChecks() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pine-fence-\(UUID())")
        let owner = base.appendingPathComponent("owner", isDirectory: true)
        let sibling = base.appendingPathComponent("owner-other", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        for directory in [owner, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owner)
        let canonicalOwner = await Task.detached { ProjectRegistry.canonicalProjectURL(owner) }.value
        let canonicalSibling = await Task.detached { ProjectRegistry.canonicalProjectURL(sibling) }.value
        let tab = TerminalTab(name: "Aliased launch")
        tab.configure(workingDirectory: alias)
        tab.configureWorkingDirectoryValidation { _ in true }
        var launched = false
        tab.checkedProcessLaunchForTesting = {
            #expect(TerminalWorkingDirectoryRetention.retainsDirectory(in: canonicalOwner))
            launched = true
            return .success(())
        }
        tab.startIfNeeded()
        let completed = await waitUntilMainActor { launched && !tab.isStartValidationPendingForTesting }
        #expect(completed)
        defer { tab.stop(); tab.finishWorkingDirectoryRetentionForTesting() }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling)
        try FileManager.default.removeItem(at: owner)
        // Re-resolution would now lose the original owner. These hot checks
        // need only cached components, even after the filesystem changes.
        for _ in 0..<100 {
            #expect(TerminalWorkingDirectoryRetention.retainsDirectory(in: canonicalOwner))
            #expect(!TerminalWorkingDirectoryRetention.retainsDirectory(in: canonicalSibling))
        }
    }
}

@MainActor
private final class PendingDirectoryStartGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
