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
            for: "child",
            at: traceURL
        ))
        let childIdentity = try #require(child.identity)

        // Close the tab through the real removal path: `stop()` starts the
        // in-flight cleanup and the inventory drops the owner.
        paneState.removeTab(id: tab.id)
        #expect(paneState.terminalTabs.isEmpty)
        #expect(PTYFixtureTrace.identityIsLive(childIdentity))

        // The barrier application Quit computes: controllers stopped from the
        // live inventory (empty — the tab is gone) plus the detached
        // in-flight owners. The removed tab's owner must still be found
        // (#1786).
        let barrierControllers = TerminalProcessCleanupOwnerRegistry
            .applicationTerminationControllers(from: [])
        #expect(barrierControllers.contains { $0 === controller })

        // Wait on this exact owner so a sibling suite's in-flight cleanup
        // cannot consume the deadline; the registry membership is pinned above.
        let quitCompleted = await TerminalTabCloseAuthorization
            .waitForAuthorizedStops([controller], until: .now() + 10)
        #expect(quitCompleted)
        #expect(!PTYFixtureTrace.identityIsLive(childIdentity))
        #expect(PTYFixtureTrace.identityIsLive(unrelatedIdentity))
        #expect(!TerminalProcessCleanupOwnerRegistry
            .shared.inFlightControllers.contains { $0 === controller })
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
        let controller = TerminalProcessTreeController(
            retention: retention,
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
        let barrierControllers = TerminalProcessCleanupOwnerRegistry
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
        #expect(!TerminalProcessCleanupOwnerRegistry
            .shared.inFlightControllers.contains { $0 === controller })
    }

    @Test("multi-element deferred cleanup releases the owner once, after all works")
    func multiElementDeferredCleanupPublishesOnceAfterAllWorks() async throws {
        // No deferredCleanupForTesting seam: the real multi-element list
        // (nil-group no-op, pid-0 descendant no-op, pid-0 root no-op) runs,
        // so the frozen work total must cover every element before the owner
        // record drops (#1786).
        for _ in 0..<5 {
            let retention = TerminalWorkingDirectoryRetention(
                canonicalDirectory: FileManager.default.temporaryDirectory
            )
            defer { retention.finishCleanup(succeeded: true) }
            let controller = TerminalProcessTreeController(
                retention: retention,
                cleanupForTesting: { false }
            )
            controller.requestTermination()

            // The owner record drops only after every work has returned;
            // poll with a bounded deadline and fail closed on it (#1786).
            let released = await Task.detached(priority: .utility) {
                let deadline = DispatchTime.now() + 5
                let stillTracked = {
                    TerminalProcessCleanupOwnerRegistry
                        .shared.inFlightControllers
                        .contains { $0 === controller }
                }
                while stillTracked(), DispatchTime.now() < deadline {
                    Darwin.usleep(10_000)
                }
                return !stillTracked()
            }.value
            #expect(released)

            // A bounded failure stays fail-closed: the fence is retained
            // (the Quit path commits it) and the termination truth is a
            // truthful failure, never a published success (#1786).
            #expect(retention.isRetained)
            #expect(!controller.waitForTermination(timeout: 0))
        }
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
        let controller = TerminalProcessTreeController(
            retention: retention,
            cleanupForTesting: {
                _ = phaseGate.wait(timeout: .now() + 5)
                return true
            }
        )
        controller.requestTermination()
        controller.requestTermination()
        controller.requestTermination()

        let recorded = TerminalProcessCleanupOwnerRegistry
            .shared.inFlightControllers
            .filter { $0 === controller }
            .count
        #expect(recorded == 1)

        // A controller present in both the live list and the detached-owner
        // registry must merge to a single element (#1786). Unrelated
        // in-flight owners from other tests may also appear in the shared
        // registry; the invariant is this controller's deduplication, not
        // an empty registry.
        let merged = TerminalProcessCleanupOwnerRegistry
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
        #expect(!TerminalProcessCleanupOwnerRegistry
            .shared.inFlightControllers.contains { $0 === controller })
    }
}
