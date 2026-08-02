//
//  WindowLifecycleTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Window Lifecycle Tests")
@MainActor
struct WindowLifecycleTests {
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempFile(in dir: URL, name: String = "test.swift") throws -> URL {
        let file = dir.appendingPathComponent(name)
        try "// \(name)".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - onDisappear logic (handleProjectWindowDisappear)

    @Test func closingLastProjectTriggersShowWelcome() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)

        let delegate = AppDelegate()
        var welcomeCalled = false
        delegate.openNamedWindow = { id in
            if id == "welcome" { welcomeCalled = true }
        }

        delegate.handleProjectWindowDisappear(projectURL: dir, registry: registry)

        // Project stays in openProjects as background
        let canonical = dir.resolvingSymlinksInPath()
        #expect(registry.backgroundProjects.contains(canonical))
        #expect(!registry.isWindowOpen(dir))
        #expect(welcomeCalled)
    }

    @Test func closingNonLastProjectDoesNotShowWelcome() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir1)
        _ = registry.projectManager(for: dir2)

        let delegate = AppDelegate()
        var welcomeCalled = false
        delegate.openNamedWindow = { id in
            if id == "welcome" { welcomeCalled = true }
        }

        delegate.handleProjectWindowDisappear(projectURL: dir1, registry: registry)

        // One project still has open window, one is background
        #expect(registry.openProjects.count == 2)
        #expect(registry.isWindowOpen(dir2))
        #expect(!registry.isWindowOpen(dir1))
        #expect(!welcomeCalled)
    }

    @Test func sessionSavedBeforeProjectClosed() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))
        pm.primaryTabManager.openTab(url: file)

        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        delegate.handleProjectWindowDisappear(projectURL: dir, registry: registry)

        // Project stays in openProjects as background
        let canonical = dir.resolvingSymlinksInPath()
        #expect(registry.backgroundProjects.contains(canonical))

        // But session was saved BEFORE close — it must be loadable
        let session = SessionState.load(for: canonical)
        #expect(session != nil)
        #expect(session?.existingFileURLs.count == 1)
        #expect(session?.existingFileURLs.first == file)
    }

    // MARK: - Termination

    @Test func terminationSavesAllProjectSessions() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let file1 = try makeTempFile(in: dir1, name: "a.swift")
        let file2 = try makeTempFile(in: dir2, name: "b.swift")

        let registry = ProjectRegistry()
        let pm1 = try #require(registry.projectManager(for: dir1))
        let pm2 = try #require(registry.projectManager(for: dir2))
        pm1.primaryTabManager.openTab(url: file1)
        pm2.primaryTabManager.openTab(url: file2)

        let delegate = AppDelegate()
        delegate.registry = registry

        // Simulate applicationWillTerminate
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        // Both sessions saved
        let session1 = SessionState.load(for: dir1.resolvingSymlinksInPath())
        let session2 = SessionState.load(for: dir2.resolvingSymlinksInPath())
        #expect(session1?.existingFileURLs.count == 1)
        #expect(session2?.existingFileURLs.count == 1)
    }

    @Test func asyncTerminationFailsClosedWhenSaveFails() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("// dirty")

        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []
        var saveAttempts = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            saveAll: { _, _ in
                saveAttempts += 1
                return false
            }
        )

        #expect(!result)
        #expect(presentedTemplates == [.unsavedChangesBulk])
        #expect(saveAttempts == 1)
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func terminationDeadlineBoundsHungAlertPresenter() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("// dirty")
        let delegate = AppDelegate()
        delegate.registry = registry
        let clock = ContinuousClock()
        let started = clock.now

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in
                try? await Task.sleep(for: .seconds(10))
                return .alertFirstButtonReturn
            },
            userTaskShutdownDeadline: .now() + .milliseconds(25)
        )

        #expect(!result)
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func asyncTerminationCancelNeverAttemptsSave() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("// dirty")

        let delegate = AppDelegate()
        delegate.registry = registry
        var saveAttempts = 0
        let fallbackWindow = NSWindow()
        let fallbackContext = DialogPresentationContext(window: fallbackWindow)
        defer { DialogPresenter.ownerDidClose(fallbackWindow) }
        var presentedOwner: NSWindow?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, context, _, _ in
                presentedOwner = context.nsWindow
                return .alertThirdButtonReturn
            },
            saveAll: { _, _ in
                saveAttempts += 1
                return true
            },
            applicationContext: fallbackContext
        )

        #expect(!result)
        #expect(saveAttempts == 0)
        #expect(project.hasUnsavedChanges)
        #expect(presentedOwner === fallbackWindow)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func asyncTerminationRejectsStaleDiscardAuthorization() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("// first dirty state")

        let delegate = AppDelegate()
        delegate.registry = registry
        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .unsavedChangesBulk)
                project.primaryTabManager.updateContent(
                    "// changed while quit sheet was visible"
                )
                return .alertSecondButtonReturn
            }
        )

        #expect(!result)
        #expect(project.hasUnsavedChanges)
        #expect(project.primaryTabManager.activeTab?.content ==
                "// changed while quit sheet was visible")
        await project.workspace.waitForLoadingComplete()
    }

    @Test func quitDiscardCommitsCleanStateAndDeletesRecovery() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("// discarded")
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs)
        #expect(project.recoveryManager?.pendingRecoveryEntries().isEmpty == false)
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .unsavedChangesBulk)
                return .alertSecondButtonReturn
            }
        )

        #expect(result)
        #expect(!project.hasUnsavedChanges)
        #expect(project.primaryTabManager.activeTab?.content == "// test.swift")
        #expect(project.recoveryManager?.pendingRecoveryEntries().isEmpty == true)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func laterQuitCancelDoesNotCommitEarlierDiscard() async throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }
        let firstFile = try makeTempFile(in: firstDirectory, name: "first.swift")
        let secondFile = try makeTempFile(in: secondDirectory, name: "second.swift")
        let registry = ProjectRegistry()
        let firstProject = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let secondProject = try #require(
            registry.projectManager(for: secondDirectory)
        )
        firstProject.primaryTabManager.openTab(url: firstFile)
        secondProject.primaryTabManager.openTab(url: secondFile)
        firstProject.primaryTabManager.updateContent("// first dirty")
        secondProject.primaryTabManager.updateContent("// second dirty")
        let delegate = AppDelegate()
        delegate.registry = registry
        var promptCount = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .unsavedChangesBulk)
                promptCount += 1
                return promptCount == 1
                    ? .alertSecondButtonReturn
                    : .alertThirdButtonReturn
            }
        )

        #expect(!result)
        #expect(promptCount == 2)
        #expect(firstProject.hasUnsavedChanges)
        #expect(firstProject.primaryTabManager.activeTab?.content == "// first dirty")
        #expect(secondProject.hasUnsavedChanges)
        #expect(secondProject.primaryTabManager.activeTab?.content == "// second dirty")
        await firstProject.workspace.waitForLoadingComplete()
        await secondProject.workspace.waitForLoadingComplete()
    }

    @Test func quitTaskTimeoutRetainsProjectAndCleanupOwnership() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let run = project.taskRunStore.start(makeTaskRun(id: "timeout"))
        let probe = TerminationTaskProbe(waitResult: false)
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            userTaskShutdownDeadline: .now()
        )

        #expect(!result)
        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(project.hasOutstandingUserTaskExecution)
        #expect(registry.isProjectOpen(dir))
        #expect(!registry.destroyAllProjects())
        #expect(registry.isProjectOpen(dir))

        project.taskRunStore.finishRun(
            id: run.id,
            outcome: makeTaskOutcome(id: "timeout"),
            cancelled: true
        )
        #expect(registry.destroyAllProjects())
    }

    @Test func quitWaitsForTaskCleanupBeforeAllowingTeardown() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let run = project.taskRunStore.start(makeTaskRun(id: "success"))
        let probe = TerminationTaskProbe(waitResult: true)
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            userTaskShutdownDeadline: .now() + 1
        )

        #expect(result)
        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(!project.hasOutstandingUserTaskExecution)
        #expect(project.taskRunStore.runs.isEmpty)
        #expect(registry.destroyAllProjects())
    }

    @Test func quitRevalidatesEditsMadeDuringTaskCleanup() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        let run = project.taskRunStore.start(makeTaskRun(id: "delayed"))
        let gate = TerminationWaitGate()
        project.taskRunStore.registerCancellation(
            UserTaskCancellation(
                terminate: { true },
                waitForCompletion: { deadline in
                    gate.waitForRelease(until: deadline)
                }
            ),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry

        let decision = Task { @MainActor in
            await delegate.confirmApplicationTermination(
                userTaskShutdownDeadline: .now() + 2
            )
        }
        defer { gate.release() }
        for _ in 0..<200 where !gate.didStartWaiting {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.didStartWaiting)
        project.primaryTabManager.updateContent("// edited during cleanup")
        gate.release()

        let result = await decision.value
        #expect(!result)
        #expect(project.hasUnsavedChanges)
        #expect(project.primaryTabManager.activeTab?.content ==
                "// edited during cleanup")
        await project.workspace.waitForLoadingComplete()
    }

    @Test func terminationHandshakeDefersAndRepliesExactlyOnce() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []

        let initialReply = delegate.beginApplicationTermination {
            replies.append($0)
        }
        #expect(initialReply == .terminateLater)
        for _ in 0..<50 {
            if !replies.isEmpty { break }
            await Task.yield()
        }

        #expect(replies == [true])
        #expect(delegate.isTerminating)
        let committedReply = delegate.beginApplicationTermination { _ in
            Issue.record("Committed termination must not reply a second time")
        }
        #expect(committedReply == .terminateNow)
        await settle()
        #expect(replies == [true])
    }

    // MARK: - windowShouldClose (CloseDelegate)

    @Test func windowShouldCloseDefersWhenNoTabs() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        let pm = ProjectManager()
        let delegate = AppDelegate()
        let window = NSWindow()
        defer { DialogPresenter.ownerDidClose(window) }

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        // Every close is approved asynchronously, then re-entered through
        // performClose so no delegate callback blocks on modal UI.
        #expect(!closeDelegate.windowShouldClose(window))
        await settle()
    }

    @Test func windowShouldCloseDefersWithCleanTabs() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let pm = ProjectManager()
        pm.primaryTabManager.openTab(url: file)

        let delegate = AppDelegate()
        let window = NSWindow()
        defer { DialogPresenter.ownerDidClose(window) }

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        #expect(!closeDelegate.windowShouldClose(window))
        // Tabs should NOT have been closed individually
        #expect(pm.primaryTabManager.tabs.count == 1)
        await settle()
    }

    @Test func windowShouldCloseDoesNotCloseIndividualCleanTab() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file1 = try makeTempFile(in: dir, name: "a.swift")
        let file2 = try makeTempFile(in: dir, name: "b.swift")

        let registry = ProjectRegistry()
        let pm = ProjectManager()
        pm.primaryTabManager.openTab(url: file1)
        pm.primaryTabManager.openTab(url: file2)

        let delegate = AppDelegate()
        let window = NSWindow()
        defer { DialogPresenter.ownerDidClose(window) }

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        // With multiple clean tabs, should close window (return true)
        // and NOT close tabs one by one
        #expect(!closeDelegate.windowShouldClose(window))
        #expect(pm.primaryTabManager.tabs.count == 2)
        await settle()
    }

    // MARK: - showWelcome

    @Test func showWelcomeCallsOpenNamedWindow() throws {
        let delegate = AppDelegate()
        var openedWindowID: String?
        delegate.openNamedWindow = { id in
            openedWindowID = id
        }

        delegate.showWelcome()

        #expect(openedWindowID == "welcome")
    }

    @Test func openFolderWaitsForDelayedWelcomeCapture() async {
        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        var attempts = 0
        var capturedWindow: NSWindow?
        var presentedOwner: NSWindow?
        var openedURL: URL?
        let selectedURL = URL(fileURLWithPath: "/tmp/pine-delayed-welcome")
        delegate.openProjectWindow = { openedURL = $0 }

        let didOpen = await delegate.openFolderFromWelcomeOwner(
            maximumAttempts: 6,
            waitForNextAttempt: {
                attempts += 1
                if attempts == 3 {
                    let window = NSWindow()
                    window.identifier = .init("welcome")
                    window.orderFront(nil)
                    capturedWindow = window
                    delegate.welcomeWindow = window
                }
                await Task.yield()
            },
            resolveVisibleWindow: {
                guard let capturedWindow,
                      capturedWindow.isVisible,
                      !capturedWindow.isMiniaturized else {
                    return nil
                }
                return capturedWindow
            },
            presentPanel: { context in
                presentedOwner = context.nsWindow
                return selectedURL
            }
        )
        defer {
            if let capturedWindow {
                DialogPresenter.ownerDidClose(capturedWindow)
                capturedWindow.orderOut(nil)
            }
        }

        #expect(didOpen)
        #expect(attempts == 3)
        #expect(presentedOwner === capturedWindow)
        #expect(openedURL == selectedURL)
        #expect(capturedWindow?.isVisible == false)
    }

    @Test func openFolderFailsClosedWhenWelcomeOwnerNeverAppears() async {
        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        var waitCount = 0
        var panelCount = 0

        let didOpen = await delegate.openFolderFromWelcomeOwner(
            maximumAttempts: 3,
            waitForNextAttempt: {
                waitCount += 1
                await Task.yield()
            },
            resolveVisibleWindow: { nil },
            presentPanel: { _ in
                panelCount += 1
                return URL(fileURLWithPath: "/tmp/should-not-open")
            }
        )

        #expect(!didOpen)
        #expect(waitCount == 3)
        #expect(panelCount == 0)
    }

    @Test func openFolderFailsClosedWithoutProjectWindowAction() async {
        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        let welcome = NSWindow()
        welcome.identifier = .init("welcome")
        welcome.orderFront(nil)
        defer {
            DialogPresenter.ownerDidClose(welcome)
            welcome.orderOut(nil)
        }

        let didOpen = await delegate.openFolderFromWelcomeOwner(
            maximumAttempts: 1,
            waitForNextAttempt: { await Task.yield() },
            resolveVisibleWindow: { welcome },
            presentPanel: { _ in
                URL(fileURLWithPath: "/tmp/pine-no-window-action")
            }
        )

        #expect(!didOpen)
        #expect(welcome.isVisible)
    }

    private func makeTaskRun(id: String) -> UserTaskRun {
        UserTaskRun(
            taskID: id,
            taskLabel: id,
            command: "printf done",
            replacesFileContent: false
        )
    }

    private func makeTaskOutcome(id: String) -> UserTaskOutcome {
        UserTaskOutcome(
            taskID: id,
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }
}

nonisolated private final class TerminationTaskProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let waitResult: Bool
    private var cancellations = 0
    private var waits = 0

    init(waitResult: Bool) {
        self.waitResult = waitResult
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    var waitCount: Int {
        lock.withLock { waits }
    }

    func makeCancellation() -> UserTaskCancellation {
        UserTaskCancellation(
            terminate: { [self] in
                lock.withLock {
                    cancellations += 1
                }
                return true
            },
            waitForCompletion: { [self] _ in
                lock.withLock {
                    waits += 1
                }
                return waitResult
            }
        )
    }
}

nonisolated private final class TerminationWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var startedWaiting = false

    var didStartWaiting: Bool {
        lock.withLock { startedWaiting }
    }

    func waitForRelease(until deadline: DispatchTime) -> Bool {
        lock.withLock {
            startedWaiting = true
        }
        return releaseSemaphore.wait(timeout: deadline) == .success
    }

    func release() {
        releaseSemaphore.signal()
    }
}
