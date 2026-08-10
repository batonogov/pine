//
//  WindowLifecycleTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Window Lifecycle Tests", .serialized)
@MainActor
struct WindowLifecycleTests {
    private func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(agentTasks: AgentTaskRegistry(
            persistence: WindowLifecycleAgentTaskStore()
        ))
    }

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

    private func updateContent(
        _ content: String,
        in project: ProjectManager
    ) {
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.updateContent(content)
    }

    // MARK: - onDisappear logic (handleProjectWindowDisappear)

    @Test func closingLastProjectTriggersShowWelcome() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = makeRegistry()
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

        let registry = makeRegistry()
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

        let registry = makeRegistry()
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

        let registry = makeRegistry()
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

        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// dirty", in: project)

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
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .applicationQuitFailure,
            ]
        )
        #expect(saveAttempts == 1)
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func saveAsDeliberationDoesNotConsumeMachineDeadline() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let destination = dir.appendingPathComponent("saved.swift")
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// saved after a slow panel", in: project)
        project.saveDestinationChooser = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(600))
            return destination
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        let deadlineProbe = TerminationDeadlineProbe()

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                switch template {
                case .applicationQuitSummary, .unsavedChangesBulk:
                    return .alertFirstButtonReturn
                default:
                    Issue.record("Unexpected Quit alert: \(template)")
                    return .abort
                }
            },
            terminationDeadlineOverride: .now() + .milliseconds(500),
            terminationDeadlineObserver: deadlineProbe.record
        )

        #expect(result)
        #expect(deadlineProbe.elapsedNanoseconds == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) ==
                "// saved after a slow panel\n")
        #expect(!project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func cancellingQuitSavePanelDoesNotShowMachineFailure() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// keep", in: project)
        project.saveDestinationChooser = { _, _, _ in nil }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
            ]
        )
        #expect(project.hasUnsavedChanges)
        #expect(project.primaryTabManager.activeTab?.fileURL == nil)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func newDirtyTabDuringQuitSavePanelInvalidatesPlan() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let destination = dir.appendingPathComponent("first.swift")
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// first dirty", in: project)
        project.saveDestinationChooser = { _, _, _ in
            _ = project.createUntitledFile()
            project.activeTabManager.autoSavePreferenceProvider = { false }
            project.activeTabManager.updateContent("// created during panel")
            return destination
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .applicationQuitFailure,
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(project.allDirtyTabs.count == 2)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func multipleSlowReviewPromptsDoNotConsumeMachineDeadline() async throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }
        let firstFile = try makeTempFile(in: firstDirectory, name: "first.swift")
        let secondFile = try makeTempFile(in: secondDirectory, name: "second.swift")
        let registry = makeRegistry()
        let first = try #require(registry.projectManager(for: firstDirectory))
        let second = try #require(registry.projectManager(for: secondDirectory))
        first.primaryTabManager.openTab(url: firstFile)
        second.primaryTabManager.openTab(url: secondFile)
        updateContent("// first dirty", in: first)
        updateContent("// second dirty", in: second)
        let delegate = AppDelegate()
        delegate.registry = registry
        let deadlineProbe = TerminationDeadlineProbe()
        var projectPromptCount = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                if template == .applicationQuitSummary {
                    return .alertFirstButtonReturn
                }
                #expect(template == .unsavedChangesBulk)
                projectPromptCount += 1
                try? await Task.sleep(for: .milliseconds(300))
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + .milliseconds(500),
            terminationDeadlineObserver: deadlineProbe.record
        )

        #expect(result)
        #expect(projectPromptCount == 2)
        #expect(deadlineProbe.elapsedNanoseconds == nil)
        await first.workspace.waitForLoadingComplete()
        await second.workspace.waitForLoadingComplete()
    }

    @Test func cleanPreflightFailureResolvesOwnerLazily() async {
        let delegate = AppDelegate()
        delegate.registry = makeRegistry()
        let owner = NSWindow()
        let expectedContext = DialogPresentationContext(window: owner)
        defer { DialogPresenter.ownerDidClose(owner) }
        var contextResolutionCount = 0
        var presentedOwner: NSWindow?
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
                presentedTemplates.append(template)
                presentedOwner = context.nsWindow
                return .alertFirstButtonReturn
            },
            terminationFailureContext: {
                contextResolutionCount += 1
                return expectedContext
            },
            terminationDeadlineOverride: .now()
        )

        #expect(!result)
        #expect(contextResolutionCount == 1)
        #expect(presentedTemplates == [.applicationQuitFailure])
        #expect(presentedOwner === owner)
    }

    @Test func laterReviewPromptUsesReplacementProjectOwner() async throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }
        let firstDirectory = root.appendingPathComponent("a-first")
        let secondDirectory = root.appendingPathComponent("b-second")
        try FileManager.default.createDirectory(
            at: firstDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: false
        )
        let firstFile = try makeTempFile(in: firstDirectory, name: "first.swift")
        let secondFile = try makeTempFile(in: secondDirectory, name: "second.swift")
        let registry = makeRegistry()
        let first = try #require(registry.projectManager(for: firstDirectory))
        let second = try #require(registry.projectManager(for: secondDirectory))
        first.primaryTabManager.openTab(url: firstFile)
        second.primaryTabManager.openTab(url: secondFile)
        updateContent("// first dirty", in: first)
        updateContent("// second dirty", in: second)

        let firstWindow = NSWindow()
        let oldSecondWindow = NSWindow()
        let newSecondWindow = NSWindow()
        firstWindow.orderFront(nil)
        oldSecondWindow.orderFront(nil)
        let applicationContext = DialogPresenter.register(
            window: firstWindow,
            projectManager: first
        )
        DialogPresenter.register(
            window: oldSecondWindow,
            projectManager: second
        )
        defer {
            for window in [firstWindow, oldSecondWindow, newSecondWindow] {
                DialogPresenter.ownerDidClose(window)
                window.orderOut(nil)
            }
        }

        let delegate = AppDelegate()
        delegate.registry = registry
        var reviewPromptCount = 0
        var laterPromptOwner: NSWindow?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
                if template == .applicationQuitSummary {
                    return .alertFirstButtonReturn
                }
                #expect(template == .unsavedChangesBulk)
                reviewPromptCount += 1
                if reviewPromptCount == 1 {
                    #expect(context.nsWindow === firstWindow)
                    DialogPresenter.ownerDidClose(oldSecondWindow)
                    oldSecondWindow.orderOut(nil)
                    newSecondWindow.orderFront(nil)
                    DialogPresenter.register(
                        window: newSecondWindow,
                        projectManager: second
                    )
                    return .alertSecondButtonReturn
                }
                laterPromptOwner = context.nsWindow
                return .alertThirdButtonReturn
            },
            applicationContext: applicationContext,
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(reviewPromptCount == 2)
        #expect(laterPromptOwner === newSecondWindow)
        #expect(first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges)
        await first.workspace.waitForLoadingComplete()
        await second.workspace.waitForLoadingComplete()
    }

    @Test func quitDecisionRetriesAfterProjectOwnerCloses() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// keep after owner closes", in: project)

        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        oldWindow.orderFront(nil)
        let applicationContext = DialogPresenter.register(
            window: oldWindow,
            projectManager: project
        )
        defer {
            for window in [oldWindow, newWindow] {
                DialogPresenter.ownerDidClose(window)
                window.orderOut(nil)
            }
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var unsavedPromptOwners: [NSWindow?] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
                if template == .applicationQuitSummary {
                    return .alertFirstButtonReturn
                }
                #expect(template == .unsavedChangesBulk)
                unsavedPromptOwners.append(context.nsWindow)
                if unsavedPromptOwners.count == 1 {
                    DialogPresenter.ownerDidClose(oldWindow)
                    oldWindow.orderOut(nil)
                    newWindow.orderFront(nil)
                    DialogPresenter.register(
                        window: newWindow,
                        projectManager: project
                    )
                    return .abort
                }
                return .alertThirdButtonReturn
            },
            applicationContext: applicationContext,
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(unsavedPromptOwners.count == 2)
        #expect(unsavedPromptOwners[0] === oldWindow)
        #expect(unsavedPromptOwners[1] === newWindow)
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func quitFailureRetriesUntilAcknowledgementIsDisplayed() async {
        let delegate = AppDelegate()
        delegate.registry = makeRegistry()
        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        let oldContext = DialogPresentationContext(window: oldWindow)
        let newContext = DialogPresentationContext(window: newWindow)
        defer {
            DialogPresenter.ownerDidClose(oldWindow)
            DialogPresenter.ownerDidClose(newWindow)
        }
        var contextResolutionCount = 0
        var presentedOwners: [NSWindow?] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
                #expect(template == .applicationQuitFailure)
                presentedOwners.append(context.nsWindow)
                if presentedOwners.count == 1 {
                    DialogPresenter.ownerDidClose(oldWindow)
                    return .abort
                }
                return .alertFirstButtonReturn
            },
            terminationFailureContext: {
                defer { contextResolutionCount += 1 }
                return contextResolutionCount == 0
                    ? oldContext
                    : newContext
            },
            terminationDeadlineOverride: .now()
        )

        #expect(!result)
        #expect(contextResolutionCount == 2)
        #expect(presentedOwners.count == 2)
        #expect(presentedOwners[0] === oldWindow)
        #expect(presentedOwners[1] === newWindow)
    }

    @Test func quitFailureRetriesPastFourLostOwnersUntilAcknowledged() async {
        let delegate = AppDelegate()
        delegate.registry = makeRegistry()
        let owner = NSWindow()
        let context = DialogPresentationContext(window: owner)
        defer { DialogPresenter.ownerDidClose(owner) }
        var presentationCount = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .applicationQuitFailure)
                presentationCount += 1
                return presentationCount <= 4
                    ? .abort
                    : .alertFirstButtonReturn
            },
            terminationFailureContext: { context },
            terminationDeadlineOverride: .now()
        )

        #expect(!result)
        #expect(presentationCount == 5)
    }

    @Test func saveAsUsesReplacementProjectOwnerAfterReview() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// keep unsaved", in: project)

        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        oldWindow.orderFront(nil)
        let oldContext = DialogPresenter.register(
            window: oldWindow,
            projectManager: project
        )
        defer {
            for window in [oldWindow, newWindow] {
                DialogPresenter.ownerDidClose(window)
                window.orderOut(nil)
            }
        }
        var saveAsOwner: NSWindow?
        var saveAsCount = 0
        project.saveDestinationChooser = { _, _, context in
            saveAsCount += 1
            saveAsOwner = context.nsWindow
            return nil
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                if template == .unsavedChangesBulk {
                    DialogPresenter.ownerDidClose(oldWindow)
                    oldWindow.orderOut(nil)
                    newWindow.orderFront(nil)
                    DialogPresenter.register(
                        window: newWindow,
                        projectManager: project
                    )
                }
                return .alertFirstButtonReturn
            },
            applicationContext: oldContext,
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
            ]
        )
        #expect(saveAsCount == 1)
        #expect(saveAsOwner === newWindow)
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func detailedQuitSaveFailureUsesReboundProjectOwner() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// cannot stage", in: project)
        project.saveDestinationChooser = { _, _, _ in
            dir.appendingPathComponent("missing-parent/file.swift")
        }
        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        let replacementFailureWindow = NSWindow()
        oldWindow.orderFront(nil)
        let oldContext = DialogPresenter.register(
            window: oldWindow,
            projectManager: project
        )
        defer {
            DialogPresenter.ownerDidClose(oldWindow)
            DialogPresenter.ownerDidClose(newWindow)
            DialogPresenter.ownerDidClose(replacementFailureWindow)
            oldWindow.orderOut(nil)
            newWindow.orderOut(nil)
            replacementFailureWindow.orderOut(nil)
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []
        var errorOwners: [NSWindow?] = []
        var errorMessages: [String] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, message in
                presented.append(template)
                if template == .unsavedChangesBulk {
                    DialogPresenter.ownerDidClose(oldWindow)
                    oldWindow.orderOut(nil)
                    newWindow.orderFront(nil)
                    DialogPresenter.register(
                        window: newWindow,
                        projectManager: project
                    )
                }
                if template == .fileOperationErrorCritical {
                    errorOwners.append(context.nsWindow)
                    errorMessages.append(message)
                    if errorOwners.count == 1 {
                        DialogPresenter.ownerDidClose(newWindow)
                        newWindow.orderOut(nil)
                        replacementFailureWindow.orderFront(nil)
                        DialogPresenter.register(
                            window: replacementFailureWindow,
                            projectManager: project
                        )
                        return .abort
                    }
                }
                return .alertFirstButtonReturn
            },
            applicationContext: oldContext,
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .fileOperationErrorCritical,
                .fileOperationErrorCritical,
            ]
        )
        #expect(errorOwners.count == 2)
        #expect(errorOwners[0] === newWindow)
        #expect(errorOwners[1] === replacementFailureWindow)
        #expect(errorMessages == [
            Strings.applicationQuitFailureMessage,
            Strings.applicationQuitFailureMessage,
        ])
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func quitSaveCleanupFailureShowsRetainedArtifact() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let file = try makeTempFile(in: directory, name: "cleanup.swift")
        let retainedArtifact = directory.appendingPathComponent(
            ".pine-save-retained.tmp"
        )
        let registry = makeRegistry()
        let project = try #require(
            registry.projectManager(for: directory)
        )
        project.primaryTabManager.openTab(url: file)
        updateContent("// unsaved cleanup bytes", in: project)
        project.terminationSaveInstaller = { _, _, _ in
            return .failed(
                message: "internal unlocalized installer detail",
                retainedArtifacts: []
            )
        }
        nonisolated(unsafe) var cleanupAttempts = 0
        project.terminationSaveCleaner = { _ in
            cleanupAttempts += 1
            guard cleanupAttempts == 1 else { return .cleaned }
            return .failed(
                message: "internal unlocalized cleanup detail",
                retainedArtifacts: [retainedArtifact]
            )
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []
        var failureMessage: String?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, message in
                presented.append(template)
                if template == .fileOperationErrorCritical {
                    failureMessage = message
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(presented == [
            .applicationQuitSummary,
            .unsavedChangesBulk,
            .fileOperationErrorCritical,
        ])
        #expect(failureMessage == Strings.applicationQuitFailureMessage
            + "\n\n"
            + retainedArtifact.path)
        #expect(!(failureMessage?.contains("unlocalized") ?? true))
        #expect(cleanupAttempts == 1)
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func terminationBudgetAlwaysReservesRollback() {
        let long = AppDelegate.terminationBudgetSplit(
            availableNanoseconds: 30_000_000_000
        )
        #expect(long?.forwardNanoseconds == 28_000_000_000)
        #expect(long?.rollbackNanoseconds == 2_000_000_000)

        let short = AppDelegate.terminationBudgetSplit(
            availableNanoseconds: 100_000_000
        )
        #expect(short?.forwardNanoseconds == 50_000_000)
        #expect(short?.rollbackNanoseconds == 50_000_000)
        #expect(AppDelegate.terminationBudgetSplit(
            availableNanoseconds: 1
        ) == nil)
    }

    @Test func terminationDeadlineDoesNotBoundHumanDeliberation() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// dirty", in: project)
        let delegate = AppDelegate()
        delegate.registry = registry
        let deadlineProbe = TerminationDeadlineProbe()
        let started = DispatchTime.now().uptimeNanoseconds

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                if template == .applicationQuitSummary {
                    try? await Task.sleep(for: .milliseconds(600))
                    return .alertSecondButtonReturn
                }
                Issue.record("Unexpected Quit alert: \(template)")
                return .abort
            },
            terminationDeadlineOverride: .now() + .milliseconds(500),
            terminationDeadlineObserver: deadlineProbe.record
        )

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(result)
        // ContinuousClock sleeps may wake within their platform tolerance;
        // the assertion only needs to prove the 500 ms machine budget did
        // not cap the user's decision time.
        #expect(elapsed >= 550_000_000)
        #expect(deadlineProbe.elapsedNanoseconds == nil)
        #expect(!project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func terminationDeadlineStillBoundsHungMachineWork() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// dirty", in: project)
        let delegate = AppDelegate()
        delegate.registry = registry
        let deadlineProbe = TerminationDeadlineProbe()
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            saveAll: { _, _ in
                try? await Task.sleep(for: .seconds(10))
                return true
            },
            terminationDeadlineOverride: .now() + .milliseconds(25),
            terminationDeadlineObserver: deadlineProbe.record
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .applicationQuitFailure,
            ]
        )
        #expect(
            deadlineProbe.elapsedNanoseconds.map { $0 < 1_000_000_000 } == true
        )
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func realQuitSaveTimeoutLeavesTargetAndTabUntouched() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// dirty before timeout", in: project)
        let probe = BlockingFormatterProbe()
        defer { probe.release() }
        let suiteName = "WindowLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        project.primaryTabManager.editorSettings = settings
        project.primaryTabManager.fileFormatters = FileFormatterRegistry(
            formatters: [probe.formatter()]
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        let deadlineProbe = TerminationDeadlineProbe()
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + .milliseconds(100),
            terminationDeadlineObserver: deadlineProbe.record
        )

        #expect(!result)
        #expect(probe.didStart)
        #expect(deadlineProbe.elapsedNanoseconds != nil)
        #expect(
            presented == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .fileOperationErrorCritical,
            ]
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "// test.swift")
        #expect(project.primaryTabManager.activeTab?.content ==
                "// dirty before timeout")
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func editBackDuringQuitSaveStagingInvalidatesGeneration() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)
        let probe = BlockingFormatterProbe()
        defer { probe.release() }
        let suiteName = "WindowLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        project.primaryTabManager.editorSettings = settings
        project.primaryTabManager.fileFormatters = FileFormatterRegistry(
            formatters: [probe.formatter()]
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []
        let quit = Task { @MainActor in
            await delegate.confirmApplicationTermination(
                presentAlert: { template, _, _, _ in
                    presented.append(template)
                    return .alertFirstButtonReturn
                },
                terminationDeadlineOverride: .now() + 5
            )
        }

        #expect(await probe.waitUntilStarted())
        project.primaryTabManager.updateContent("// edited during staging")
        project.primaryTabManager.updateContent("// captured dirty")
        probe.release()
        let result = await quit.value

        #expect(!result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .unsavedChangesBulk,
                .fileOperationErrorCritical,
            ]
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "// test.swift")
        #expect(project.primaryTabManager.activeTab?.content ==
                "// captured dirty")
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func paneReplacementInvalidatesStagedTerminationSave() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tabManager = project.primaryTabManager
        tabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)

        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready termination save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        guard case .ready = staged.0 else {
            Issue.record("Expected staged termination save artifacts")
            return
        }
        let stagedPlan = try #require(staged.1)

        project.paneManager.removePane(project.paneManager.activePaneID)
        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + 5
        )

        #expect(result == .invalidated)
        #expect(try String(contentsOf: file, encoding: .utf8) == "// test.swift")
        #expect(tabManager.activeTab?.content == "// captured dirty")
        #expect(tabManager.activeTab?.isDirty == true)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func externalReplacementInvalidatesTerminationStaging() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// local dirty", in: project)

        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready termination save plan")
            return
        }
        let originalDate = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[
                .modificationDate
            ] as? Date
        )
        try "// external".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: file.path
        )

        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )

        guard case .invalidated = staged.0 else {
            Issue.record("Expected the external replacement to invalidate staging")
            return
        }
        #expect(staged.1 == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "// external")
        #expect(project.primaryTabManager.activeTab?.content == "// local dirty")
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func applicationSaveRejectsCrossProjectDestinationAlias() async throws {
        let firstRoot = try makeTempDirectory()
        let secondRoot = try makeTempDirectory()
        defer { cleanup(firstRoot); cleanup(secondRoot) }
        let destination = firstRoot.appendingPathComponent("shared.swift")
        let registry = makeRegistry()
        let first = try #require(registry.projectManager(for: firstRoot))
        let second = try #require(registry.projectManager(for: secondRoot))
        _ = try #require(first.createUntitledFile())
        _ = try #require(second.createUntitledFile())
        updateContent("// first", in: first)
        updateContent("// second", in: second)
        first.saveDestinationChooser = { _, _, _ in destination }
        second.saveDestinationChooser = { _, _, _ in destination }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges)
        #expect(presented.last == .applicationQuitFailure)
        await first.workspace.waitForLoadingComplete()
        await second.workspace.waitForLoadingComplete()
    }

    @Test func applicationSaveRejectsCaseAliasedOpenFile() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let volumeValues = try dir.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        )
        guard volumeValues.volumeSupportsCaseSensitiveNames == false else {
            return
        }
        let openFile = try makeTempFile(in: dir, name: "shared.swift")
        let aliasedDestination = dir.appendingPathComponent("SHARED.swift")
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: openFile)
        _ = try #require(project.createUntitledFile())
        updateContent("// must remain untitled", in: project)
        project.saveDestinationChooser = { _, _, _ in aliasedDestination }
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in .alertFirstButtonReturn },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            try String(contentsOf: openFile, encoding: .utf8)
                == "// shared.swift"
        )
        let untitled = try #require(project.allTabs.first(where: {
            $0.fileURL == nil
        }))
        #expect(untitled.content == "// must remain untitled")
        #expect(untitled.isDirty)
        #expect(project.allTabs.first(where: { $0.fileURL == openFile })?
            .isDirty == false)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func applicationSaveRejectsAliasCreatedAfterInitialFence() async throws {
        let saveRoot = try makeTempDirectory()
        let observerRoot = try makeTempDirectory()
        defer { cleanup(saveRoot); cleanup(observerRoot) }
        let destinationParent = saveRoot.appendingPathComponent(
            "redirected",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationParent,
            withIntermediateDirectories: false
        )
        let observedFile = try makeTempFile(
            in: observerRoot,
            name: "shared.swift"
        )
        let destination = destinationParent.appendingPathComponent(
            observedFile.lastPathComponent
        )
        let registry = makeRegistry()
        let savingProject = try #require(
            registry.projectManager(for: saveRoot)
        )
        let observingProject = try #require(
            registry.projectManager(for: observerRoot)
        )
        observingProject.primaryTabManager.openTab(url: observedFile)
        _ = try #require(savingProject.createUntitledFile())
        updateContent("// must remain untitled", in: savingProject)
        savingProject.saveDestinationChooser = { _, _, _ in destination }
        let aliasCapture = TerminationAliasMutationProbe {
            do {
                try FileManager.default.removeItem(at: destinationParent)
                try FileManager.default.createSymbolicLink(
                    at: destinationParent,
                    withDestinationURL: observerRoot
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5,
            terminationAliasCapture: { urls, deadline in
                await aliasCapture.capture(urls, until: deadline)
            }
        )

        #expect(aliasCapture.mutationError == nil)
        #expect(aliasCapture.captureCount == 2)
        #expect(!result)
        #expect(
            try String(contentsOf: observedFile, encoding: .utf8)
                == "// shared.swift"
        )
        let untitled = try #require(savingProject.allTabs.first(where: {
            $0.fileURL == nil
        }))
        #expect(untitled.content == "// must remain untitled")
        #expect(untitled.isDirty)
        #expect(observingProject.allTabs.first(where: {
            $0.fileURL == observedFile
        })?.isDirty == false)
        #expect(presented.last == .fileOperationErrorCritical)
        await savingProject.workspace.waitForLoadingComplete()
        await observingProject.workspace.waitForLoadingComplete()
    }

    @Test func laterOpenTabStopsFutureTerminationInstall() async throws {
        let saveRoot = try makeTempDirectory()
        let observerRoot = try makeTempDirectory()
        defer { cleanup(saveRoot); cleanup(observerRoot) }
        let firstDestination = try makeTempFile(
            in: saveRoot,
            name: "first.swift"
        )
        let laterDestination = try makeTempFile(
            in: saveRoot,
            name: "later.swift"
        )
        let registry = makeRegistry()
        let savingProject = try #require(
            registry.projectManager(for: saveRoot)
        )
        let observingProject = try #require(
            registry.projectManager(for: observerRoot)
        )
        _ = try #require(savingProject.createUntitledFile())
        updateContent("// first captured", in: savingProject)
        _ = try #require(savingProject.createUntitledFile())
        updateContent("// later captured", in: savingProject)
        var destinationIndex = 0
        let destinations = [firstDestination, laterDestination]
        savingProject.saveDestinationChooser = { _, _, _ in
            defer { destinationIndex += 1 }
            return destinations[destinationIndex]
        }
        let installer = FirstTerminationInstallGate()
        defer { installer.release() }
        savingProject.terminationSaveInstaller = { staged, deadline, lateCompletion in
            await installer.install(
                staged,
                until: deadline,
                lateCompletion: lateCompletion
            )
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        let quit = Task { @MainActor in
            await delegate.confirmApplicationTermination(
                presentAlert: { _, _, _, _ in .alertFirstButtonReturn },
                terminationDeadlineOverride: .now() + 5
            )
        }

        #expect(await installer.waitUntilStarted())
        observingProject.primaryTabManager.openTab(url: laterDestination)
        installer.release()
        let result = await quit.value

        #expect(!result)
        #expect(installer.installCount == 1)
        #expect(
            try String(contentsOf: firstDestination, encoding: .utf8)
                == "// first captured\n"
        )
        #expect(
            try String(contentsOf: laterDestination, encoding: .utf8)
                == "// later.swift"
        )
        #expect(savingProject.allTabs.first(where: {
            $0.fileURL == firstDestination
        })?.isDirty == false)
        let unsavedLater = try #require(savingProject.allTabs.first(where: {
            $0.fileURL == nil && $0.content == "// later captured"
        }))
        #expect(unsavedLater.isDirty)
        let observed = try #require(observingProject.allTabs.first(where: {
            $0.fileURL == laterDestination
        }))
        #expect(!observed.isDirty)
        #expect(observed.content == "// later.swift")
        await savingProject.workspace.waitForLoadingComplete()
        await observingProject.workspace.waitForLoadingComplete()
    }

    @Test func destinationCreatedDuringStagingIsNotOverwritten() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let destination = dir.appendingPathComponent("created.swift")
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        _ = try #require(project.createUntitledFile())
        updateContent("// captured dirty", in: project)
        project.saveDestinationChooser = { _, _, _ in destination }
        let probe = BlockingFormatterProbe()
        defer { probe.release() }
        let suiteName = "WindowLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        project.primaryTabManager.editorSettings = settings
        project.primaryTabManager.fileFormatters = FileFormatterRegistry(
            formatters: [probe.formatter()]
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        let quit = Task { @MainActor in
            await delegate.confirmApplicationTermination(
                presentAlert: { _, _, _, _ in .alertFirstButtonReturn },
                terminationDeadlineOverride: .now() + 5
            )
        }

        #expect(await probe.waitUntilStarted())
        try "external".write(
            to: destination,
            atomically: false,
            encoding: .utf8
        )
        probe.release()
        let result = await quit.value

        #expect(!result)
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "external"
        )
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func quitAnywayCancelsPendingAutoSaveBeforeDecision() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tabs = project.primaryTabManager
        tabs.openTab(url: file)
        tabs.autoSavePreferenceProvider = { true }
        tabs.setAutoSaveDelay(0.05)
        tabs.updateContent("// must be discarded")
        #expect(tabs.hasScheduledAutoSave)
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .applicationQuitSummary)
                try? await Task.sleep(for: .milliseconds(200))
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(result)
        #expect(try String(contentsOf: file, encoding: .utf8) == "// test.swift")
        #expect(tabs.activeTab?.content == "// test.swift")
        #expect(!tabs.hasScheduledAutoSave)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func movedParentRetainedSaveSurvivesProjectCleanup() async throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let saveDirectory = directory.appendingPathComponent("sources")
        let movedDirectory = directory.appendingPathComponent("sources-moved")
        try FileManager.default.createDirectory(
            at: saveDirectory,
            withIntermediateDirectories: false
        )
        let file = try makeTempFile(in: saveDirectory, name: "moved.swift")
        let registry = makeRegistry()
        let project = try #require(
            registry.projectManager(for: directory)
        )
        project.primaryTabManager.openTab(url: file)
        updateContent("// retained dirty bytes", in: project)
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        let stagingProbe = TerminationStagingLeafProbe()
        project.terminationSaveInstaller = { staged, deadline, lateCompletion in
            stagingProbe.record(staged)
            return await TerminationSaveCoordinator.install(
                staged,
                until: deadline,
                beforeDestinationQuarantine: {
                    try? FileManager.default.moveItem(
                        at: saveDirectory,
                        to: movedDirectory
                    )
                    try? FileManager.default.createDirectory(
                        at: saveDirectory,
                        withIntermediateDirectories: false
                    )
                },
                lateCompletion: lateCompletion
            )
        }

        let result = await project
            .commitStagedSaveAllPaneTabsForTermination(
                stagedPlan,
                until: .now() + 5
            )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("Expected the moved parent install to fail closed")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        let movedArtifact = movedDirectory.appendingPathComponent(
            try #require(stagingProbe.leaf)
        )
        #expect(FileManager.default.fileExists(atPath: movedArtifact.path))
        #expect(
            try String(contentsOf: movedArtifact, encoding: .utf8)
                .contains("// retained dirty bytes")
        )
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func stagedCommitStopsBeforeNextFileAfterDeadline() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let firstURL = try makeTempFile(in: dir, name: "first.swift")
        let secondURL = try makeTempFile(in: dir, name: "second.swift")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750],
            ofItemAtPath: firstURL.path
        )
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tabs = project.primaryTabManager
        tabs.autoSavePreferenceProvider = { false }
        tabs.openTab(url: firstURL)
        tabs.updateContent("// first dirty")
        tabs.openTab(url: secondURL)
        tabs.updateContent("// second dirty")
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        let installer = DelayedTerminationInstallerProbe()
        project.terminationSaveInstaller = { staged, deadline, lateCompletion in
            await installer.install(
                staged,
                until: deadline,
                lateCompletion: lateCompletion
            )
        }

        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + .milliseconds(50)
        )

        guard case .failed(let message, let retainedArtifacts) = result else {
            Issue.record("Expected deadline cleanup failure")
            return
        }
        #expect(message == "Termination save cleanup exceeded its deadline")
        #expect(retainedArtifacts.isEmpty)
        #expect(installer.installCount == 1)
        #expect(
            try String(contentsOf: firstURL, encoding: .utf8)
                == "// first.swift"
        )
        #expect(
            try String(contentsOf: secondURL, encoding: .utf8)
                == "// second.swift"
        )
        let firstAttributes = try FileManager.default.attributesOfItem(
            atPath: firstURL.path
        )
        #expect(firstAttributes[.posixPermissions] as? Int == 0o750)
        #expect(tabs.tabs.first(where: { $0.fileURL == firstURL })?.isDirty == true)
        #expect(tabs.tabs.first(where: { $0.fileURL == secondURL })?.isDirty == true)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func cleanupTimeoutDoesNotClaimArtifactThatWorkerLaterDeletes() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        let cleaner = BlockingTerminationCleanerProbe { staged in
            TerminationSaveCoordinator.cleanup(staged)
        }
        project.terminationSaveCleaner = { staged in
            cleaner.clean(staged)
        }

        let cleanupTask = Task {
            await project.cleanupTerminationSavePlan(
                stagedPlan,
                until: .now() + .milliseconds(50)
            )
        }
        #expect(await cleaner.waitUntilStarted())
        let result = await cleanupTask.value

        guard case .failed(let message, let retainedArtifacts) = result else {
            Issue.record("Expected cleanup deadline failure")
            cleaner.release()
            return
        }
        #expect(message == "Termination save cleanup exceeded its deadline")
        #expect(retainedArtifacts.isEmpty)
        cleaner.release()
        #expect(await cleaner.waitUntilReturned())
        #expect(cleaner.stagingURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        await project.workspace.waitForLoadingComplete()
    }

    @Test func cleanupTimeoutReportsActualLateRetainedArtifact() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let retainedArtifact = dir.appendingPathComponent(
            ".pine-save-cleanup-retained"
        )
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        let cleaner = BlockingTerminationCleanerProbe { staged in
            guard let stagingURL = staged.first?.stagingURL else {
                return .cleaned
            }
            do {
                try FileManager.default.moveItem(
                    at: stagingURL,
                    to: retainedArtifact
                )
                return .failed(
                    message: "late cleanup retained recovery",
                    retainedArtifacts: [retainedArtifact]
                )
            } catch {
                return .failed(
                    message: error.localizedDescription,
                    retainedArtifacts: []
                )
            }
        }
        let report = TerminationLateFailureReportProbe()
        project.terminationSaveCleaner = { staged in
            cleaner.clean(staged)
        }
        project.terminationSaveLateFailureHandler = { message, artifacts in
            report.record(message: message, artifacts: artifacts)
        }

        let cleanupTask = Task {
            await project.cleanupTerminationSavePlan(
                stagedPlan,
                until: .now() + .milliseconds(50)
            )
        }
        #expect(await cleaner.waitUntilStarted())
        let result = await cleanupTask.value
        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("Expected cleanup deadline failure")
            cleaner.release()
            return
        }
        #expect(retainedArtifacts.isEmpty)

        cleaner.release()
        #expect(await cleaner.waitUntilReturned())
        #expect(await report.waitUntilRecorded())
        #expect(report.message == "late cleanup retained recovery")
        #expect(report.artifacts == [retainedArtifact])
        #expect(FileManager.default.fileExists(atPath: retainedArtifact.path))
        await project.workspace.waitForLoadingComplete()
    }

    @Test func lateTerminationInstallDoesNotRegressNewerSave() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tabs = project.primaryTabManager
        tabs.autoSavePreferenceProvider = { false }
        tabs.openTab(url: file)
        tabs.updateContent("// captured by termination")
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        let installer = PausedInstalledTerminationInstallerProbe()
        defer { installer.release() }
        project.terminationSaveInstaller = { staged, deadline, lateCompletion in
            await installer.install(
                staged,
                until: deadline,
                lateCompletion: lateCompletion
            )
        }
        let commit = Task {
            await project.commitStagedSaveAllPaneTabsForTermination(
                stagedPlan,
                until: .now() + .milliseconds(250)
            )
        }
        #expect(await installer.waitUntilInstalled())

        let result = await commit.value
        guard case .failed(let message, let retainedArtifacts) = result else {
            Issue.record("Expected timed-out cleanup failure")
            return
        }
        #expect(message == "Termination save cleanup exceeded its deadline")
        #expect(retainedArtifacts.isEmpty)
        #expect(
            try String(contentsOf: file, encoding: .utf8)
                == "// captured by termination\n"
        )

        let newerContent = "// saved after timeout"
        tabs.updateContent(newerContent)
        let index = try #require(tabs.tabs.firstIndex(where: {
            $0.fileURL == file
        }))
        let conflict: TabManager.ExternalConflict
        do {
            _ = try tabs.trySaveTab(at: index)
            Issue.record("Expected the late install to require overwrite authorization")
            return
        } catch let TabPersistence.SaveError.externalChange(observed) {
            conflict = observed
        }
        #expect(tabs.authorizeExternalChange(conflict))
        #expect(try tabs.trySaveTab(at: index))
        let savedTab = try #require(tabs.tabs.first(where: {
            $0.fileURL == file
        }))
        let persistedContent = savedTab.content
        #expect(persistedContent.hasPrefix(newerContent))
        #expect(savedTab.savedContent == persistedContent)
        let savedGeneration = savedTab.persistenceGeneration
        let savedModificationDate = savedTab.lastModDate
        let savedFileSize = savedTab.fileSizeBytes

        installer.release()
        #expect(await installer.waitUntilReturned())
        await settle()

        let reconciledTab = try #require(tabs.tabs.first(where: {
            $0.fileURL == file
        }))
        #expect(reconciledTab.content == persistedContent)
        #expect(reconciledTab.savedContent == persistedContent)
        #expect(reconciledTab.persistenceGeneration == savedGeneration)
        #expect(reconciledTab.lastModDate == savedModificationDate)
        #expect(reconciledTab.fileSizeBytes == savedFileSize)
        #expect(!reconciledTab.isDirty)
        #expect(
            try String(contentsOf: file, encoding: .utf8) == persistedContent
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test func lateTerminationFailureReportsActualRetainedPath() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let retainedArtifact = dir.appendingPathComponent(
            ".pine-save-late-retained"
        )
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)
        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready termination save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        nonisolated(unsafe) var reportedArtifacts: [URL] = []
        project.terminationSaveLateFailureHandler = { _, retainedArtifacts in
            reportedArtifacts = retainedArtifacts
        }
        project.terminationSaveInstaller = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return .failed(
                message: "late retained recovery",
                retainedArtifacts: [retainedArtifact]
            )
        }

        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + .milliseconds(25)
        )
        try? await Task.sleep(for: .milliseconds(150))

        guard case .failed = result else {
            Issue.record("Deadline cleanup should fail with retained staging")
            return
        }
        #expect(reportedArtifacts == [retainedArtifact])
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func replacedStagingFileIsRejectedBeforeInstall() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)

        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready termination save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        guard case .ready = staged.0 else {
            Issue.record("Expected staged termination save artifacts")
            return
        }
        let stagedPlan = try #require(staged.1)
        let stagingURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix(".pine-save-") })
        )
        try FileManager.default.removeItem(at: stagingURL)
        try "substituted".write(
            to: stagingURL,
            atomically: false,
            encoding: .utf8
        )

        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + 5
        )

        guard case .failed = result else {
            Issue.record("Expected substituted staging file to fail")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "// test.swift")
        #expect(
            try String(contentsOf: stagingURL, encoding: .utf8)
                == "substituted"
        )
        #expect(project.primaryTabManager.activeTab?.content ==
                "// captured dirty")
        #expect(project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func concurrentReplacementBeforeQuarantineIsRestored() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// captured dirty", in: project)

        let prepared = await project.prepareSaveAllPaneTabs(
            context: .unscoped
        )
        guard case .ready(let plan) = prepared else {
            Issue.record("Expected a ready termination save plan")
            return
        }
        let staged = await project.stagePreparedSaveAllPaneTabsForTermination(
            plan,
            until: .now() + 5
        )
        let stagedPlan = try #require(staged.1)
        project.terminationSaveInstaller = { staged, deadline, lateCompletion in
            await TerminationSaveCoordinator.install(
                staged,
                until: deadline,
                beforeDestinationQuarantine: {
                    try? FileManager.default.removeItem(at: file)
                    try? Data("external replacement".utf8).write(to: file)
                },
                lateCompletion: lateCompletion
            )
        }

        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + 5
        )

        guard case .failed = result else {
            Issue.record("Expected the raced install to fail")
            return
        }
        #expect(
            try String(contentsOf: file, encoding: .utf8)
                == "external replacement"
        )
        #expect(project.hasUnsavedChanges)
        let recoveryArtifacts = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".pine-save-recovery-") }
        #expect(recoveryArtifacts.isEmpty)
        await project.workspace.waitForLoadingComplete()
    }

    @Test func asyncTerminationCancelNeverAttemptsSave() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// dirty", in: project)

        let delegate = AppDelegate()
        delegate.registry = registry
        var saveAttempts = 0
        let fallbackWindow = NSWindow()
        let fallbackContext = DialogPresentationContext(window: fallbackWindow)
        defer { DialogPresenter.ownerDidClose(fallbackWindow) }
        var presentedOwner: NSWindow?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
                #expect(template == .applicationQuitSummary)
                presentedOwner = context.nsWindow
                return .alertThirdButtonReturn
            },
            saveAll: { _, _ in
                saveAttempts += 1
                return true
            },
            applicationContext: fallbackContext,
            terminationDeadlineOverride: .now() + 120
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

        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// first dirty state", in: project)

        let delegate = AppDelegate()
        delegate.registry = registry
        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                switch template {
                case .applicationQuitSummary:
                    return .alertFirstButtonReturn
                case .unsavedChangesBulk:
                    updateContent(
                        "// changed while quit sheet was visible",
                        in: project
                    )
                    return .alertSecondButtonReturn
                case .applicationQuitFailure:
                    return .alertFirstButtonReturn
                default:
                    Issue.record("Unexpected Quit alert: \(template)")
                    return .abort
                }
            },
            terminationDeadlineOverride: .now() + 120
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
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// discarded", in: project)
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs)
        #expect(project.recoveryManager?.pendingRecoveryEntries().isEmpty == false)
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .applicationQuitSummary)
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
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
        let registry = makeRegistry()
        let firstProject = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let secondProject = try #require(
            registry.projectManager(for: secondDirectory)
        )
        firstProject.primaryTabManager.openTab(url: firstFile)
        secondProject.primaryTabManager.openTab(url: secondFile)
        updateContent("// first dirty", in: firstProject)
        updateContent("// second dirty", in: secondProject)
        let delegate = AppDelegate()
        delegate.registry = registry
        var promptCount = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                if template == .applicationQuitSummary {
                    return .alertFirstButtonReturn
                }
                #expect(template == .unsavedChangesBulk)
                promptCount += 1
                return promptCount == 1
                    ? .alertSecondButtonReturn
                    : .alertThirdButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
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

    @Test func quitFailureIsVisibleWhenUserTaskCleanupDoesNotFinish() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let run = project.taskRunStore.start(makeTaskRun(id: "active"))
        let probe = TerminationTaskProbe(waitResult: false)
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return template == .applicationQuitSummary
                    ? .alertSecondButtonReturn
                    : .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(project.hasOutstandingUserTaskExecution)
        #expect(registry.isProjectOpen(dir))
        #expect(!registry.destroyAllProjects())
        #expect(registry.isProjectOpen(dir))

        project.taskRunStore.finishRun(
            id: run.id,
            outcome: makeTaskOutcome(id: "active"),
            cancelled: false
        )
        #expect(registry.destroyAllProjects())
    }

    @Test func quitSummaryCountsEveryDetachedTaskOwner() async throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }
        let registry = makeRegistry()
        let firstProject = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let secondProject = try #require(
            registry.projectManager(for: secondDirectory)
        )
        let firstRun = firstProject.taskRunStore.start(
            makeTaskRun(id: "first-detached")
        )
        let secondRun = secondProject.taskRunStore.start(
            makeTaskRun(id: "second-detached")
        )
        firstProject.taskRunStore.registerCancellation(
            TerminationTaskProbe(waitResult: false).makeCancellation(),
            forRunID: firstRun.id
        )
        secondProject.taskRunStore.registerCancellation(
            TerminationTaskProbe(waitResult: false).makeCancellation(),
            forRunID: secondRun.id
        )
        registry.closeProjectWindow(firstDirectory)
        registry.closeProjectWindow(secondDirectory)
        cleanup(firstDirectory)
        cleanup(secondDirectory)
        #expect(registry.projectManager(for: firstDirectory) == nil)
        #expect(registry.projectManager(for: secondDirectory) == nil)
        let delegate = AppDelegate()
        delegate.registry = registry
        var summaryMessage: String?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, message in
                #expect(template == .applicationQuitSummary)
                summaryMessage = message
                return .alertThirdButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(summaryMessage == Strings.applicationQuitSummaryMessage(2))
        firstProject.taskRunStore.finishRun(
            id: firstRun.id,
            outcome: makeTaskOutcome(id: "first-detached"),
            cancelled: true
        )
        secondProject.taskRunStore.finishRun(
            id: secondRun.id,
            outcome: makeTaskOutcome(id: "second-detached"),
            cancelled: true
        )
        await settle()
        #expect(registry.destroyAllProjects())
    }

    @Test func quitAnywayStopsUserTaskAndQuits() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let run = project.taskRunStore.start(makeTaskRun(id: "active"))
        let probe = TerminationTaskProbe(waitResult: true)
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .applicationQuitSummary)
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(probe.cancellationCount == 1)
        #expect(probe.waitCount == 1)
        #expect(!project.hasOutstandingUserTaskExecution)
        #expect(project.taskRunStore.runs.isEmpty)
        #expect(registry.destroyAllProjects())
    }

    @Test func lateDirtyStateRetainsPreparedUserTaskHistory() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        let run = project.taskRunStore.start(makeTaskRun(id: "active"))
        let probe = BlockingTerminationTaskProbe()
        project.taskRunStore.registerCancellation(
            probe.makeCancellation(),
            forRunID: run.id
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let quit = Task { @MainActor in
            await delegate.confirmApplicationTermination(
                presentAlert: { template, _, _, _ in
                    presentedTemplates.append(template)
                    return template == .applicationQuitSummary
                        ? .alertSecondButtonReturn
                        : .alertFirstButtonReturn
                },
                terminationDeadlineOverride: .now() + 5
            )
        }

        #expect(await probe.waitUntilStarted())
        project.primaryTabManager.updateContent("// late dirty")
        probe.release()
        let result = await quit.value

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        #expect(project.taskRunStore.runs.contains(where: { $0.id == run.id }))
        #expect(project.hasOutstandingUserTaskExecution)
        #expect(project.hasUnsavedChanges)
        project.taskRunStore.finishRun(
            id: run.id,
            outcome: makeTaskOutcome(id: "active"),
            cancelled: true
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test func taskStartedDuringQuitDoesNotCommitDiscard() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// keep after refused quit", in: project)
        let probe = TerminationTaskProbe(waitResult: true)
        var run: UserTaskRun?
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                switch template {
                case .applicationQuitSummary:
                    return .alertFirstButtonReturn
                case .unsavedChangesBulk:
                    let started = project.taskRunStore.start(
                        makeTaskRun(id: "late-active")
                    )
                    project.taskRunStore.registerCancellation(
                        probe.makeCancellation(),
                        forRunID: started.id
                    )
                    run = started
                    return .alertSecondButtonReturn
                case .activeUserTasksPreventQuit:
                    return .alertSecondButtonReturn
                default:
                    Issue.record("Unexpected Quit alert: \(template)")
                    return .abort
                }
            },
            terminationDeadlineOverride: .now() + 2
        )

        #expect(!result)
        #expect(probe.cancellationCount == 0)
        #expect(probe.waitCount == 0)
        #expect(project.hasUnsavedChanges)
        #expect(project.primaryTabManager.activeTab?.content ==
                "// keep after refused quit")
        let activeRun = try #require(run)
        project.taskRunStore.finishRun(
            id: activeRun.id,
            outcome: makeTaskOutcome(id: "late-active"),
            cancelled: false
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test func taskStartedAfterQuitAnywayIsNotCancelled() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.primaryTabManager.openTab(url: file)
        updateContent("// keep late task", in: project)
        let probe = TerminationTaskProbe(waitResult: true)
        var lateRun: UserTaskRun?
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                if template == .applicationQuitSummary {
                    let run = project.taskRunStore.start(
                        makeTaskRun(id: "late-after-summary")
                    )
                    project.taskRunStore.registerCancellation(
                        probe.makeCancellation(),
                        forRunID: run.id
                    )
                    lateRun = run
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        #expect(probe.cancellationCount == 0)
        #expect(probe.waitCount == 0)
        #expect(project.hasUnsavedChanges)
        let run = try #require(lateRun)
        project.taskRunStore.finishRun(
            id: run.id,
            outcome: makeTaskOutcome(id: "late-after-summary"),
            cancelled: false
        )
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

        let registry = makeRegistry()
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

        let registry = makeRegistry()
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

        let registry = makeRegistry()
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

    @Test func existingQuitOwnerIsRaisedBeforeNativePresentation() {
        let delegate = AppDelegate()
        let owner = TrackingApplicationOwnerWindow()
        owner.orderFront(nil)
        owner.resetTracking()
        defer { owner.orderOut(nil) }

        delegate.prepareApplicationDialogOwner(windows: [owner])

        #expect(owner.makeKeyAndOrderFrontCount == 1)
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

nonisolated private final class TerminationStagingLeafProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLeaf: String?

    var leaf: String? { lock.withLock { recordedLeaf } }

    func record(_ staged: TerminationStagedSave) {
        lock.withLock {
            recordedLeaf = staged.stagingURL.lastPathComponent
        }
    }
}

private actor WindowLifecycleAgentTaskStore:
    AgentTaskPersisting {
    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        .saved(taskCount: tasks.count)
    }
}

nonisolated private final class TerminationDeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var recordedElapsedNanoseconds: UInt64?

    var elapsedNanoseconds: UInt64? {
        lock.withLock { recordedElapsedNanoseconds }
    }

    func record() {
        lock.withLock {
            guard recordedElapsedNanoseconds == nil else { return }
            recordedElapsedNanoseconds =
                DispatchTime.now().uptimeNanoseconds - started
        }
    }
}

nonisolated private final class TerminationAliasMutationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private let mutation: @Sendable () -> String?
    private var captures = 0
    private var recordedMutationError: String?

    init(mutation: @escaping @Sendable () -> String?) {
        self.mutation = mutation
    }

    var captureCount: Int { lock.withLock { captures } }
    var mutationError: String? { lock.withLock { recordedMutationError } }

    func capture(
        _ urls: [URL],
        until deadline: DispatchTime
    ) async -> TerminationFileAliasCaptureResult {
        let result = await TerminationFileAliasResolver.capture(
            urls,
            until: deadline
        )
        let shouldMutate = lock.withLock {
            captures += 1
            return captures == 1
        }
        if shouldMutate {
            let error = mutation()
            lock.withLock { recordedMutationError = error }
        }
        return result
    }
}

nonisolated private final class BlockingFormatterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false

    var didStart: Bool {
        lock.withLock { started }
    }

    func formatter() -> ExternalFileFormatter {
        ExternalFileFormatter(
            toolPath: "/usr/bin/false",
            toolName: "blocking-test-formatter",
            extensions: ["swift"],
            arguments: [],
            processRunner: { [self] _, _, input, _ in
                lock.withLock { started = true }
                releaseSemaphore.wait()
                return ProcessRunResult(
                    stdout: input,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            timeout: 30
        )
    }

    func release() {
        releaseSemaphore.signal()
    }

    func waitUntilStarted(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while !didStart, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return didStart
    }
}

nonisolated private final class DelayedTerminationInstallerProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var installs = 0

    var installCount: Int { lock.withLock { installs } }

    func install(
        _: TerminationStagedSave,
        until _: DispatchTime,
        lateCompletion _: @escaping @Sendable (
            TerminationSaveInstallResult
        ) -> Void
    ) async -> TerminationSaveInstallResult {
        lock.withLock { installs += 1 }
        try? await Task.sleep(for: .milliseconds(100))
        return .failed(
            message: "The outer deadline did not win",
            retainedArtifacts: []
        )
    }
}

nonisolated private final class BlockingTerminationCleanerProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let cleanup: @Sendable (
        [TerminationStagedSave]
    ) -> TerminationSaveCleanupResult
    private var started = false
    private var returned = false
    private var recordedStagingURLs: [URL] = []

    var stagingURLs: [URL] { lock.withLock { recordedStagingURLs } }

    init(
        cleanup: @escaping @Sendable (
            [TerminationStagedSave]
        ) -> TerminationSaveCleanupResult
    ) {
        self.cleanup = cleanup
    }

    func clean(
        _ staged: [TerminationStagedSave]
    ) -> TerminationSaveCleanupResult {
        lock.withLock {
            recordedStagingURLs = staged.map(\.stagingURL)
            started = true
        }
        releaseSemaphore.wait()
        let result = cleanup(staged)
        lock.withLock { returned = true }
        return result
    }

    func release() {
        releaseSemaphore.signal()
    }

    func waitUntilStarted(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        await wait(
            until: { self.lock.withLock { self.started } },
            maximumDuration: maximumDuration
        )
    }

    func waitUntilReturned(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        await wait(
            until: { self.lock.withLock { self.returned } },
            maximumDuration: maximumDuration
        )
    }

    private func wait(
        until condition: () -> Bool,
        maximumDuration: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while !condition(), clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return condition()
    }
}

nonisolated private final class TerminationLateFailureReportProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessage: String?
    private var recordedArtifacts: [URL] = []

    var message: String? { lock.withLock { recordedMessage } }
    var artifacts: [URL] { lock.withLock { recordedArtifacts } }

    func record(message: String, artifacts: [URL]) {
        lock.withLock {
            recordedMessage = message
            recordedArtifacts = artifacts
        }
    }

    func waitUntilRecorded(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while message == nil, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return message != nil
    }
}

nonisolated private final class FirstTerminationInstallGate:
    @unchecked Sendable {
    private let lock = NSLock()
    private var installs = 0
    private var firstInstallStarted = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var installCount: Int { lock.withLock { installs } }

    func install(
        _ staged: TerminationStagedSave,
        until deadline: DispatchTime,
        lateCompletion: @escaping @Sendable (
            TerminationSaveInstallResult
        ) -> Void
    ) async -> TerminationSaveInstallResult {
        let shouldWait = lock.withLock {
            installs += 1
            guard installs == 1 else { return false }
            firstInstallStarted = true
            return true
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if released { return true }
                    releaseContinuation = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        return await TerminationSaveCoordinator.install(
            staged,
            until: deadline,
            lateCompletion: lateCompletion
        )
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }

    func waitUntilStarted(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while !lock.withLock({ firstInstallStarted }), clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return lock.withLock { firstInstallStarted }
    }
}

nonisolated private final class PausedInstalledTerminationInstallerProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var installed = false
    private var returned = false

    var didInstall: Bool { lock.withLock { installed } }
    var didReturn: Bool { lock.withLock { returned } }

    func install(
        _ staged: TerminationStagedSave,
        until deadline: DispatchTime,
        lateCompletion: @escaping @Sendable (
            TerminationSaveInstallResult
        ) -> Void
    ) async -> TerminationSaveInstallResult {
        let result = await TerminationSaveCoordinator.install(
            staged,
            until: deadline,
            lateCompletion: lateCompletion
        )
        guard case .installed = result else { return result }
        lock.withLock { installed = true }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
        lock.withLock { returned = true }
        return result
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }

    func waitUntilInstalled(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        await wait(until: { self.didInstall }, maximumDuration: maximumDuration)
    }

    func waitUntilReturned(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        await wait(until: { self.didReturn }, maximumDuration: maximumDuration)
    }

    private func wait(
        until condition: () -> Bool,
        maximumDuration: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while !condition(), clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return condition()
    }
}

@MainActor
private final class TrackingApplicationOwnerWindow: NSWindow {
    private(set) var makeKeyAndOrderFrontCount = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCount += 1
        super.makeKeyAndOrderFront(sender)
    }

    func resetTracking() {
        makeKeyAndOrderFrontCount = 0
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

nonisolated private final class BlockingTerminationTaskProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false

    var didStart: Bool { lock.withLock { started } }

    func makeCancellation() -> UserTaskCancellation {
        UserTaskCancellation(
            terminate: { true },
            waitForCompletion: { [self] _ in
                lock.withLock { started = true }
                releaseSemaphore.wait()
                return true
            }
        )
    }

    func release() {
        releaseSemaphore.signal()
    }

    func waitUntilStarted(
        maximumDuration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while !didStart, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return didStart
    }
}
