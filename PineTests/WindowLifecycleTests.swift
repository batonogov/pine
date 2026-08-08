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
        oldWindow.orderFront(nil)
        let oldContext = DialogPresenter.register(
            window: oldWindow,
            projectManager: project
        )
        defer {
            DialogPresenter.ownerDidClose(oldWindow)
            DialogPresenter.ownerDidClose(newWindow)
            oldWindow.orderOut(nil)
            newWindow.orderOut(nil)
        }
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []
        var errorOwner: NSWindow?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, context, _, _ in
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
                    errorOwner = context.nsWindow
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
            ]
        )
        #expect(errorOwner === newWindow)
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
                .applicationQuitFailure,
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
                .applicationQuitFailure,
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
        project.terminationSaveInstaller = { staged in
            await installer.install(staged)
        }

        let result = await project.commitStagedSaveAllPaneTabsForTermination(
            stagedPlan,
            until: .now() + .milliseconds(50)
        )

        #expect(result == .timedOut)
        #expect(installer.installCount == 1)
        #expect(
            try String(contentsOf: firstURL, encoding: .utf8)
                == "// first dirty\n"
        )
        #expect(
            try String(contentsOf: secondURL, encoding: .utf8)
                == "// second.swift"
        )
        let firstAttributes = try FileManager.default.attributesOfItem(
            atPath: firstURL.path
        )
        #expect(firstAttributes[.posixPermissions] as? Int == 0o750)
        #expect(tabs.tabs.first(where: { $0.fileURL == firstURL })?.isDirty == false)
        #expect(tabs.tabs.first(where: { $0.fileURL == secondURL })?.isDirty == true)
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
        _ staged: TerminationStagedSave
    ) async -> TerminationSaveInstallResult {
        lock.withLock { installs += 1 }
        try? await Task.sleep(for: .milliseconds(100))
        return await TerminationSaveCoordinator.install(staged)
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
