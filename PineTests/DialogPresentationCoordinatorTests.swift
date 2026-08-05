//
//  DialogPresentationCoordinatorTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Window dialog coordinator")
@MainActor
struct DialogPresentationCoordinatorTests {
    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    private func makeVisibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        return window
    }

    @Test("requests for one window are presented FIFO, never concurrently")
    func serializesRequestsPerWindow() async {
        let window = NSWindow()
        let coordinator = WindowDialogCoordinator(ownerWindow: window)
        var starts: [Int] = []
        var completions: [(NSApplication.ModalResponse) -> Void] = []

        let first = Task {
            await coordinator.present(
                start: { _, completion in
                    starts.append(1)
                    completions.append(completion)
                },
                cancel: { _ in }
            )
        }
        await settle()

        let second = Task {
            await coordinator.present(
                start: { _, completion in
                    starts.append(2)
                    completions.append(completion)
                },
                cancel: { _ in }
            )
        }
        await settle()

        #expect(starts == [1])
        #expect(coordinator.pendingRequestCount == 2)

        completions[0](.alertFirstButtonReturn)
        await settle()
        #expect(starts == [1, 2])
        #expect(coordinator.pendingRequestCount == 1)

        completions[1](.alertSecondButtonReturn)
        await settle()
        #expect(await first.value == .alertFirstButtonReturn)
        #expect(await second.value == .alertSecondButtonReturn)
        #expect(coordinator.pendingRequestCount == 0)
    }

    @Test("duplicate destructive request is rejected until the original finishes")
    func deduplicatesInFlightRequestKey() async {
        let window = NSWindow()
        let coordinator = WindowDialogCoordinator(ownerWindow: window)
        let key = DialogRequestKey.editorTabs(
            tabManager: ObjectIdentifier(window),
            tabIDs: [UUID()]
        )
        var startCount = 0
        var firstCompletion: ((NSApplication.ModalResponse) -> Void)?

        let first = Task {
            await coordinator.present(
                deduplicationKey: key,
                start: { _, completion in
                    startCount += 1
                    firstCompletion = completion
                },
                cancel: { _ in }
            )
        }
        await settle()

        let duplicate = await coordinator.present(
            deduplicationKey: key,
            start: { _, completion in
                startCount += 1
                completion(.alertFirstButtonReturn)
            },
            cancel: { _ in }
        )

        #expect(duplicate == .abort)
        #expect(startCount == 1)
        #expect(coordinator.pendingRequestCount == 1)

        firstCompletion?(.alertSecondButtonReturn)
        #expect(await first.value == .alertSecondButtonReturn)
        await settle()

        let next = await coordinator.present(
            deduplicationKey: key,
            start: { _, completion in
                startCount += 1
                completion(.alertFirstButtonReturn)
            },
            cancel: { _ in }
        )
        #expect(next == .alertFirstButtonReturn)
        #expect(startCount == 2)
        #expect(coordinator.pendingRequestCount == 0)
    }

    @Test("different owner windows can present independently")
    func isolatesWindows() async {
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let firstCoordinator = WindowDialogCoordinator(ownerWindow: firstWindow)
        let secondCoordinator = WindowDialogCoordinator(ownerWindow: secondWindow)
        var firstCompletion: ((NSApplication.ModalResponse) -> Void)?
        var secondCompletion: ((NSApplication.ModalResponse) -> Void)?
        var starts: [String] = []

        let first = Task {
            await firstCoordinator.present(
                start: { _, completion in
                    starts.append("first")
                    firstCompletion = completion
                },
                cancel: { _ in }
            )
        }
        let second = Task {
            await secondCoordinator.present(
                start: { _, completion in
                    starts.append("second")
                    secondCompletion = completion
                },
                cancel: { _ in }
            )
        }
        await settle()

        #expect(Set(starts) == Set(["first", "second"]))
        #expect(firstCoordinator.pendingRequestCount == 1)
        #expect(secondCoordinator.pendingRequestCount == 1)

        firstCompletion?(.alertFirstButtonReturn)
        secondCompletion?(.alertSecondButtonReturn)
        #expect(await first.value == .alertFirstButtonReturn)
        #expect(await second.value == .alertSecondButtonReturn)
    }

    @Test("real sheets stay scoped and can coexist on separate windows")
    func realSheetsDoNotBlockOtherWindows() async {
        let firstWindow = makeVisibleWindow()
        let secondWindow = makeVisibleWindow()
        defer {
            DialogPresenter.ownerDidClose(firstWindow)
            DialogPresenter.ownerDidClose(secondWindow)
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }
        let firstContext = DialogPresentationContext(window: firstWindow)
        let secondContext = DialogPresentationContext(window: secondWindow)
        let firstAlert = NSAlert()
        firstAlert.messageText = "First"
        firstAlert.addButton(withTitle: "OK")
        let secondAlert = NSAlert()
        secondAlert.messageText = "Second"
        secondAlert.addButton(withTitle: "OK")

        let firstResponse = Task {
            await firstAlert.runSheet(on: firstContext)
        }
        let secondResponse = Task {
            await secondAlert.runSheet(on: secondContext)
        }
        for _ in 0..<50 {
            if firstWindow.attachedSheet != nil,
               secondWindow.attachedSheet != nil {
                break
            }
            await Task.yield()
        }

        #expect(firstWindow.attachedSheet === firstAlert.window)
        #expect(secondWindow.attachedSheet === secondAlert.window)
        if firstWindow.attachedSheet === firstAlert.window {
            firstWindow.endSheet(
                firstAlert.window,
                returnCode: .alertFirstButtonReturn
            )
        } else {
            DialogPresenter.ownerDidClose(firstWindow)
        }
        if secondWindow.attachedSheet === secondAlert.window {
            secondWindow.endSheet(
                secondAlert.window,
                returnCode: .alertFirstButtonReturn
            )
        } else {
            DialogPresenter.ownerDidClose(secondWindow)
        }

        #expect(await firstResponse.value == .alertFirstButtonReturn)
        #expect(await secondResponse.value == .alertFirstButtonReturn)
    }

    @Test("queued native dialog waits for a framework-owned sheet")
    func waitsForExistingOwnerSheet() async {
        let owner = makeVisibleWindow()
        let frameworkSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowDialogCoordinator(ownerWindow: owner)
        var startCount = 0
        var completion: ((NSApplication.ModalResponse) -> Void)?
        defer {
            coordinator.ownerDidClose()
            owner.orderOut(nil)
        }

        owner.beginSheet(frameworkSheet) { _ in }
        let response = Task {
            await coordinator.present(
                start: { _, callback in
                    startCount += 1
                    completion = callback
                },
                cancel: { _ in }
            )
        }
        await settle()
        #expect(startCount == 0)

        owner.endSheet(frameworkSheet, returnCode: .cancel)
        for _ in 0..<50 {
            if startCount == 1 { break }
            await Task.yield()
        }
        #expect(startCount == 1)

        if let completion {
            completion(.alertFirstButtonReturn)
        } else {
            coordinator.ownerDidClose()
        }
        #expect(await response.value == .alertFirstButtonReturn)
    }

    @Test("owner close aborts active and queued requests exactly once")
    func ownerCloseCancelsEverythingOnce() async {
        let window = NSWindow()
        let coordinator = WindowDialogCoordinator(ownerWindow: window)
        var activeCompletion: ((NSApplication.ModalResponse) -> Void)?
        var cancelCount = 0
        var queuedStarted = false

        let active = Task {
            await coordinator.present(
                start: { _, completion in activeCompletion = completion },
                cancel: { _ in cancelCount += 1 }
            )
        }
        await settle()
        let queued = Task {
            await coordinator.present(
                start: { _, _ in queuedStarted = true },
                cancel: { _ in cancelCount += 1 }
            )
        }
        await settle()

        coordinator.ownerDidClose()
        coordinator.ownerDidClose()
        await settle()

        #expect(await active.value == .abort)
        #expect(await queued.value == .abort)
        #expect(cancelCount == 1)
        #expect(!queuedStarted)
        #expect(coordinator.pendingRequestCount == 0)

        // AppKit may deliver the sheet completion after endSheet/cancel.
        // It must not resume the request a second time.
        activeCompletion?(.alertFirstButtonReturn)
        await settle()
        #expect(cancelCount == 1)
    }

    @Test("task cancellation aborts its active request exactly once")
    func taskCancellationEndsActiveRequest() async {
        let window = NSWindow()
        let coordinator = WindowDialogCoordinator(ownerWindow: window)
        var lateCompletion: ((NSApplication.ModalResponse) -> Void)?
        var cancelCount = 0

        let request = Task {
            await coordinator.present(
                start: { _, completion in
                    lateCompletion = completion
                },
                cancel: { _ in cancelCount += 1 }
            )
        }
        await settle()
        request.cancel()
        await settle()

        let didCancelRequest = coordinator.pendingRequestCount == 0
        #expect(didCancelRequest)
        #expect(!coordinator.isOwnerClosed)
        if !didCancelRequest {
            coordinator.ownerDidClose()
        }
        #expect(await request.value == .abort)
        #expect(cancelCount == 1)
        #expect(coordinator.pendingRequestCount == 0)

        lateCompletion?(.alertFirstButtonReturn)
        await settle()
        #expect(cancelCount == 1)
        #expect(coordinator.pendingRequestCount == 0)
    }

    @Test("injected notification center owns the close lifecycle")
    func injectedNotificationCenterCancelsRequest() async {
        let window = NSWindow()
        let notificationCenter = NotificationCenter()
        let coordinator = WindowDialogCoordinator(
            ownerWindow: window,
            notificationCenter: notificationCenter
        )
        var cancelCount = 0

        let request = Task {
            await coordinator.present(
                start: { _, _ in },
                cancel: { _ in cancelCount += 1 }
            )
        }
        await settle()

        notificationCenter.post(
            name: NSWindow.willCloseNotification,
            object: window
        )
        await settle()

        #expect(await request.value == .abort)
        #expect(cancelCount == 1)
        #expect(coordinator.pendingRequestCount == 0)
    }

    @Test("missing owner fails closed without starting UI")
    func missingOwnerFailsClosed() async {
        var didStart = false
        let response = await DialogPresentationContext.unscoped.present(
            start: { _, _ in didStart = true },
            cancel: { _ in }
        )
        #expect(response == .abort)
        #expect(!didStart)
    }

    @Test("native adapters fail closed for a hidden owner")
    func hiddenOwnerFailsClosed() async {
        let window = NSWindow()
        let context = DialogPresentationContext(window: window)
        let alert = NSAlert()
        alert.messageText = "Hidden"
        alert.addButton(withTitle: "OK")

        let response = await alert.runSheet(on: context)

        #expect(response == .abort)
        #expect(window.attachedSheet == nil)
        DialogPresenter.ownerDidClose(window)
    }

    @Test("application owner eligibility rejects hidden and miniaturized states")
    func applicationOwnerEligibility() {
        #expect(
            DialogPresenter.applicationOwnerState(
                isVisible: true,
                isMiniaturized: false
            ) == .eligible
        )
        #expect(
            DialogPresenter.applicationOwnerState(
                isVisible: true,
                isMiniaturized: true
            ) == .miniaturized
        )
        #expect(
            DialogPresenter.applicationOwnerState(
                isVisible: false,
                isMiniaturized: false
            ) == .unavailable
        )
        #expect(
            DialogPresenter.applicationOwnerState(
                isVisible: false,
                isMiniaturized: true
            ) == .unavailable
        )
    }

    @Test("application dialog owner plan keeps, restores, or creates deterministically")
    func applicationDialogOwnerPlan() {
        #expect(
            DialogPresenter.applicationOwnerPlan(
                for: [.miniaturized, .eligible, .unavailable]
            ) == .keepExisting
        )
        #expect(
            DialogPresenter.applicationOwnerPlan(
                for: [.unavailable, .miniaturized, .miniaturized]
            ) == .restore(index: 1)
        )
        #expect(
            DialogPresenter.applicationOwnerPlan(
                for: [.unavailable, .unavailable]
            ) == .showWelcome
        )
        #expect(
            DialogPresenter.applicationOwnerPlan(for: []) == .showWelcome
        )
    }

    @Test("project lookup captures the matching window, not the key window")
    func routesToMatchingProjectWindow() {
        // This is a routing test, so do not load real project directories:
        // doing so starts asynchronous workspace + git work unrelated to the
        // presentation contract.
        let firstProject = ProjectManager()
        let secondProject = ProjectManager()
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        DialogPresenter.register(window: firstWindow, projectManager: firstProject)
        DialogPresenter.register(window: secondWindow, projectManager: secondProject)
        defer {
            DialogPresenter.ownerDidClose(firstWindow)
            DialogPresenter.ownerDidClose(secondWindow)
        }

        #expect(DialogPresenter.forProject(firstProject).nsWindow === firstWindow)
        #expect(DialogPresenter.forProject(secondProject).nsWindow === secondWindow)
        #expect(firstProject.primaryTabManager.dialogContextProvider().nsWindow === firstWindow)
        #expect(secondProject.primaryTabManager.dialogContextProvider().nsWindow === secondWindow)
    }

    @Test("same-window project rebind aborts the old active and queued generation")
    func sameWindowProjectRebindRetiresCoordinatorGeneration() async {
        let window = NSWindow()
        let firstProject = ProjectManager()
        let secondProject = ProjectManager()
        let firstContext = DialogPresenter.register(
            window: window,
            projectManager: firstProject
        )
        var activeCompletion: ((NSApplication.ModalResponse) -> Void)?
        var activeCancelCount = 0
        var queuedStarted = false

        let active = Task {
            await firstContext.present(
                start: { _, completion in
                    activeCompletion = completion
                },
                cancel: { _ in
                    activeCancelCount += 1
                }
            )
        }
        await settle()
        let queued = Task {
            await firstContext.present(
                start: { _, _ in
                    queuedStarted = true
                },
                cancel: { _ in }
            )
        }
        await settle()

        let secondContext = DialogPresenter.register(
            window: window,
            projectManager: secondProject
        )
        await settle()

        #expect(await active.value == .abort)
        #expect(await queued.value == .abort)
        #expect(activeCancelCount == 1)
        #expect(!queuedStarted)
        #expect(firstContext.nsWindow == nil)
        #expect(DialogPresenter.projectManager(for: window) === secondProject)
        #expect(firstProject.dialogOwnerWindow == nil)
        #expect(secondProject.dialogOwnerWindow === window)

        var secondCompletion: ((NSApplication.ModalResponse) -> Void)?
        let secondRequest = Task {
            await secondContext.present(
                start: { _, completion in
                    secondCompletion = completion
                },
                cancel: { _ in }
            )
        }
        await settle()
        if let secondCompletion {
            secondCompletion(.alertFirstButtonReturn)
        } else {
            DialogPresenter.ownerDidClose(window)
        }
        #expect(await secondRequest.value == .alertFirstButtonReturn)

        // A late AppKit callback from the retired generation is harmless.
        activeCompletion?(.alertFirstButtonReturn)
        await settle()
        #expect(activeCancelCount == 1)
        DialogPresenter.ownerDidClose(window)
    }

    @Test("owner close clears the project-owned weak anchor")
    func ownerCloseClearsProjectAnchor() {
        let project = ProjectManager()
        let window = NSWindow()
        DialogPresenter.register(window: window, projectManager: project)

        #expect(project.dialogOwnerWindow === window)
        DialogPresenter.ownerDidClose(window)
        #expect(project.dialogOwnerWindow == nil)
        #expect(DialogPresenter.forProject(project).nsWindow == nil)
    }

    @Test("closing an obsolete owner does not clear a rebound project anchor")
    func obsoleteOwnerClosePreservesNewAnchor() {
        let project = ProjectManager()
        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        let oldContext = DialogPresenter.register(
            window: oldWindow,
            projectManager: project
        )
        DialogPresenter.register(window: newWindow, projectManager: project)
        defer { DialogPresenter.ownerDidClose(newWindow) }

        DialogPresenter.ownerDidClose(oldWindow)

        #expect(oldContext.nsWindow == nil)
        #expect(DialogPresenter.projectManager(for: oldWindow) == nil)
        #expect(project.dialogOwnerWindow === newWindow)
        #expect(DialogPresenter.forProject(project).nsWindow === newWindow)
    }

    @Test("project stateful dialog operations recompute in FIFO order")
    func projectDialogOperationsAreSerialized() async {
        let project = ProjectManager()
        var events: [String] = []
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)

        project.enqueueDialogOperation {
            events.append("first-start")
            for await _ in gate {
                break
            }
            events.append("first-end")
        }
        project.enqueueDialogOperation {
            events.append("second")
        }
        await settle()

        #expect(events == ["first-start"])
        gateContinuation.yield()
        gateContinuation.finish()
        for _ in 0..<50 {
            if events.count == 3 { break }
            await Task.yield()
        }

        #expect(events == ["first-start", "first-end", "second"])
    }

    // MARK: - Foreign-sheet watchdog (#1335 H2)
    //
    // A foreign (framework/SwiftUI) sheet occupying the owner blocks a queued
    // native request. SwiftUI sheets do not reliably emit
    // `didEndSheetNotification`, so without a watchdog the request could wait
    // forever for a signal that never arrives. The coordinator polls the
    // owner on a bounded cadence and, once the foreign sheet clears, presents
    // the queued request; after the bound it aborts so the queue can never
    // wedge permanently.

    @Test("queued request presents via watchdog when didEndSheet is not delivered")
    func watchdogAdvancesBlockedRequestWithoutNotification() async {
        let owner = makeVisibleWindow()
        let foreignSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Empty notification center: the coordinator never receives
        // didEndSheet, so only the watchdog can advance the queued request.
        let coordinator = WindowDialogCoordinator(
            ownerWindow: owner,
            notificationCenter: NotificationCenter(),
            watchdogInterval: 0.01,
            watchdogMaxAttempts: 500
        )
        var startCount = 0
        var completion: ((NSApplication.ModalResponse) -> Void)?
        defer {
            coordinator.ownerDidClose()
            owner.orderOut(nil)
        }

        owner.beginSheet(foreignSheet) { _ in }
        let response = Task {
            await coordinator.present(
                start: { _, callback in
                    startCount += 1
                    completion = callback
                },
                cancel: { _ in }
            )
        }
        await settle()
        #expect(startCount == 0) // blocked by the foreign sheet

        // End the foreign sheet. NSWindow posts didEndSheet to .default, which
        // the coordinator does not observe here — only the watchdog re-checks.
        owner.endSheet(foreignSheet, returnCode: .cancel)
        for _ in 0..<2000 {
            if startCount == 1 { break }
            await Task.yield()
        }
        #expect(startCount == 1)

        if let completion {
            completion(.alertFirstButtonReturn)
        } else {
            coordinator.ownerDidClose()
        }
        #expect(await response.value == .alertFirstButtonReturn)
    }

    @Test("a request blocked past the watchdog bound aborts instead of hanging forever")
    func blockedRequestAbortsAfterWatchdogBound() async {
        let owner = makeVisibleWindow()
        let foreignSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowDialogCoordinator(
            ownerWindow: owner,
            notificationCenter: NotificationCenter(),
            watchdogInterval: 0.01,
            watchdogMaxAttempts: 3
        )
        var started = false
        defer {
            coordinator.ownerDidClose()
            owner.orderOut(nil)
        }

        owner.beginSheet(foreignSheet) { _ in } // foreign sheet never ends
        let response = Task {
            await coordinator.present(
                start: { _, _ in started = true },
                cancel: { _ in }
            )
        }

        // Bound is ~30 ms; the request must resolve (abort) rather than hang.
        #expect(await response.value == .abort)
        #expect(!started)
    }
}

@Suite("Dialog flow regressions")
@MainActor
struct DialogFlowRegressionTests {
    @Test("single dirty tab remains open when save fails")
    func dirtySingleTabSaveFailureIsFailClosed() async {
        let manager = TabManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-save-failure.swift"),
            content: "modified",
            savedContent: "original"
        )
        manager.tabs = [tab]
        manager.activeTabID = tab.id

        let closed = await TabCloseHelper.closeTab(
            tab,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertFirstButtonReturn },
            saveTab: { _ in false }
        )

        #expect(!closed)
        #expect(manager.tabs.map(\.id) == [tab.id])
        #expect(manager.tabs[0].isDirty)
    }

    @Test("discard closes the last dirty tab only after the decision resolves")
    func dirtyLastTabDiscardCompletesClose() async {
        let manager = TabManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-discard.swift"),
            content: "modified",
            savedContent: "original"
        )
        manager.tabs = [tab]
        manager.activeTabID = tab.id

        let closed = await TabCloseHelper.closeTab(
            tab,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertSecondButtonReturn }
        )

        #expect(closed)
        #expect(manager.tabs.isEmpty)
    }

    @Test("single-tab discard is rejected when content changes during the sheet")
    func dirtySingleTabRejectsStaleDiscard() async {
        let manager = TabManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-stale-discard.swift"),
            content: "first modification",
            savedContent: "original"
        )
        manager.tabs = [tab]
        manager.activeTabID = tab.id

        let closed = await TabCloseHelper.closeTab(
            tab,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: {
                manager.updateContent("new modification")
                return .alertSecondButtonReturn
            }
        )

        #expect(!closed)
        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.content == "new modification")
    }

    @Test("single-tab save is rejected when the tab is dirtied again")
    func dirtySingleTabRejectsStaleSave() async {
        let manager = TabManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-stale-save.swift"),
            content: "first modification",
            savedContent: "original"
        )
        manager.tabs = [tab]
        manager.activeTabID = tab.id

        let closed = await TabCloseHelper.closeTab(
            tab,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertFirstButtonReturn },
            saveTab: { index in
                manager.tabs[index].savedContent = manager.tabs[index].content
                manager.tabs[index].content = "edited after save"
                return true
            }
        )

        #expect(!closed)
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].isDirty)
        #expect(manager.tabs[0].content == "edited after save")
    }

    @Test("captured clean value cannot bypass a newly dirty live tab")
    func capturedCleanTabReResolvesDirtyState() async {
        let manager = TabManager()
        let captured = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-clean-snapshot.swift"),
            content: "original",
            savedContent: "original"
        )
        var live = captured
        live.content = "edited before async entry"
        manager.tabs = [live]
        manager.activeTabID = live.id
        var alertCount = 0

        let closed = await TabCloseHelper.closeTab(
            captured,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: {
                alertCount += 1
                return .alertThirdButtonReturn
            }
        )

        #expect(!closed)
        #expect(alertCount == 1)
        #expect(manager.tabs.first?.content == "edited before async entry")
        #expect(manager.tabs.first?.isDirty == true)
    }

    @Test("disappeared captured tab fails closed without presenting")
    func disappearedTabDoesNotReportFalseClose() async {
        let manager = TabManager()
        let captured = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-missing.swift"),
            content: "edited",
            savedContent: "original"
        )
        var alertCount = 0

        let closed = await TabCloseHelper.closeTab(
            captured,
            in: manager,
            gitProvider: GitStatusProvider(),
            presentAlert: {
                alertCount += 1
                return .alertSecondButtonReturn
            }
        )

        #expect(!closed)
        #expect(alertCount == 0)
        #expect(manager.tabs.isEmpty)
    }

    @Test("dirty authorization excludes clean tabs and rejects clean-to-dirty")
    func dirtyAuthorizationRejectsCleanToDirtyTransition() {
        let displayedDirty = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-displayed-dirty.swift"),
            content: "edited",
            savedContent: "saved"
        )
        var displayedClean = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dialog-displayed-clean.swift"),
            content: "saved",
            savedContent: "saved"
        )
        let authorization = DirtyEditorContentAuthorization(
            tabs: [displayedDirty, displayedClean]
        )

        #expect(authorization.covers([displayedDirty]))
        displayedClean.content = "became dirty while sheet was visible"
        #expect(!authorization.covers([displayedDirty, displayedClean]))
    }

    @Test("discard commit validates every buffer before mutating any buffer")
    func discardCommitIsAtomicWithinTabManager() {
        let manager = TabManager()
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-discard-atomic-first.swift"),
            content: "first edit",
            savedContent: "first saved"
        )
        var second = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-discard-atomic-second.swift"),
            content: "second edit",
            savedContent: "second saved"
        )
        manager.tabs = [first, second]
        let authorization = DirtyEditorContentAuthorization(tabs: manager.tabs)
        second.content = "newer second edit"
        manager.tabs[1] = second

        #expect(!manager.discardChanges(authorizedBy: authorization))
        #expect(manager.tabs[0].content == "first edit")
        #expect(manager.tabs[0].isDirty)
        #expect(manager.tabs[1].content == "newer second edit")
        #expect(manager.tabs[1].isDirty)
    }

    @Test("large-file response mapping is fail closed")
    func largeFileResponseMapping() {
        #expect(
            TabPersistence.largeFileDecision(for: .alertFirstButtonReturn)
                == .openWithoutHighlighting
        )
        #expect(
            TabPersistence.largeFileDecision(for: .alertSecondButtonReturn)
                == .openWithHighlighting
        )
        #expect(TabPersistence.largeFileDecision(for: .abort) == .cancel)
        #expect(TabPersistence.largeFileDecision(for: .cancel) == .cancel)
    }

    @Test("production Swift contains no application-modal dialog calls")
    func noApplicationModalRegression() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Pine")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        let forbiddenAPIs = [
            "runModal(",
            "beginModalSession(",
            "runModalSession(",
            "runModal(for:",
            "beginModal(for:",
            "panel.begin {",
            "panel.begin(completionHandler:",
        ]
        var offenders: [String] = []
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for forbiddenAPI in forbiddenAPIs where source.contains(forbiddenAPI) {
                offenders.append(
                    "\(fileURL.lastPathComponent): \(forbiddenAPI)"
                )
            }
        }
        #expect(offenders.isEmpty, "Application-modal calls: \(offenders)")
    }
}
