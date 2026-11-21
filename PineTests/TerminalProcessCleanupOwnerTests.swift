//
//  TerminalProcessCleanupOwnerTests.swift
//  PineTests
//
//  Regressions for detached process-cleanup ownership (#1786): the
//  pre-termination barrier must account for cleanup whose tab or manager is
//  already gone, and owner records must neither leak nor be released before
//  the cleanup actually finishes.
//

import AppKit
import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Detached terminal process-cleanup ownership", .serialized)
@MainActor
struct TerminalProcessCleanupOwnerTests {
    nonisolated private static let ptyFixtureScript =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Terminal/pty-process-tree.sh")

    @Test("removing a tab keeps its in-flight cleanup in the Quit barrier")
    func removingTabKeepsDetachedCleanupInQuitBarrier() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "pine-detached-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let traceURL = directoryURL.appending(path: "process.trace")

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

        let ownerRegistry = TerminalProcessCleanupOwnerRegistry()
        let paneState = TerminalPaneState()
        let tab = paneState.addTab(
            workingDirectory: directoryURL,
            initialProcess: TerminalInitialProcess(
                executablePath: "/bin/sh",
                arguments: [
                    Self.ptyFixtureScript.path,
                    "tree",
                    traceURL.path,
                ]
            )
        )
        tab.processCleanupOwnerRegistry = ownerRegistry
        defer { paneState.removeTab(id: tab.id) }
        tab.terminalView.frame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 300
        )
        tab.startIfNeeded()
        guard tab.isProcessRunning,
              let controller = tab.processTreeControllerForTesting else {
            tab.stop()
            throw PTYFixtureError.processDidNotStart
        }
        let child = try #require(await PTYFixtureTrace.wait(
            for: "child-ready",
            at: traceURL
        ))
        let childIdentity = try #require(child.identity)

        // Close the tab through the real removal path: `stop()` starts the
        // in-flight cleanup and the inventory drops the owner.
        paneState.removeTab(id: tab.id)
        #expect(paneState.terminalTabs.isEmpty)
        #expect(PTYFixtureTrace.identityIsLive(childIdentity))

        // Drive the actual AppDelegate Quit transaction. Its live inventory is
        // empty, so only the injected detached-owner registry can find this tab.
        let appDelegate = AppDelegate()
        appDelegate.registry = ProjectRegistry()
        appDelegate.terminalProcessCleanupOwnerRegistry = ownerRegistry
        var presentedFailure = false
        let quitCompleted = await appDelegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                if template == .applicationQuitFailure {
                    presentedFailure = true
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 10
        )
        #expect(quitCompleted)
        #expect(!presentedFailure)
        #expect(!PTYFixtureTrace.identityIsLive(childIdentity))
        #expect(PTYFixtureTrace.identityIsLive(unrelatedIdentity))
        #expect(!ownerRegistry.inFlightControllers.contains { $0 === controller })
    }

    @Test("application termination waits for a suspended detached owner")
    func applicationTerminationWaitsForSuspendedDetachedOwner() async throws {
        let retention = TerminalWorkingDirectoryRetention(
            canonicalDirectory: FileManager.default.temporaryDirectory
        )
        let releaseCleanup = DispatchSemaphore(value: 0)
        defer {
            releaseCleanup.signal()
            retention.finishCleanup(succeeded: true)
        }
        let ownerRegistry = TerminalProcessCleanupOwnerRegistry()
        let controller = TerminalProcessTreeController(
            retention: retention,
            ownerRegistry: ownerRegistry,
            cleanupForTesting: { false },
            deferredCleanupForTesting: {
                _ = releaseCleanup.wait(timeout: .now() + 5)
            }
        )
        controller.requestTermination()

        let boundedResult = await Task.detached(priority: .utility) {
            controller.waitForTermination(timeout: 1)
        }.value
        #expect(!boundedResult)
        // Fail-closed while the suspended deferred cleanup is in flight.
        #expect(retention.isRetained)

        // No tab or manager references this owner any more; only the
        // detached-owner record keeps it in the barrier.
        let barrierControllers = ownerRegistry
            .applicationTerminationControllers(from: [])
        #expect(barrierControllers.contains { $0 === controller })

        // Wait on this exact owner, not the process-wide registry snapshot,
        // so a sibling suite's in-flight owner cannot consume the deadline.
        // A timed-out cleanup must produce a truthful failure, not a
        // successful termination (#1786).
        let missedDeadline = await TerminalTabCloseAuthorization
            .waitForAuthorizedStops([controller], until: .now() + 0.2)
        #expect(!missedDeadline)
        #expect(retention.isRetained)

        releaseCleanup.signal()
        let completed = await TerminalTabCloseAuthorization
            .waitForAuthorizedStops([controller], until: .now() + 5)
        #expect(completed)
        #expect(!retention.isRetained)
        #expect(!ownerRegistry.inFlightControllers.contains { $0 === controller })
    }

    @Test("multi-element deferred cleanup releases the owner once, after all works")
    func multiElementDeferredCleanupPublishesOnceAfterAllWorks() async throws {
        let retention = TerminalWorkingDirectoryRetention(
            canonicalDirectory: FileManager.default.temporaryDirectory
        )
        defer { retention.finishCleanup(succeeded: true) }
        let ownerRegistry = TerminalProcessCleanupOwnerRegistry()
        let started = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        let release = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        let finished = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        defer { release.forEach { $0.signal() } }
        let works: [@Sendable () -> Void] = (0..<3).map { index in
            {
                started[index].signal()
                _ = release[index].wait(timeout: .now() + 10)
                finished[index].signal()
            }
        }
        let controller = TerminalProcessTreeController(
            retention: retention,
            ownerRegistry: ownerRegistry,
            cleanupForTesting: { false },
            deferredCleanupWorksForTesting: works
        )
        controller.requestTermination()

        for semaphore in started {
            let waitForEntry: @Sendable () -> Bool = {
                semaphore.wait(timeout: .now() + 5) == .success
            }
            let entered = await Task.detached(
                priority: .utility,
                operation: waitForEntry
            ).value
            try #require(entered)
        }
        #expect(ownerRegistry.releaseCountForTesting(controller) == 0)

        for index in 0..<2 {
            release[index].signal()
            let waitForCompletion: @Sendable () -> Bool = {
                finished[index].wait(timeout: .now() + 5) == .success
            }
            let completed = await Task.detached(
                priority: .utility,
                operation: waitForCompletion
            ).value
            try #require(completed)
            #expect(ownerRegistry.releaseCountForTesting(controller) == 0)
            #expect(ownerRegistry.inFlightControllers.contains { $0 === controller })
            #expect(retention.isRetained)
        }

        release[2].signal()
        let published = await Task.detached(priority: .utility) {
            let deadline = DispatchTime.now() + 5
            while ownerRegistry.releaseCountForTesting(controller) == 0,
                  DispatchTime.now() < deadline {
                Darwin.usleep(10_000)
            }
            return ownerRegistry.releaseCountForTesting(controller)
        }.value
        #expect(published == 1)
        #expect(!ownerRegistry.inFlightControllers.contains { $0 === controller })
        #expect(!retention.isRetained)
        #expect(!controller.waitForTermination(timeout: 0))
    }

    @Test("repeated close and completion do not leak owner records")
    func repeatedCloseDoesNotLeakOwnerRecords() async throws {
        let retention = TerminalWorkingDirectoryRetention(
            canonicalDirectory: FileManager.default.temporaryDirectory
        )
        defer { retention.finishCleanup(succeeded: true) }
        // Hold the bounded phase until the registry reads below have run:
        // the success-path release is asynchronous on the state queue, and
        // an ungated read could observe the record already gone.
        let phaseGate = DispatchSemaphore(value: 0)
        let ownerRegistry = TerminalProcessCleanupOwnerRegistry()
        let controller = TerminalProcessTreeController(
            retention: retention,
            ownerRegistry: ownerRegistry,
            cleanupForTesting: {
                _ = phaseGate.wait(timeout: .now() + 5)
                return true
            }
        )
        controller.requestTermination()
        controller.requestTermination()
        controller.requestTermination()

        let recorded = ownerRegistry.inFlightControllers
            .filter { $0 === controller }
            .count
        #expect(recorded == 1)

        // A controller present in both the live list and the detached-owner
        // registry must merge to a single element (#1786).
        let merged = ownerRegistry
            .applicationTerminationControllers(from: [controller])
        #expect(merged.filter { $0 === controller }.count == 1)

        // Release the held bounded phase; the success path then removes the
        // record, which the termination assertions below verify.
        phaseGate.signal()

        let finished = await Task.detached(priority: .utility) {
            controller.waitForTermination(timeout: 2)
        }.value
        #expect(finished)
        #expect(!retention.isRetained)
        #expect(!ownerRegistry.inFlightControllers.contains { $0 === controller })
    }
}
