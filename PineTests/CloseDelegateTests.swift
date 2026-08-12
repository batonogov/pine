//
//  CloseDelegateTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for CloseDelegate (PineApp.swift) — window close handling.
@Suite("CloseDelegate Tests")
@MainActor
struct CloseDelegateTests {
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineCloseDelegateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeCloseDelegate(
        projectURL: URL,
        original: (any NSWindowDelegate)? = nil,
        presentAlert: CloseDelegate.CloseAlertPresenter? = nil,
        saveAll: CloseDelegate.CloseSaveAll? = nil
    ) -> (CloseDelegate, ProjectManager, ProjectRegistry) {
        let pm = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: projectURL,
            appDelegate: appDelegate,
            original: original,
            presentAlert: presentAlert,
            saveAll: saveAll
        )
        return (delegate, pm, registry)
    }

    private func addDirtyTab(
        to projectManager: ProjectManager,
        in directory: URL
    ) throws {
        projectManager.primaryTabManager.autoSavePreferenceProvider = { false }
        let fileURL = directory.appendingPathComponent("dirty.swift")
        try "original".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        projectManager.primaryTabManager.openTab(url: fileURL)
        projectManager.primaryTabManager.updateContent("modified")
    }

    // MARK: - Initialization

    @Test func closeDelegateStoresReferences() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, registry) = makeCloseDelegate(projectURL: dir)
        #expect(delegate.projectManager === pm)
        #expect(delegate.registry === registry)
        #expect(delegate.projectURL == dir)
    }

    // MARK: - windowShouldClose

    @Test func windowShouldCloseDefersEvenWithNoDirtyTabs() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let window = NSWindow()
        defer { DialogPresenter.ownerDidClose(window) }
        #expect(delegate.windowShouldClose(window) == false)
        await settle()
    }

    @Test func approvedCloseReentersThroughPerformCloseExactlyOnce() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)
        let window = CloseTrackingWindow()
        defer { DialogPresenter.ownerDidClose(window) }
        window.delegate = delegate

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
    }

    @Test func originalDelegateIsConsultedOnlyOnInitialCloseAttempt() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let original = CountingCloseDelegate(shouldApprove: true)
        let (delegate, _, _) = makeCloseDelegate(
            projectURL: dir,
            original: original
        )
        let window = CloseTrackingWindow()
        defer { DialogPresenter.ownerDidClose(window) }
        window.delegate = delegate

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(original.shouldCloseCount == 1)
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
    }

    @Test func failedSaveKeepsDirtyWindowOpen() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        var presentedTemplates: [AlertTemplate] = []
        var saveCount = 0
        let (delegate, projectManager, _) = makeCloseDelegate(
            projectURL: dir,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            saveAll: { _, _ in
                saveCount += 1
                return false
            }
        )
        try addDirtyTab(to: projectManager, in: dir)
        let window = CloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates == [.unsavedChangesBulk])
        #expect(saveCount == 1)
        #expect(window.performCloseCount == 0)
        #expect(projectManager.hasUnsavedChanges)
    }

    @Test func discardApprovesDirtyWindowCloseWithoutSaving() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        var saveCount = 0
        let (delegate, projectManager, _) = makeCloseDelegate(
            projectURL: dir,
            presentAlert: { _, _, _, _ in .alertSecondButtonReturn },
            saveAll: { _, _ in
                saveCount += 1
                return true
            }
        )
        try addDirtyTab(to: projectManager, in: dir)
        let window = CloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(saveCount == 0)
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
        #expect(!projectManager.hasUnsavedChanges)
        #expect(projectManager.primaryTabManager.activeTab?.content == "original")
    }

    @Test func discardCommitSurvivesBackgroundCloseAndReopen() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        try addDirtyTab(to: project, in: dir)
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs)
        #expect(project.recoveryManager?.pendingRecoveryEntries().isEmpty == false)
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil,
            presentAlert: { _, _, _, _ in .alertSecondButtonReturn }
        )
        let window = CloseTrackingWindow()
        window.delegate = delegate
        delegate.observeWindowClose(window)
        defer {
            delegate.detachFromWindow()
            window.delegate = nil
        }

        #expect(!delegate.windowShouldClose(window))
        await settle()
        #expect(window.approvedCloseCount == 1)
        delegate.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )

        let reopened = try #require(registry.projectManager(for: dir))
        #expect(reopened === project)
        #expect(!reopened.hasUnsavedChanges)
        #expect(reopened.primaryTabManager.activeTab?.content == "original")
        #expect(reopened.recoveryManager?.pendingRecoveryEntries().isEmpty == true)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func cancelKeepsDirtyWindowOpenWithoutSaving() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        var saveCount = 0
        let (delegate, projectManager, _) = makeCloseDelegate(
            projectURL: dir,
            presentAlert: { _, _, _, _ in .alertThirdButtonReturn },
            saveAll: { _, _ in
                saveCount += 1
                return true
            }
        )
        try addDirtyTab(to: projectManager, in: dir)
        let window = CloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(saveCount == 0)
        #expect(window.performCloseCount == 0)
        #expect(projectManager.hasUnsavedChanges)
    }

    @Test func staleDiscardCannotCoverNewBufferContent() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        var mutateWhilePresented: (() -> Void)?
        let (delegate, projectManager, _) = makeCloseDelegate(
            projectURL: dir,
            presentAlert: { _, _, _, _ in
                mutateWhilePresented?()
                return .alertSecondButtonReturn
            }
        )
        try addDirtyTab(to: projectManager, in: dir)
        mutateWhilePresented = {
            projectManager.primaryTabManager.updateContent(
                "changed while confirmation was visible"
            )
        }
        let window = CloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(window.performCloseCount == 0)
        #expect(projectManager.primaryTabManager.activeTab?.content ==
                "changed while confirmation was visible")
        #expect(projectManager.hasUnsavedChanges)
    }

    // MARK: - closeActiveTab

    @Test func closeActiveTabNoOpWithoutTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        #expect(pm.primaryTabManager.tabs.isEmpty)
        delegate.closeActiveTab()
        #expect(pm.primaryTabManager.tabs.isEmpty)
    }

    @Test func closeActiveTabClosesCleanTab() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let fileURL = dir.appendingPathComponent("clean.swift")
        try "clean content".write(to: fileURL, atomically: true, encoding: .utf8)
        pm.primaryTabManager.openTab(url: fileURL)

        #expect(pm.primaryTabManager.tabs.count == 1)
        delegate.closeActiveTab()
        await settle()
        #expect(pm.primaryTabManager.tabs.isEmpty)
    }

    // MARK: - windowWillClose idempotency

    @Test func windowWillCloseHandlesOnlyOnce() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let notification = Notification(name: NSWindow.willCloseNotification)
        delegate.windowWillClose(notification)
        // Second call is guarded by didHandleClose — should be no-op
        delegate.windowWillClose(notification)
    }

    // MARK: - closeActiveTab removes empty pane

    @Test func closeActiveTabRemovesEmptyPane() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let pane = pm.paneManager
        let firstPaneID = pane.activePaneID

        // Open a tab in the first pane so it stays alive
        let url1 = dir.appendingPathComponent("keep.swift")
        try "keep".write(to: url1, atomically: true, encoding: .utf8)
        pane.tabManager(for: firstPaneID)?.openTab(url: url1)

        // Split to create a second pane
        guard let secondPaneID = pane.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = dir.appendingPathComponent("remove.swift")
        try "remove".write(to: url2, atomically: true, encoding: .utf8)
        pane.tabManager(for: secondPaneID)?.openTab(url: url2)
        pane.activePaneID = secondPaneID

        #expect(pane.root.leafCount == 2)

        // Close the only tab in the active (second) pane via CloseDelegate
        delegate.closeActiveTab()
        await settle()

        // The empty pane should have been removed
        #expect(pane.root.leafCount == 1)
        #expect(pane.tabManagers[secondPaneID] == nil)
    }

    @Test func closeActiveTabDoesNotRemovePaneWithRemainingTabs() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let pane = pm.paneManager
        let firstPaneID = pane.activePaneID

        // Open a tab in the first pane
        let url1 = dir.appendingPathComponent("keep1.swift")
        try "keep1".write(to: url1, atomically: true, encoding: .utf8)
        pane.tabManager(for: firstPaneID)?.openTab(url: url1)

        // Split to create a second pane with two tabs
        guard let secondPaneID = pane.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = dir.appendingPathComponent("stay.swift")
        try "stay".write(to: url2, atomically: true, encoding: .utf8)
        let url3 = dir.appendingPathComponent("close.swift")
        try "close".write(to: url3, atomically: true, encoding: .utf8)
        pane.tabManager(for: secondPaneID)?.openTab(url: url2)
        pane.tabManager(for: secondPaneID)?.openTab(url: url3)
        pane.activePaneID = secondPaneID

        #expect(pane.root.leafCount == 2)

        // Close one tab — pane should remain since it still has a tab
        delegate.closeActiveTab()
        await settle()

        #expect(pane.root.leafCount == 2)
        #expect(pane.tabManagers[secondPaneID] != nil)
    }

    // MARK: - observeWindowClose

    @Test func observeWindowCloseRegistersNotification() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, projectManager, _) = makeCloseDelegate(projectURL: dir)

        let window = NSWindow()
        delegate.observeWindowClose(window)
        #expect(projectManager.dialogOwnerWindow === window)
        #expect(delegate.dialogContext.nsWindow === window)
        DialogPresenter.ownerDidClose(window)
        #expect(projectManager.dialogOwnerWindow == nil)
    }

    @Test func interceptorRewrapsAReplacedDelegateAndPreservesDirtyVeto() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        try addDirtyTab(to: project, in: dir)
        let window = CloseTrackingWindow()
        let initialOriginal = CountingCloseDelegate(shouldApprove: true)
        window.delegate = initialOriginal
        let coordinator = WindowCloseInterceptor.Coordinator()
        var promptCount = 0

        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            presentAlert: { _, _, _, _ in
                promptCount += 1
                return .alertThirdButtonReturn
            }
        )
        let firstInterceptor = try #require(
            window.delegate as? CloseDelegate
        )

        let replacement = CountingCloseDelegate(shouldApprove: true)
        window.delegate = replacement
        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            presentAlert: { _, _, _, _ in
                promptCount += 1
                return .alertThirdButtonReturn
            }
        )
        let secondInterceptor = try #require(
            window.delegate as? CloseDelegate
        )
        defer {
            secondInterceptor.detachFromWindow()
            window.delegate = nil
        }

        #expect(secondInterceptor !== firstInterceptor)
        #expect(secondInterceptor.original === replacement)
        window.performClose(nil)
        await settle()

        #expect(promptCount == 1)
        #expect(window.approvedCloseCount == 0)
        #expect(project.hasUnsavedChanges)
    }

    @Test func interceptorLifecycleNotificationRepairsDelegateReplacement() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let window = NSWindow()
        let coordinator = WindowCloseInterceptor.Coordinator()
        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let firstInterceptor = try #require(
            window.delegate as? CloseDelegate
        )
        let replacement = CountingCloseDelegate(shouldApprove: true)
        window.delegate = replacement

        NotificationCenter.default.post(
            name: NSWindow.didUpdateNotification,
            object: window
        )
        let repaired = try #require(window.delegate as? CloseDelegate)
        defer {
            repaired.detachFromWindow()
            window.delegate = nil
        }

        #expect(repaired !== firstInterceptor)
        #expect(repaired.original === replacement)
        #expect(project.dialogOwnerWindow === window)
    }

    @Test func interceptorMoveRestoresOldWindowAndRebindsProjectOwner() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let firstOriginal = CountingCloseDelegate(shouldApprove: true)
        let secondOriginal = CountingCloseDelegate(shouldApprove: true)
        firstWindow.delegate = firstOriginal
        secondWindow.delegate = secondOriginal
        let coordinator = WindowCloseInterceptor.Coordinator()

        coordinator.installDelegate(
            on: firstWindow,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let firstContext = try #require(
            firstWindow.delegate as? CloseDelegate
        ).dialogContext
        coordinator.installDelegate(
            on: secondWindow,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let secondInterceptor = try #require(
            secondWindow.delegate as? CloseDelegate
        )
        defer {
            secondInterceptor.detachFromWindow()
            firstWindow.delegate = nil
            secondWindow.delegate = nil
        }

        #expect(firstWindow.delegate === firstOriginal)
        #expect(firstContext.nsWindow == nil)
        #expect(secondInterceptor.original === secondOriginal)
        #expect(project.dialogOwnerWindow === secondWindow)
        #expect(secondInterceptor.dialogContext.nsWindow === secondWindow)
    }

    @Test func interceptorDismantleRestoresDelegateAndRetiresDialogAuthority() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let window = NSWindow()
        let original = CountingCloseDelegate(shouldApprove: true)
        window.delegate = original
        let coordinator = WindowCloseInterceptor.Coordinator()
        let sentinel = WindowCloseInterceptor.InterceptorView()

        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let capturedContext = try #require(
            window.delegate as? CloseDelegate
        ).dialogContext
        #expect(project.dialogOwnerWindow === window)

        WindowCloseInterceptor.dismantleNSView(
            sentinel,
            coordinator: coordinator
        )

        #expect(window.delegate === original)
        #expect(project.dialogOwnerWindow == nil)
        #expect(capturedContext.nsWindow == nil)
        let response = await capturedContext.present(
            start: { _, completion in
                completion(.alertFirstButtonReturn)
            },
            cancel: { _ in }
        )
        #expect(response == .abort)

        // A second teardown must not disturb the restored delegate.
        coordinator.detach()
        #expect(window.delegate === original)
    }

    @Test func replacementCoordinatorOwnsDelegateAcrossOldDismantle() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let window = NSWindow()
        let firstCoordinator = WindowCloseInterceptor.Coordinator()
        let replacementCoordinator = WindowCloseInterceptor.Coordinator()
        weak var expectedOriginal: CountingCloseDelegate?
        do {
            let original = CountingCloseDelegate(shouldApprove: true)
            expectedOriginal = original
            window.delegate = original
            firstCoordinator.installDelegate(
                on: window,
                projectManager: project,
                registry: registry,
                projectURL: dir,
                appDelegate: appDelegate
            )
        }
        let interceptor = try #require(window.delegate as? CloseDelegate)
        #expect(expectedOriginal != nil)
        replacementCoordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )

        // A stale SwiftUI update delivered to the superseded generation must
        // not let it reclaim the delegate from its replacement.
        firstCoordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )

        // SwiftUI dismantles the obsolete representable after its replacement
        // is already live. The old coordinator must not restore the original
        // delegate or clear the replacement's dialog owner (#1407).
        firstCoordinator.detach()

        #expect(window.delegate === interceptor)
        #expect(project.dialogOwnerWindow === window)
        #expect(interceptor.dialogContext.nsWindow === window)
        #expect(expectedOriginal != nil)
        #expect(interceptor.original === expectedOriginal)

        replacementCoordinator.detach()
        #expect(project.dialogOwnerWindow == nil)
    }

    @Test func lostBindingRecoversFromLiveProjectDelegate() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let project = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let window = NSWindow()
        let coordinator = WindowCloseInterceptor.Coordinator()

        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let delegate = try #require(window.delegate as? CloseDelegate)
        DialogPresenter.ownerDidClose(window)
        #expect(project.dialogOwnerWindow == nil)

        let recovered = DialogPresenter.recoverProjectOwnerWindow(
            for: project,
            candidates: [window],
            isEligible: { _ in true }
        )

        #expect(recovered === window)
        #expect(project.dialogOwnerWindow === window)
        #expect(delegate.dialogContext.nsWindow === window)
        coordinator.detach()
    }

    @Test func recoveryRejectsSiblingProjectAndCompletedDelegate() throws {
        let targetDir = try makeTempDir()
        let siblingDir = try makeTempDir()
        defer {
            cleanup(targetDir)
            cleanup(siblingDir)
        }
        let (targetDelegate, targetProject, _) = makeCloseDelegate(
            projectURL: targetDir
        )
        let (siblingDelegate, siblingProject, _) = makeCloseDelegate(
            projectURL: siblingDir
        )
        let targetWindow = NSWindow()
        let siblingWindow = NSWindow()
        targetWindow.delegate = targetDelegate
        siblingWindow.delegate = siblingDelegate
        targetDelegate.observeWindowClose(targetWindow)
        siblingDelegate.observeWindowClose(siblingWindow)
        defer {
            DialogPresenter.ownerDidClose(targetWindow)
            DialogPresenter.ownerDidClose(siblingWindow)
            targetWindow.delegate = nil
            siblingWindow.delegate = nil
        }

        DialogPresenter.ownerDidClose(targetWindow)
        #expect(DialogPresenter.recoverProjectOwnerWindow(
            for: targetProject,
            candidates: [siblingWindow],
            isEligible: { _ in true }
        ) == nil)
        #expect(targetProject.dialogOwnerWindow == nil)
        #expect(siblingProject.dialogOwnerWindow === siblingWindow)

        targetDelegate.windowWillClose(
            Notification(
                name: NSWindow.willCloseNotification,
                object: targetWindow
            )
        )
        #expect(targetDelegate.didCompleteWindowLifecycle)
        #expect(DialogPresenter.recoverProjectOwnerWindow(
            for: targetProject,
            candidates: [targetWindow],
            isEligible: { _ in true }
        ) == nil)
        #expect(targetProject.dialogOwnerWindow == nil)
    }

    @Test func retainedReopenRearmsCompletedDelegateWithoutCoordinatorUpdate() async throws {
        let dir = try makeTempDir()
        let otherDir = try makeTempDir()
        defer {
            cleanup(dir)
            cleanup(otherDir)
        }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        // Keep another project window logically open so closing `dir` does
        // not schedule the global delayed Welcome fallback and contaminate
        // otherwise unrelated window-lifecycle tests.
        _ = try #require(registry.projectManager(for: otherDir))
        let appDelegate = AppDelegate()
        let window = CloseTrackingWindow()
        let original = CountingCloseDelegate(shouldApprove: true)
        window.delegate = original
        let coordinator = WindowCloseInterceptor.Coordinator()

        coordinator.installDelegate(
            on: window,
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate
        )
        let interceptor = try #require(window.delegate as? CloseDelegate)
        interceptor.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )
        #expect(interceptor.didCompleteWindowLifecycle)
        #expect(!registry.isWindowOpen(dir))
        #expect(project.dialogOwnerWindow == nil)

        #expect(registry.projectManager(for: dir) === project)
        #expect(registry.isWindowOpen(dir))

        // macOS 26 can order the same WindowGroup NSWindow front without an
        // update/move callback for its NSViewRepresentable. Admission must
        // therefore re-arm the delegate from the completed close record.
        #expect(window.delegate === interceptor)
        #expect(!interceptor.didCompleteWindowLifecycle)
        #expect(project.dialogOwnerWindow === window)
        window.performClose(nil)
        await settle()
        #expect(window.approvedCloseCount == 1)

        interceptor.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )
        #expect(interceptor.didCompleteWindowLifecycle)
        #expect(!registry.isWindowOpen(dir))
        #expect(project.dialogOwnerWindow == nil)
        coordinator.detach()
        #expect(window.delegate === original)
    }

    @Test func staleCloseCannotReplaceCompletedOwnerChosenForReopen() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let appDelegate = AppDelegate()
        let oldWindow = NSWindow()
        let currentWindow = NSWindow()
        let oldDelegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil
        )
        let currentDelegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil
        )
        oldWindow.delegate = oldDelegate
        currentWindow.delegate = currentDelegate
        oldDelegate.observeWindowClose(oldWindow)
        currentDelegate.observeWindowClose(currentWindow)
        defer {
            oldDelegate.detachFromWindow()
            currentDelegate.detachFromWindow()
            oldWindow.delegate = nil
            currentWindow.delegate = nil
        }

        // B is the exact current owner and completes the close that moves the
        // project to the background. A's older callback arrives afterwards.
        currentDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: currentWindow
        ))
        oldDelegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: oldWindow
        ))
        #expect(currentDelegate.didCompleteWindowLifecycle)
        #expect(oldDelegate.didCompleteWindowLifecycle)
        #expect(!registry.isWindowOpen(dir))

        // Admission may reuse B without a representable update. The stale A
        // callback must not have replaced B's completed-lifecycle record.
        #expect(registry.projectManager(for: dir) === project)
        #expect(!currentDelegate.didCompleteWindowLifecycle)
        #expect(oldDelegate.didCompleteWindowLifecycle)
        #expect(project.dialogOwnerWindow === currentWindow)
    }
}

@MainActor
private final class CloseTrackingWindow: NSWindow {
    private(set) var performCloseCount = 0
    private(set) var approvedCloseCount = 0

    override func performClose(_ sender: Any?) {
        performCloseCount += 1
        if delegate?.windowShouldClose?(self) != false {
            approvedCloseCount += 1
        }
    }
}

@MainActor
private final class CountingCloseDelegate: NSObject, NSWindowDelegate {
    private let shouldApprove: Bool
    private(set) var shouldCloseCount = 0

    init(shouldApprove: Bool) {
        self.shouldApprove = shouldApprove
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return shouldApprove
    }
}
