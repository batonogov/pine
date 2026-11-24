import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Project window presentation intent", .serialized)
@MainActor
struct ProjectWindowPresentationIntentTests {
    @Test("Late worktree admission cannot override newer navigation", arguments: [false, true])
    func latestNavigationWins(selectSameProject: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        let registry = fixture.registry(gate: gate)
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        let first = try #require(registry.projectManager(for: fixture.repository))
        let pending = Task { await session.activate(fixture.worktree.worktreeRoot, registry: registry) }
        try #require(await waitUntilMainActor { gate.entered })
        let target = selectSameProject ? fixture.repository : fixture.other
        await session.openProject(target, registry: registry)
        let selected = try #require(registry.projectManagerIfAdmitted(for: target))
        gate.release()
        await pending.value

        #expect(session.activeProjectURL == target)
        #expect(registry.isWindowOpen(target))
        #expect(selected.presentationLifecycle == .visible)
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        #expect(first.presentationLifecycle == (selectSameProject ? .visible : .backgroundSuspended))
        let restored = fixture.session()
        #expect(await restored.restoreIfNeeded(registry: registry) == .restored)
        #expect(restored.activeProjectURL == target)
        session.windowDidClose(registry: registry)
        restored.windowDidClose(registry: registry)
        registry.closeProjectWindow(target)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Admission completing after close cannot own the replacement window", arguments: [false, true])
    func closeInvalidatesAdmission(reopen: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        let registry = fixture.registry(gate: gate)
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        _ = try #require(registry.projectManager(for: fixture.repository))
        let pending = Task { await session.activate(fixture.worktree.worktreeRoot, registry: registry) }
        try #require(await waitUntilMainActor { gate.entered })
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.repository)
        let replacement = fixture.session()
        if reopen {
            await replacement.openProject(fixture.other, registry: registry)
        }
        gate.release()
        await pending.value

        #expect(session.activeProjectURL == fixture.repository)
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        if reopen {
            #expect(replacement.activeProjectURL == fixture.other)
            #expect(registry.isWindowOpen(fixture.other))
        }
        replacement.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.other)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.worktreeRoot.path))
    }

    @Test("Authorized launches survive stale presentation without leaking ownership",
          arguments: ["active", "newer", "closed", "replacement", "reused"])
    func launchKeepsExecutionOwnership(navigation: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        let registry = fixture.registry(gate: gate)
        _ = try #require(registry.projectManager(for: fixture.repository))
        let executable = fixture.root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var launchedManager: ProjectManager?
        let managedRoot = fixture.root.appendingPathComponent("launches", isDirectory: true)
        let session = ProjectWindowSession(
            initialProjectURL: fixture.repository,
            defaults: fixture.defaults,
            toolResolver: ExternalToolResolver(searchDirectories: [fixture.root.path]),
            managedRootResolver: { _ in managedRoot },
            agentLauncher: { manager, option, directory in
                launchedManager = manager
                registry.runBackgroundReclamationPassForTesting()
                #expect(registry.projectManagerIfAdmitted(for: directory) === manager)
                manager.terminal.createTerminalTab(
                    relativeTo: manager.paneManager.activePaneID, workingDirectory: directory
                )
                guard let tab = manager.paneManager.allTerminalTabs.last else { return .rejected }
                return await manager.terminal.launchAgentCommandForTesting(
                    option.command, descriptor: option.descriptor, in: tab, acknowledgedWrite: { true }
                )
            }
        )
        let pending = Task {
            await session.launchAgent(
                ProjectAgentLaunchOption(id: "codex", displayName: "Codex", command: "codex"),
                registry: registry
            )
        }
        try #require(await waitUntilMainActor { gate.entered })
        var replacement: ProjectWindowSession?
        if navigation == "newer" {
            await session.openProject(fixture.other, registry: registry)
        } else if navigation != "active" {
            session.windowDidClose(registry: registry)
            registry.closeProjectWindow(fixture.repository)
            if navigation == "replacement" {
                replacement = fixture.session()
                await replacement?.openProject(fixture.other, registry: registry)
            } else if navigation == "reused" {
                session.windowDidOpen()
                await session.openProject(fixture.other, registry: registry)
            }
        }
        gate.release()
        await pending.value
        let manager = try #require(launchedManager)
        let root = try #require(manager.rootURL)
        #expect(manager.requiresBackgroundRetention)
        #expect(manager.terminal.hasAcknowledgedAgentLaunchForTesting)
        #expect(session.alertMessage == nil)
        if navigation == "active" {
            #expect(session.activeProjectURL == root)
            #expect(registry.isWindowOpen(root))
        } else {
            #expect(!registry.isWindowOpen(root))
            #expect(manager.presentationLifecycle == .backgroundSuspended)
            #expect(session.activeProjectURL == (
                navigation == "newer" || navigation == "reused" ? fixture.other : fixture.repository
            ))
            if navigation != "closed" {
                #expect(registry.isWindowOpen(fixture.other))
                let restored = fixture.session()
                #expect(await restored.restoreIfNeeded(registry: registry) == .restored)
                #expect(restored.activeProjectURL == fixture.other)
                restored.windowDidClose(registry: registry)
            }
        }
        session.windowDidClose(registry: registry)
        replacement?.windowDidClose(registry: registry)
        registry.closeProjectWindow(root)
        registry.closeProjectWindow(fixture.other)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.projectManagerIfAdmitted(for: root) === manager)
        manager.terminal.terminateAll()
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Notification navigation obeys the same latest-intent fence")
    func notificationNavigationWins() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        let registry = fixture.registry(gate: gate)
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        let manager = try #require(registry.projectManager(for: fixture.repository))
        var mounted = false
        let hosted = NSHostingView(rootView: Color.clear
            .modifier(ProjectWindowCommandObserver(projectManager: manager, session: session, registry: registry))
            .onAppear { mounted = true })
        hosted.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hosted.layoutSubtreeIfNeeded()
        try #require(await waitUntilMainActor { mounted })
        NotificationCenter.default.post(
            name: .switchProjectInWindow, object: manager, userInfo: ["url": fixture.worktree.worktreeRoot]
        )
        try #require(await waitUntilMainActor { gate.entered })
        NotificationCenter.default.post(
            name: .switchProjectInWindow, object: manager, userInfo: ["url": fixture.other]
        )
        try #require(await waitUntilMainActor { session.activeProjectURL == fixture.other })
        gate.release()
        try #require(await waitUntilMainActor {
            registry.projectManagerIfAdmitted(for: fixture.worktree.worktreeRoot) != nil
        })
        #expect(session.activeProjectURL == fixture.other)
        #expect(registry.isWindowOpen(fixture.other))
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        withExtendedLifetime(hosted) {}
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.other)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Closing before the terminal mounts still starts the authorized local process")
    func backgroundLaunchStartsWithoutMount() async throws {
        let panes = PaneManager()
        let terminal = TerminalManager(agentDetectionProcessRunner: { _, _, _, _ in
            ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
        })
        terminal.paneManager = panes
        defer { terminal.terminateAll() }
        var configured = false
        let directory = FileManager.default.temporaryDirectory
        let result = await terminal.launchAgentInNewTerminal(
            "codex",
            descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            workingDirectory: directory,
            maximumAttempts: 400,
            waitForNextAttempt: {
                if !configured, let tab = terminal.allTerminalTabs.first {
                    // No provider or user shell executes: the PTY only ever runs this inert local child.
                    tab.configure(workingDirectory: directory, initialProcess: TerminalInitialProcess(
                        executablePath: "/bin/sleep", arguments: ["60"]
                    ))
                    configured = true
                    terminal.setAgentTaskWindowOpen(false)
                }
                await Task.yield()
            }
        )
        #expect(configured)
        #expect(result == .sentWithoutReservation)
        #expect(terminal.allTerminalTabs.first?.isProcessRunning == true)
        withExtendedLifetime(panes) {}
    }

    @Test("Background shell admission still fails fast after bounded re-arms")
    func backgroundRefusalRemainsBounded() async {
        let panes = PaneManager()
        let terminal = TerminalManager(agentDetectionProcessRunner: { _, _, _, _ in
            ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
        })
        terminal.paneManager = panes
        defer { terminal.terminateAll() }
        var waits = 0
        let result = await terminal.launchAgentInNewTerminal(
            "codex",
            descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            workingDirectory: FileManager.default.temporaryDirectory,
            maximumAttempts: 25,
            waitForNextAttempt: {
                waits += 1
                if waits == 1, let tab = terminal.allTerminalTabs.first {
                    tab.configureWorkingDirectoryValidation { _ in false }
                    terminal.setAgentTaskWindowOpen(false)
                }
                #expect(await waitUntilMainActor {
                    terminal.allTerminalTabs.first?.isStartValidationPendingForTesting == false
                })
            }
        )
        #expect(result == .rejected)
        #expect(waits == 4)
        #expect(terminal.allTerminalTabs.first?.isProcessRunning == false)
        withExtendedLifetime(panes) {}
    }

    private final class Gate {
        var isArmed = true
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard isArmed, !entered else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            isArmed = false
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let other: URL
        let worktree: AgentManagedWorktree
        let suite: String
        let defaults: UserDefaults

        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("PresentationIntent-\(UUID())", isDirectory: true)
            let repository = root.appendingPathComponent("repository", isDirectory: true)
            let other = root.appendingPathComponent("other", isDirectory: true)
            let managed = root.appendingPathComponent("managed", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            for arguments in [
                ["init", "-b", "main"],
                ["-c", "user.name=Pine Tests", "-c", "user.email=tests@pine.invalid",
                 "commit", "--allow-empty", "-m", "base"]
            ] {
                let result = await GitCommand.runAsync(arguments, at: repository)
                try #require(result.completedSuccessfully)
            }
            let result = await AgentWorktreeService().create(AgentWorktreeCreateRequest(
                taskID: UUID(), repositoryRoot: repository,
                managedRoot: managed,
                branchName: "agent/intent", startPoint: "HEAD"
            ))
            guard case .created(let worktree) = result else {
                throw NSError(domain: "PresentationIntentFixture", code: 1)
            }
            let suite = "PresentationIntent.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            return Fixture(root: root, repository: repository, other: other,
                           worktree: worktree, suite: suite, defaults: defaults)
        }

        func registry(
            gate: Gate,
            canonicalizer: @escaping @Sendable (URL) async -> URL = { url in
                await runOnBackground { ProjectRegistry.canonicalProjectURL(url) }
            }
        ) -> ProjectRegistry {
            ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(persistence: AgentTaskMetadataStore(
                    storageRoot: root.appendingPathComponent("tasks")
                ), accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in .verifiedLifecycleTransitions }),
                agentInboxProjectCanonicalizer: canonicalizer,
                agentTaskFilesystemValidationCommitSeam: { await gate.wait() },
                agentDetectionProcessRunner: { _, _, _, _ in
                    ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
                },
                agentDetectionPollInterval: 3_600,
                agentDetectionInitialPollDelay: 3_600,
                backgroundReclamationInterval: .seconds(3_600)
            )
        }

        func session() -> ProjectWindowSession {
            ProjectWindowSession(initialProjectURL: repository, defaults: defaults)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

extension ProjectWindowPresentationIntentTests {
    @Test("A genuinely missing restoration target remains unavailable")
    func missingRestoreRemainsUnavailable() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        gate.isArmed = false
        let registry = fixture.registry(gate: gate)
        let session = ProjectWindowSession(
            initialProjectURL: fixture.root.appendingPathComponent("absent", isDirectory: true),
            defaults: fixture.defaults
        )
        #expect(await session.restoreIfNeeded(registry: registry) == .unavailable)
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Superseded or cancelled restoration cannot dismiss the current scene",
          arguments: ["newer", "cancelled"])
    func suspendedRestoreDoesNotDismiss(navigation: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        gate.isArmed = false
        let registry = fixture.registry(gate: gate)
        let previous = fixture.session()
        previous.adoptWorktreeForTesting(fixture.worktree)
        _ = try #require(registry.projectManager(for: fixture.repository))
        await previous.activate(fixture.worktree.worktreeRoot, registry: registry)
        previous.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.worktree.worktreeRoot)

        let session = fixture.session()
        registry.registerWindowSession(session)
        _ = try #require(registry.projectManager(for: fixture.repository))
        gate.isArmed = true
        let pending = Task { await session.restoreIfNeeded(registry: registry) }
        try #require(await waitUntilMainActor { gate.entered })
        let target = navigation == "cancelled" ? fixture.repository : fixture.other
        if navigation == "cancelled" {
            pending.cancel()
        } else {
            await session.openProject(target, registry: registry)
        }
        let selected = try #require(registry.projectManagerIfAdmitted(for: target))
        gate.release()
        let result = await pending.value
        // PineApp dismisses the scene only for a genuinely unavailable restore.
        #expect(result != .unavailable)
        #expect(result != .restored)
        #expect(result != .alreadyRestored)
        #expect(session.activeProjectURL == target)
        #expect(registry.windowSession(owning: target) === session)
        #expect(registry.isWindowOpen(target))
        #expect(selected.presentationLifecycle == .visible)
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(target)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects.isEmpty
        })
    }

    @Test("Open Recent captures destination intent before suspended admission",
          arguments: ["same", "newer", "closed", "replacement", "reused", "newWindow", "active", "cold"])
    func suspendedOpenRecentKeepsIntent(navigation: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        gate.isArmed = false
        let registry = fixture.registry(gate: gate)
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        if navigation != "newWindow", navigation != "cold" { registry.registerWindowSession(session) }
        _ = try #require(registry.projectManager(for: fixture.repository))
        _ = try #require(await registry.projectManager(for: fixture.worktree))
        registry.closeProjectWindow(fixture.worktree.worktreeRoot)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.projectManagerIfAdmitted(for: fixture.worktree.worktreeRoot) == nil)
        let delegate = AppDelegate()
        delegate.registry = registry
        var opened: [URL] = []
        delegate.openProjectWindow = { opened.append($0) }
        gate.isArmed = true
        let pending = Task { await delegate.openRecentProject(fixture.worktree.worktreeRoot) }
        try #require(await waitUntilMainActor { gate.entered })
        var replacement: ProjectWindowSession?
        switch navigation {
        case "same":
            await session.activate(fixture.repository, registry: registry)
        case "newer":
            await session.openProject(fixture.other, registry: registry)
        case "closed", "replacement", "reused", "newWindow":
            session.windowDidClose(registry: registry)
            registry.closeProjectWindow(fixture.repository)
            if navigation == "reused" {
                registry.registerWindowSession(session)
                await session.openProject(fixture.other, registry: registry)
            } else if navigation != "closed" {
                replacement = fixture.session()
                registry.registerWindowSession(try #require(replacement))
                await replacement?.openProject(fixture.other, registry: registry)
            }
        default:
            break
        }
        let selected = registry.projectManagerIfAdmitted(for: fixture.other)
        gate.release()
        let result = await pending.value
        if navigation == "active" {
            #expect(result)
            #expect(opened == [session.sceneProjectURL])
            #expect(session.activeProjectURL == fixture.worktree.worktreeRoot)
            #expect(registry.isWindowOpen(fixture.worktree.worktreeRoot))
        } else if navigation == "cold" {
            #expect(result)
            #expect(opened == [fixture.worktree.worktreeRoot])
            #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        } else {
            #expect(!result)
            #expect(opened.isEmpty)
            #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
            #expect(registry.projectManagerIfAdmitted(for: fixture.worktree.worktreeRoot)?
                .presentationLifecycle != .visible)
            if let selected {
                #expect(registry.projectManagerIfAdmitted(for: fixture.other) === selected)
                #expect(registry.isWindowOpen(fixture.other))
                #expect(selected.presentationLifecycle == .visible)
            }
        }
        session.windowDidClose(registry: registry)
        replacement?.windowDidClose(registry: registry)
        for url in [fixture.repository, fixture.other, fixture.worktree.worktreeRoot] {
            registry.closeProjectWindow(url)
        }
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects.isEmpty
        })
    }

    @Test("Open Recent cannot reopen a sessionless owner closed during admission")
    func suspendedOpenRecentRejectsClosedNativeOwner() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        defer { gate.release() }
        gate.isArmed = false
        let registry = fixture.registry(gate: gate)
        let manager = try #require(await registry.projectManager(for: fixture.worktree))
        let delegate = AppDelegate()
        delegate.registry = registry
        var opened: [URL] = []
        delegate.openProjectWindow = { opened.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let closeDelegate = CloseDelegate(
            projectManager: manager, registry: registry,
            projectURL: fixture.worktree.worktreeRoot, appDelegate: delegate, original: nil
        )
        window.delegate = closeDelegate
        closeDelegate.observeWindowClose(window)
        window.makeKeyAndOrderFront(nil)
        defer {
            manager.unbindDialogOwnerWindow(window)
            window.orderOut(nil)
        }
        try #require(window.isVisible)
        try #require(manager.dialogOwnerWindow === window)
        gate.isArmed = true
        let pending = Task { await delegate.openRecentProject(fixture.worktree.worktreeRoot) }
        try #require(await waitUntilMainActor { gate.entered })
        window.close()
        try #require(closeDelegate.didCompleteWindowLifecycle)
        gate.release()
        #expect(!(await pending.value))
        #expect(opened.isEmpty)
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        #expect(manager.presentationLifecycle == .backgroundSuspended)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects.isEmpty
        })
    }

    @Test("Closing an inactive repository invalidates admission of its worktree")
    func closingProjectInvalidatesAdmission() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let gate = Gate()
        let registry = fixture.registry(gate: gate)
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        _ = try #require(registry.projectManager(for: fixture.repository))
        await session.openProject(fixture.other, registry: registry)
        let pending = Task { await session.activate(fixture.worktree.worktreeRoot, registry: registry) }
        defer { gate.release() }
        try #require(await waitUntilMainActor { gate.entered })
        #expect(await session.closeProject(fixture.repository, registry: registry))
        gate.release()
        #expect(!(await pending.value))
        #expect(session.activeProjectURL == fixture.other)
        #expect(!session.contains(fixture.worktree.worktreeRoot))
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.other)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Task and notification routing cannot outlive their destination intent",
          arguments: ["canonicalization", "admission"], ["same", "newer", "closed", "replacement", "newWindow"])
    func taskNavigationKeepsLatestIntent(boundary: String, navigation: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let admission = Gate()
        admission.isArmed = false
        let canonicalization = Gate()
        canonicalization.isArmed = boundary == "canonicalization"
        let registry = fixture.registry(gate: admission, canonicalizer: { url in
            await canonicalization.wait()
            return url
        })
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        if navigation != "newWindow" { registry.noteKeyWindowSession(session) }
        _ = try #require(registry.projectManager(for: fixture.repository))
        let worktreeManager = try #require(await registry.projectManager(for: fixture.worktree))
        let task = try stageTask(in: worktreeManager, registry: registry)
        registry.closeProjectWindow(fixture.worktree.worktreeRoot)
        admission.isArmed = boundary == "admission"
        var opened: [URL] = []
        var focused = false
        let pending = Task {
            await registry.navigateToAgentTaskFromInbox(
                task.taskID,
                openProjectWindow: { opened.append($0) },
                waitUntilPresented: { _ in false },
                activateApplication: { _ in focused = true },
                expectedNotificationRoute: task
            )
        }
        let gate = boundary == "admission" ? admission : canonicalization
        defer { gate.release() }
        try #require(await waitUntilMainActor { gate.entered })
        var replacement: ProjectWindowSession?
        if navigation == "closed" || navigation == "replacement" || navigation == "newWindow" {
            session.windowDidClose(registry: registry)
            registry.closeProjectWindow(fixture.repository)
            if navigation != "closed" {
                replacement = fixture.session()
                registry.noteKeyWindowSession(try #require(replacement))
                await replacement?.openProject(fixture.other, registry: registry)
            }
        } else {
            await session.openProject(
                navigation == "same" ? fixture.repository : fixture.other, registry: registry
            )
        }
        gate.release()
        #expect(await pending.value == .projectUnavailable)
        #expect(opened.isEmpty)
        #expect(!focused)
        #expect(session.activeProjectURL == (navigation == "newer" ? fixture.other : fixture.repository))
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        #expect(registry.agentTasks.task(for: task.taskID)?.lifecycle == .active)
        if navigation == "replacement" || navigation == "newer" || navigation == "newWindow" {
            #expect(registry.isWindowOpen(fixture.other))
        } else if navigation == "same" {
            #expect(registry.isWindowOpen(fixture.repository))
        }
        session.windowDidClose(registry: registry)
        replacement?.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.other)
        registry.closeProjectWindow(fixture.repository)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects.count == 1)
        #expect(registry.projectManagerIfAdmitted(for: fixture.worktree.worktreeRoot) === worktreeManager)
        worktreeManager.terminal.terminateAll()
    }

    @Test("Legacy recovery also captures intent before canonicalization")
    func recoveryKeepsLatestIntent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let admission = Gate()
        admission.isArmed = false
        let gate = Gate()
        let registry = fixture.registry(gate: admission, canonicalizer: { url in
            await gate.wait()
            return url
        })
        let session = fixture.session()
        session.adoptWorktreeForTesting(fixture.worktree)
        registry.noteKeyWindowSession(session)
        _ = try #require(registry.projectManager(for: fixture.repository))
        let manager = try #require(await registry.projectManager(for: fixture.worktree))
        let task = try stageTask(in: manager, registry: registry)
        registry.closeProjectWindow(fixture.worktree.worktreeRoot)
        var opened: [URL] = []
        let pending = Task {
            await registry.recoverAgentTaskFromInbox(
                task.taskID, action: .startNewSession,
                openProjectWindow: { opened.append($0) }, waitUntilPresented: { _ in false }
            )
        }
        defer { gate.release() }
        try #require(await waitUntilMainActor { gate.entered })
        await session.activate(fixture.repository, registry: registry)
        gate.release()
        #expect(await pending.value == .projectUnavailable)
        #expect(opened.isEmpty)
        #expect(session.activeProjectURL == fixture.repository)
        #expect(!registry.isWindowOpen(fixture.worktree.worktreeRoot))
        #expect(registry.agentTasks.task(for: task.taskID)?.lifecycle == .active)
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.repository)
        manager.terminal.terminateAll()
    }

    private func stageTask(
        in manager: ProjectManager, registry: ProjectRegistry
    ) throws -> AgentNotificationRouteIdentity {
        let pane = manager.paneManager.createTerminalPaneAtBottom(workingDirectory: manager.rootURL)
        let tab = try #require(manager.paneManager.terminalState(for: pane)?.terminalTabs.first)
        let session = AgentSession(
            agentType: .codex, state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions, startedAt: Date()
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 1_788, processGeneration: 1,
            startIdentifier: "presentation-intent", observedStartedAt: session.startedAt,
            startIsAuthoritative: true
        ))
        manager.terminal.bridgeAgentSession(session, replacing: nil, in: tab)
        tab.agentSession = session
        let taskID = try #require(registry.agentTasks.taskID(forSessionID: session.id))
        try #require(registry.agentTasks.task(for: taskID)?.lifecycle == .active)
        return AgentNotificationRouteIdentity(taskID: taskID, runID: session.id, processGeneration: 1)
    }
}
