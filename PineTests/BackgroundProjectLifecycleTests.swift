//
//  BackgroundProjectLifecycleTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

nonisolated private final class ProcessSnapshotRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func recordRun() -> ProcessRunResult {
        lock.withLock { storedCount += 1 }
        return ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }
}

@MainActor
private final class ControlledWorkspaceWatcher: WorkspaceFileWatching {
    private let callback: @MainActor () -> Void
    private(set) var isStopped = false

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func watch(directory _: URL) {
        isStopped = false
    }

    func stop() {
        isStopped = true
    }

    func emit() {
        guard !isStopped else { return }
        callback()
    }

    func emitIgnoringStop() {
        callback()
    }
}

@MainActor
private final class ControlledWorkspaceWatcherFactory {
    private(set) var watchers: [ControlledWorkspaceWatcher] = []

    func make(
        callback: @escaping @MainActor () -> Void
    ) -> any WorkspaceFileWatching {
        let watcher = ControlledWorkspaceWatcher(callback: callback)
        watchers.append(watcher)
        return watcher
    }
}

@Suite("Background Project Lifecycle", .serialized)
@MainActor
struct BackgroundProjectLifecycleTests {
    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }

    @Test("close and reopen suspend and resume editor services once")
    func suspendAndResumeAreIdempotent() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))

        #expect(manager.presentationLifecycle == .visible)
        #expect(!manager.workspace.isSuspended)
        #expect(manager.workspace.hasActiveFileWatcherForTesting)
        #expect(manager.recoveryManager?.isPeriodicSnapshotting == true)

        registry.closeProjectWindow(directory)
        registry.closeProjectWindow(directory)

        #expect(manager.presentationLifecycle == .backgroundSuspended)
        #expect(manager.workspace.isSuspended)
        #expect(!manager.workspace.hasActiveFileWatcherForTesting)
        #expect(manager.recoveryManager?.isPeriodicSnapshotting == false)
        #expect(manager.lspManager.presentationLifecycle == .backgroundSuspended)
        #expect(manager.editorServiceSuspendCountForTesting == 1)

        let reopened = try #require(registry.projectManager(for: directory))
        let reopenedAgain = try #require(registry.projectManager(for: directory))

        #expect(reopened === manager)
        #expect(reopenedAgain === manager)
        #expect(manager.presentationLifecycle == .visible)
        #expect(!manager.workspace.isSuspended)
        #expect(manager.workspace.hasActiveFileWatcherForTesting)
        #expect(manager.recoveryManager?.isPeriodicSnapshotting == true)
        #expect(manager.lspManager.presentationLifecycle == .active)
        #expect(manager.editorServiceResumeCountForTesting == 1)
    }

    @Test("key restored scene repairs a suspended empty file tree")
    func keySceneRepairsSuspendedTree() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        try "visible".write(
            to: directory.appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))

        registry.closeProjectWindow(directory)
        #expect(manager.presentationLifecycle == .backgroundSuspended)
        #expect(manager.workspace.isSuspended)

        #expect(registry.reconcileKeyProjectPresentation(manager))
        await waitUntil {
            manager.workspace.rootNodes.contains { $0.name == "visible.txt" }
        }

        #expect(registry.isWindowOpen(directory))
        #expect(manager.presentationLifecycle == .visible)
        #expect(!manager.workspace.isSuspended)
        #expect(manager.workspace.hasActiveFileWatcherForTesting)
        #expect(manager.workspace.rootNodes.contains {
            $0.name == "visible.txt"
        })
    }

    @Test("workspace watcher events are fenced while suspended and rearmed")
    func workspaceWatcherEventsFollowLifecycle() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let factory = ControlledWorkspaceWatcherFactory()
        let workspace = WorkspaceManager(fileWatcherFactory: { callback in
            factory.make(callback: callback)
        })
        workspace.loadDirectory(url: directory)
        let firstWatcher = try #require(factory.watchers.first)
        let initialToken = workspace.externalChangeToken

        firstWatcher.emit()
        #expect(workspace.externalChangeToken == initialToken + 1)

        workspace.suspend()
        #expect(firstWatcher.isStopped)
        firstWatcher.emitIgnoringStop()
        #expect(workspace.externalChangeToken == initialToken + 1)

        workspace.resume()
        let resumedWatcher = try #require(factory.watchers.last)
        #expect(resumedWatcher !== firstWatcher)
        resumedWatcher.emit()
        #expect(workspace.externalChangeToken == initialToken + 2)
    }

    @Test("application timer delivers one shared snapshot to two detectors")
    func processSnapshotIsSharedAcrossProjects() async throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }
        let counter = ProcessSnapshotRunCounter()
        let registry = makeRegistry(
            processRunner: { _, _, _, _ in counter.recordRun() },
            pollInterval: 3_600,
            initialPollDelay: 0.2
        )
        let first = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let second = try #require(
            registry.projectManager(for: secondDirectory)
        )

        first.terminal.ensureAgentDetectionStarted()
        second.terminal.ensureAgentDetectionStarted()

        #expect(registry.agentSnapshotSubscriberCountForTesting == 2)
        await waitUntil {
            first.terminal.receivedAgentSnapshotCountForTesting >= 1
                && second.terminal.receivedAgentSnapshotCountForTesting >= 1
        }
        let firstReceiptCount =
            first.terminal.receivedAgentSnapshotCountForTesting
        let secondReceiptCount =
            second.terminal.receivedAgentSnapshotCountForTesting
        #expect(registry.destroyAllProjects())
        #expect(counter.count == 1)
        #expect(firstReceiptCount == 1)
        #expect(secondReceiptCount == 1)
        #expect(registry.agentSnapshotSubscriberCountForTesting == 0)
    }

    @Test("live terminal keeps its exact manager, pane, tab, and PTY")
    func liveTerminalIdentitySurvivesBackgroundReclamation() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))
        let paneID = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: directory,
            initialProcess: TerminalInitialProcess(
                executablePath: "/bin/cat",
                arguments: []
            )
        )
        let state = try #require(
            manager.paneManager.terminalState(for: paneID)
        )
        let tab = try #require(state.activeTab)
        defer {
            tab.stop()
            _ = registry.destroyAllProjects()
        }
        tab.terminalView.frame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 300
        )
        tab.startIfNeeded()
        try #require(tab.isProcessRunning)
        let sentinel = "pine-scrollback-\(UUID().uuidString)"
        try #require(tab.sendText("\(sentinel)\n"))
        // The sentinel reaches the scrollback twice — the PTY echoes the line,
        // then `cat` writes it back — and the two arrive independently. Taking
        // the count at the first non-empty search recorded 1 on a slow runner
        // and 2 by the time the assertion below re-searched, which is how this
        // test failed with `2 == 1` one run in three (#1518). Wait for the
        // scrollback to settle instead of racing it: what this test is about
        // is that reclamation does not change the count, not what the count is.
        let matchCount = try #require(
            await settledMatchCount(for: sentinel, in: tab),
            "The sentinel never reached the terminal scrollback"
        )

        registry.closeProjectWindow(directory)
        registry.runBackgroundReclamationPassForTesting()

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(manager.paneManager.terminalState(for: paneID) === state)
        #expect(state.activeTab === tab)
        #expect(tab.isProcessRunning)
        await tab.search(for: sentinel)
        #expect(tab.searchMatches.count == matchCount)

        let reopened = try #require(registry.projectManager(for: directory))
        #expect(reopened === manager)
        #expect(reopened.paneManager.terminalState(for: paneID) === state)
        #expect(state.activeTab === tab)
        #expect(tab.isProcessRunning)
        await tab.search(for: sentinel)
        #expect(tab.searchMatches.count == matchCount)
    }

    /// The number of scrollback matches for `sentinel` once it stops
    /// changing, or `nil` if nothing ever arrived.
    ///
    /// "Settled" is a value that survives `stableChecks` consecutive searches.
    /// A terminal writes asynchronously through a PTY, so any single search is
    /// a sample of an animation, not a measurement.
    private func settledMatchCount(
        for sentinel: String,
        in tab: TerminalTab,
        within duration: Duration = .seconds(10),
        stableChecks: Int = 5
    ) async -> Int? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var lastCount = 0
        var stable = 0
        while clock.now < deadline {
            await tab.search(for: sentinel)
            let count = tab.searchMatches.count
            if count > 0, count == lastCount {
                stable += 1
                if stable >= stableChecks { return count }
            } else {
                stable = 0
            }
            lastCount = count
            try? await clock.sleep(for: .milliseconds(10))
        }
        return lastCount > 0 ? lastCount : nil
    }

    @Test("dirty project is retained when recovery is unavailable")
    func dirtyProjectFailsClosedWithoutRecovery() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let file = directory.appendingPathComponent("Dirty.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))
        manager.primaryTabManager.openTab(url: file)
        manager.primaryTabManager.updateContent("let value = 2\n")
        try #require(manager.allTabs.contains { $0.isDirty })
        manager.removeRecoveryManagerForTesting()

        registry.closeProjectWindow(directory)
        registry.runBackgroundReclamationPassForTesting()

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(manager.presentationLifecycle == .backgroundSuspended)
        #expect(manager.recoveryManager == nil)
        #expect(manager.allTabs.contains { $0.isDirty })
    }

    @Test("idle background projects are reclaimed by the bounded sweep")
    func idleProjectIsReclaimedAndCanBeReadmitted() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry(
            backgroundReclamationInterval: .milliseconds(10)
        )
        let original = try #require(registry.projectManager(for: directory))
        let canonical = registry.canonicalProjectURL(directory)

        registry.closeProjectWindow(directory)
        await waitUntil { registry.openProjects[canonical] == nil }

        #expect(original.presentationLifecycle == .destroyed)
        #expect(!registry.backgroundProjects.contains(canonical))
        let replacement = try #require(registry.projectManager(for: directory))
        #expect(replacement !== original)
        #expect(replacement.presentationLifecycle == .visible)
    }

    @Test("reclamation is capped per turn and eventually preserves sessions")
    func reclamationIsBatchedAndEventual() async throws {
        let directories = try (0..<7).map { _ in try makeTempDirectory() }
        defer {
            for directory in directories {
                SessionState.clear(for: directory)
                cleanup(directory)
            }
        }
        let registry = makeRegistry(
            backgroundReclamationInterval: .milliseconds(10),
            backgroundReclamationBatchSize: 2
        )
        let expectedFiles = try directories.enumerated().map { index, directory in
            let file = directory.appendingPathComponent("Project-\(index).swift")
            try "let project = \(index)\n".write(
                to: file,
                atomically: true,
                encoding: .utf8
            )
            return file
        }
        let managers = try zip(directories, expectedFiles).map { directory, file in
            let manager = try #require(registry.projectManager(for: directory))
            manager.primaryTabManager.openTab(url: file)
            return manager
        }
        for directory in directories {
            registry.closeProjectWindow(directory)
        }

        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.lastReclaimPassCountForTesting == 2)
        #expect(registry.openProjects.count == 5)
        await waitUntil { registry.openProjects.isEmpty }

        #expect(managers.allSatisfy {
            $0.presentationLifecycle == .destroyed
        })
        for (directory, expectedFile) in zip(directories, expectedFiles) {
            let canonical = registry.canonicalProjectURL(directory)
            let session = try #require(SessionState.load(for: canonical))
            #expect(session.existingFileURLs == [expectedFile])
        }
    }

    @Test("reclaim tombstones delayed terminal layout starts")
    func reclaimPermanentlyInvalidatesDelayedTerminalStart() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))
        let paneID = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: directory,
            initialProcess: TerminalInitialProcess(
                executablePath: "/bin/cat",
                arguments: []
            )
        )
        let state = try #require(manager.paneManager.terminalState(for: paneID))
        let tab = try #require(state.activeTab)
        #expect(!tab.isProcessRunning)

        registry.closeProjectWindow(directory)
        registry.runBackgroundReclamationPassForTesting()

        #expect(manager.presentationLifecycle == .destroyed)
        #expect(manager.terminal.isPermanentlyInvalidated)
        #expect(tab.isTerminated)
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.startIfNeeded()
        #expect(!tab.isProcessRunning)
    }

    @Test("stale scene lookup cannot admit a reclaimed manager")
    func staleSceneLookupDoesNotResurrectProject() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let original = try #require(registry.projectManager(for: directory))
        let canonical = registry.canonicalProjectURL(directory)

        registry.closeProjectWindow(directory)
        registry.runBackgroundReclamationPassForTesting()
        #expect(original.presentationLifecycle == .destroyed)
        #expect(registry.projectManagerIfAdmitted(for: directory) == nil)
        #expect(registry.openProjects[canonical] == nil)

        let explicitlyAdmitted = try #require(
            registry.projectManager(for: directory)
        )
        #expect(explicitlyAdmitted !== original)
    }

    @Test("delayed old-manager close cannot background its replacement")
    func staleCloseCannotBackgroundReplacementManager() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let original = try #require(registry.projectManager(for: directory))
        let oldWindow = makeWindow()
        let closeDelegate = CloseDelegate(
            projectManager: original,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate,
            original: nil
        )
        closeDelegate.observeWindowClose(oldWindow)
        defer { closeDelegate.detachFromWindow() }

        registry.closeProjectWindow(directory)
        registry.runBackgroundReclamationPassForTesting()
        let replacement = try #require(registry.projectManager(for: directory))
        #expect(replacement !== original)

        closeDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === replacement)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(replacement.presentationLifecycle == .visible)
    }

    @Test("delayed old-window close cannot background a newer generation")
    func staleCloseCannotBackgroundNewWindowGeneration() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let manager = try #require(registry.projectManager(for: directory))
        let oldWindow = makeWindow()
        let newWindow = makeWindow()
        let oldDelegate = CloseDelegate(
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate,
            original: nil
        )
        let newDelegate = CloseDelegate(
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate,
            original: nil
        )
        oldDelegate.observeWindowClose(oldWindow)
        newDelegate.observeWindowClose(newWindow)
        defer {
            oldDelegate.detachFromWindow()
            newDelegate.detachFromWindow()
        }

        oldDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(manager.dialogOwnerWindow === newWindow)
        #expect(manager.presentationLifecycle == .visible)
    }

    @Test("retained reopen fences old close before replacement window binds")
    func retainedReopenRotatesGenerationBeforeWindowBinding() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let manager = try #require(registry.projectManager(for: directory))
        let oldWindow = makeWindow()
        let oldDelegate = CloseDelegate(
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate,
            original: nil
        )
        oldDelegate.observeWindowClose(oldWindow)
        let oldGeneration = manager.dialogOwnerWindowGeneration
        defer { oldDelegate.detachFromWindow() }

        registry.closeProjectWindow(directory)
        let reopened = try #require(registry.projectManager(for: directory))
        #expect(reopened === manager)
        #expect(manager.dialogOwnerWindowGeneration != oldGeneration)
        #expect(manager.dialogOwnerWindow == nil)

        // Window B has not bound yet. A's delayed close must already be stale.
        oldDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(manager.presentationLifecycle == .visible)
    }

    @Test("retained reopen cannot recover the old visible window before binding")
    func retainedReopenRetiresOldWindowRecoveryAuthorization() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let manager = try #require(registry.projectManager(for: directory))
        let oldWindow = makeWindow()
        let oldDelegate = CloseDelegate(
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate,
            original: nil
        )
        oldWindow.delegate = oldDelegate
        oldDelegate.observeWindowClose(oldWindow)
        oldWindow.orderFront(nil)
        defer {
            oldDelegate.detachFromWindow()
            oldWindow.delegate = nil
            oldWindow.orderOut(nil)
        }

        registry.closeProjectWindow(directory)
        let reopened = try #require(registry.projectManager(for: directory))
        #expect(reopened === manager)
        #expect(manager.dialogOwnerWindow == nil)

        // A is still visible and still carries the exact manager delegate,
        // but its pre-transition authorization must not be repaired as B's.
        let recovered = await manager.awaitDialogOwnerWindow(
            maximumAttempts: 0
        )
        #expect(recovered == nil)
        #expect(manager.dialogOwnerWindow == nil)

        oldDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(manager.presentationLifecycle == .visible)
    }

    @Test("coordinator transfer cannot reauthorize a retired old window")
    func coordinatorTransferPreservesRetiredWindowFence() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let manager = try #require(registry.projectManager(for: directory))
        let oldWindow = makeWindow()
        let firstCoordinator = WindowCloseInterceptor.Coordinator()
        firstCoordinator.installDelegate(
            on: oldWindow,
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate
        )
        let oldDelegate = try #require(oldWindow.delegate as? CloseDelegate)
        oldWindow.makeKeyAndOrderFront(nil)
        let secondCoordinator = WindowCloseInterceptor.Coordinator()
        defer {
            secondCoordinator.detach()
            oldWindow.orderOut(nil)
        }

        registry.closeProjectWindow(directory)
        #expect(registry.projectManager(for: directory) === manager)
        #expect(manager.dialogOwnerWindow == nil)

        // SwiftUI installs another coordinator on A before B binds. Transfer
        // must preserve both the revoked presentation authority and A's old
        // close generation.
        secondCoordinator.installDelegate(
            on: oldWindow,
            projectManager: manager,
            registry: registry,
            projectURL: directory,
            appDelegate: appDelegate
        )
        #expect(oldWindow.delegate === oldDelegate)
        #expect(await manager.awaitDialogOwnerWindow(maximumAttempts: 0) == nil)
        #expect(DialogPresenter.forKeyProject(
            keyWindow: oldWindow
        ).nsWindow == nil)
        #expect(manager.dialogOwnerWindow == nil)

        oldDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))

        let canonical = registry.canonicalProjectURL(directory)
        #expect(registry.openProjects[canonical] === manager)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(manager.presentationLifecycle == .visible)
    }

    @Test("auto-save termination freeze fences reclamation until rollback")
    func earlyTerminationFreezeFencesReclamation() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry(
            backgroundReclamationInterval: .milliseconds(10)
        )
        let manager = try #require(registry.projectManager(for: directory))
        let canonical = registry.canonicalProjectURL(directory)
        registry.closeProjectWindow(directory)

        registry.freezeAutoSaveForTermination()
        _ = registry.captureApplicationTerminationSaveInventory(
            allowingSaveAs: [:]
        )
        try? await Task.sleep(for: .milliseconds(40))
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[canonical] === manager)

        registry.cancelAutoSaveTerminationFreeze()
        await waitUntil { registry.openProjects[canonical] == nil }
        #expect(manager.presentationLifecycle == .destroyed)
    }

    @Test("Inbox presentation lease prevents mid-presentation reclamation")
    func presentationLeaseRetainsBackgroundManager() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))
        let canonical = registry.canonicalProjectURL(directory)

        registry.closeProjectWindow(directory)
        let leaseID = try #require(
            registry.retainBackgroundProjectForPresentation(
                directory,
                manager: manager
            )
        )
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[canonical] === manager)

        registry.releaseBackgroundProjectPresentation(
            leaseID,
            for: directory
        )
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[canonical] == nil)
        #expect(manager.presentationLifecycle == .destroyed)
    }

    @Test("quit freeze fences reclaim while exact retained reopen survives")
    func quitAndReopenRaceIsFenced() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let manager = try #require(registry.projectManager(for: directory))
        let canonical = registry.canonicalProjectURL(directory)
        registry.closeProjectWindow(directory)

        registry.freezeAgentTasksForTermination()
        registry.runBackgroundReclamationPassForTesting()

        #expect(registry.openProjects[canonical] === manager)
        let reopenedDuringFreeze = try #require(
            registry.projectManager(for: directory)
        )
        #expect(reopenedDuringFreeze === manager)
        #expect(manager.presentationLifecycle == .visible)

        #expect(await registry.cancelAgentTaskTermination())
        let reopened = try #require(registry.projectManager(for: directory))
        #expect(reopened === manager)
        #expect(manager.presentationLifecycle == .visible)
    }

    @Test("committed teardown invalidates services and poll subscriptions")
    func committedTeardownIsFinal() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let registry = makeRegistry()
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let manager = try #require(registry.projectManager(for: directory))
        let paneID = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: directory,
            initialProcess: TerminalInitialProcess(
                executablePath: "/bin/cat",
                arguments: []
            )
        )
        let state = try #require(manager.paneManager.terminalState(for: paneID))
        let tab = try #require(state.activeTab)
        let originalTabIDs = state.terminalTabs.map(\.id)
        manager.terminal.ensureAgentDetectionStarted()
        try #require(registry.agentSnapshotSubscriberCountForTesting == 1)

        appDelegate.applicationWillTerminate(Notification(
            name: NSApplication.willTerminateNotification
        ))

        #expect(manager.presentationLifecycle == .destroyed)
        #expect(manager.workspace.isSuspended)
        #expect(manager.lspManager.presentationLifecycle == .invalidated)
        #expect(manager.terminal.isPermanentlyInvalidated)
        #expect(!manager.terminal.isAgentDetectionPolling)
        #expect(registry.agentSnapshotSubscriberCountForTesting == 0)
        #expect(registry.openProjects.isEmpty)
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        tab.startIfNeeded()
        #expect(tab.isTerminated)
        #expect(!tab.isProcessRunning)
        _ = manager.terminal.createTerminalTab(
            in: paneID,
            workingDirectory: directory
        )
        #expect(state.terminalTabs.map(\.id) == originalTabIDs)
    }

    @Test("frozen task callbacks cannot restart agent detection")
    func callbackFreezeRejectsDetectionRestart() throws {
        let terminal = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminal.ensureAgentDetectionStarted()
        try #require(terminal.isAgentDetectionPolling)
        terminal.freezeAgentTasksForTermination()
        terminal.shutdownAgentDetection()

        terminal.ensureAgentDetectionStarted()

        #expect(!terminal.isAgentDetectionPolling)
        terminal.cancelAgentTaskTermination()
        terminal.ensureAgentDetectionStarted()
        #expect(terminal.isAgentDetectionPolling)
        terminal.shutdownAgentDetection()
    }

    private func makeRegistry(
        processRunner: @escaping ProcessRunner = Self.noOpProcessRunner,
        pollInterval: TimeInterval = 3_600,
        initialPollDelay: TimeInterval? = nil,
        backgroundReclamationInterval: Duration = .seconds(30),
        backgroundReclamationBatchSize: Int = 4
    ) -> ProjectRegistry {
        ProjectRegistry(
            agentDetectionProcessRunner: processRunner,
            agentDetectionPollInterval: pollInterval,
            agentDetectionInitialPollDelay: initialPollDelay,
            backgroundReclamationInterval: backgroundReclamationInterval,
            backgroundReclamationBatchSize: backgroundReclamationBatchSize
        )
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pine-1421-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// Background reclamation lands on the main actor, which parallel
    /// suites contend for — the 500 ms this used to allow measured the
    /// scheduler, not the reclamation (#1568). The shared helper keeps a
    /// generous ceiling so a stuck reclamation still fails.
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        guard await waitUntilMainActor(condition) else {
            Issue.record("Timed out waiting for background reclamation")
            return
        }
    }
}
