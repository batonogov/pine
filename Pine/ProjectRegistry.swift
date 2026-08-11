//
//  ProjectRegistry.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import os
import SwiftUI

nonisolated enum AgentInboxNavigationResult: Equatable, Sendable {
    case focused(AgentTaskRoute)
    case taskMissing
    case projectUnavailable
    case routeStale
}

nonisolated enum AgentInboxRecoveryResult: Equatable, Sendable {
    case openedNewSession(terminalID: UUID)
    case resumed(terminalID: UUID)
    case taskMissing
    case projectUnavailable
    case unavailable(AgentTaskRecoveryUnavailableReason)
    case changedWhilePreparing
    case launchRejected
}

#if DEBUG
/// Keeps the live-agent XCUITest on the production registry mutation path
/// without reading or writing the developer's durable task metadata.
private actor LiveAgentUITestTaskPersistence: AgentTaskPersisting {
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        if let authorization {
            switch authorization.publishForTesting(operation: { true }) {
            case .published:
                break
            case .failed:
                return .rejected(.ioFailure)
            case .superseded:
                return .rejected(.superseded)
            }
        }
        return .saved(taskCount: tasks.count)
    }

    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }
}
#endif

/// App-wide snapshot of the exact user-task executions covered by one Quit
/// decision, keyed by their owning ProjectManager identity.
@MainActor
struct UserTaskShutdownAuthorization {
    fileprivate let byOwner: [
        ObjectIdentifier: UserTaskExecutionAuthorization
    ]

    var requiresConfirmation: Bool {
        byOwner.values.contains { $0.requiresConfirmation }
    }

    var confirmingOwnerIDs: Set<ObjectIdentifier> {
        Set(byOwner.compactMap { owner, authorization in
            authorization.requiresConfirmation ? owner : nil
        })
    }
}

/// Stable application-wide ownership fence for Quit's machine save phase.
/// Planned Save As tabs may move from their original backing to the one
/// destination chosen by the user; every other project, pane manager, tab,
/// and backing URL must remain identical until the transaction completes.
@MainActor
struct TerminationSaveInventoryAuthorization {
    fileprivate let projectsByRoot: [URL: ObjectIdentifier]
    fileprivate let tabsByProject: [
        ObjectIdentifier: ProjectManager.TerminationOpenTabInventory
    ]
}

/// Manages open projects and recent project history.
/// Each project directory maps to a single ProjectManager instance.
@MainActor
@Observable
final class ProjectRegistry: LSPSettingsObserver {
    /// Open projects keyed by their root directory URL.
    private(set) var openProjects: [URL: ProjectManager] = [:]
    /// Projects whose window was closed but whose ProjectManager (and terminal processes)
    /// are kept alive. Reopening the same project returns the existing PM.
    private(set) var backgroundProjects: Set<URL> = []
    /// Project managers detached after their directory disappeared. They stay
    /// retained until user-task process cleanup completes, so a later Quit
    /// can still wait for and reap those executions.
    @ObservationIgnored
    private var detachedTaskCleanupProjects: [
        ObjectIdentifier: ProjectManager
    ] = [:]
    /// Recently opened project paths (most recent first), persisted to UserDefaults.
    var recentProjects: [URL] = []

    /// Application-wide LSP preferences shared by every project manager.
    let lspSettings: LSPSettings
    /// Application-lifetime durable agent identity across every project.
    let agentTasks: AgentTaskRegistry

    private static let recentProjectsKey = "recentProjectPaths"
    private static let maxRecentProjects = 10
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let agentRecoveryInspector: AgentTaskRecoveryInspector
    @ObservationIgnored
    private var agentTaskProjectsByRoot: [URL: AgentTaskProjectIdentity] = [:] {
        didSet {
            // Opening or closing a project window changes which identities the
            // attention badge projects onto (#1337). Funnelled through `didSet`
            // so every mutation site stays in sync without remembering to call
            // the recompute by hand.
            guard oldValue != agentTaskProjectsByRoot else { return }
            recomputeAgentInboxAttentionCounts()
        }
    }

    /// Per-project count of durable agent tasks in the Inbox's
    /// `needsAttention` section, keyed by canonical project URL (#1337).
    ///
    /// Deliberately a cache rather than a computed property: it is read from
    /// `ContentView.body`, and computing it on demand would make every project
    /// window's root view observe the whole durable task array — any task
    /// mutation anywhere would then rebuild an `AgentInboxSnapshot` per window
    /// per body pass. Recomputing on task change instead means windows are
    /// invalidated only when a count they display actually moves.
    private var agentInboxAttentionCounts: [URL: Int] = [:]

    /// Serializes settings lifecycle changes so rapid Apply/Reset operations
    /// cannot race each other across projects.
    @ObservationIgnored
    private var lspSettingsChangeTask: Task<Void, Never>?
    /// Prevents a ProjectManager from being created without a matching agent
    /// metadata registration while that registry has frozen admission.
    @ObservationIgnored
    private(set) var isProjectAdmissionFrozenForTermination = false
    @ObservationIgnored
    private var isAutoSaveFrozenForTermination = false

    init(
        lspSettings: LSPSettings = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        agentTasks: AgentTaskRegistry? = nil,
        agentRecoveryInspector: AgentTaskRecoveryInspector = AgentTaskRecoveryInspector(),
        clearRecentProjects: Bool = CommandLine.arguments.contains(
            "--clear-recent-projects"
        )
    ) {
        self.lspSettings = lspSettings
        self.agentTasks = agentTasks ?? Self.makeDefaultAgentTaskRegistry()
        self.defaults = defaults
        self.fileManager = fileManager
        self.agentRecoveryInspector = agentRecoveryInspector
        if clearRecentProjects {
            defaults.removeObject(forKey: Self.recentProjectsKey)
        }
        loadRecentProjects()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-inbox-marketing"
        ) {
            self.agentTasks.seedMarketingInboxForUITesting()
        }
        #endif
        lspSettings.addObserver(self)
        // Keeps the toolbar attention badge current (#1337). The token is not
        // retained: this registry owns `agentTasks`, so the observer cannot
        // outlive its target, and the closure holds `self` weakly.
        _ = self.agentTasks.addTaskChangeObserver { [weak self] _, tasks in
            self?.recomputeAgentInboxAttentionCounts(tasks: tasks)
        }
    }

    private static func makeDefaultAgentTaskRegistry() -> AgentTaskRegistry {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset-state"),
           arguments.contains("--ui-test-live-agent") {
            return AgentTaskRegistry(
                persistence: LiveAgentUITestTaskPersistence()
            )
        }
        #endif
        return AgentTaskRegistry()
    }

    /// Returns the ProjectManager for a given project URL, creating one if needed.
    /// URLs are resolved to their canonical (real) path to prevent duplicates via symlinks.
    /// Returns nil if the directory no longer exists on disk.
    func projectManager(for projectURL: URL) -> ProjectManager? {
        let canonical = canonicalProjectURL(projectURL)
        return projectManager(
            forCanonicalWorktree: canonical,
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: canonical.path,
                canonicalWorktreePath: canonical.path
            )
        )
    }

    /// Opens a Pine-managed worktree while retaining the owning repository as
    /// the shared project scope. Sibling worktrees therefore remain comparable
    /// without sharing terminal, task, event, checkpoint, or notification IDs.
    func projectManager(for worktree: AgentManagedWorktree) -> ProjectManager? {
        let repository = canonicalProjectURL(worktree.repositoryRoot)
        let managedRoot = canonicalProjectURL(worktree.managedRoot)
        let worktreeRoot = canonicalProjectURL(worktree.worktreeRoot)
        guard repository == worktree.repositoryRoot.standardizedFileURL,
              managedRoot == worktree.managedRoot.standardizedFileURL,
              worktreeRoot == worktree.worktreeRoot.standardizedFileURL,
              worktreeRoot.deletingLastPathComponent() == managedRoot else {
            return nil
        }
        return projectManager(
            forCanonicalWorktree: worktreeRoot,
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: repository.path,
                canonicalWorktreePath: worktreeRoot.path
            )
        )
    }

    /// Reopens a persisted exact project/worktree scope after both paths have
    /// been canonicalized again. This is used by Inbox navigation and recovery.
    private func projectManager(
        for identity: AgentTaskProjectIdentity
    ) -> ProjectManager? {
        let project = canonicalProjectURL(URL(
            fileURLWithPath: identity.canonicalProjectPath,
            isDirectory: true
        ))
        let worktree = canonicalProjectURL(URL(
            fileURLWithPath: identity.canonicalWorktreePath,
            isDirectory: true
        ))
        guard project.path == identity.canonicalProjectPath,
              worktree.path == identity.canonicalWorktreePath else {
            return nil
        }
        return projectManager(
            forCanonicalWorktree: worktree,
            identity: identity
        )
    }

    private func projectManager(
        forCanonicalWorktree canonical: URL,
        identity: AgentTaskProjectIdentity
    ) -> ProjectManager? {
        if let existing = openProjects[canonical] {
            guard agentTaskProjectsByRoot[canonical] == identity else {
                return nil
            }
            // Verify directory still exists when reopening from background
            if backgroundProjects.contains(canonical) {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    // Directory was deleted while in background — clean up
                    existing.requestUserTaskShutdown()
                    existing.terminal.terminateAll()
                    existing.shutdownLanguageServers()
                    let ownerID = ObjectIdentifier(existing)
                    detachedTaskCleanupProjects[ownerID] = existing
                    Task { @MainActor [weak self] in
                        let didStop = await existing.shutdownUserTasks(
                            until: .now() + 2
                        )
                        if didStop {
                            self?.detachedTaskCleanupProjects.removeValue(
                                forKey: ownerID
                            )
                        }
                    }
                    openProjects.removeValue(forKey: canonical)
                    agentTaskProjectsByRoot.removeValue(forKey: canonical)
                    backgroundProjects.remove(canonical)
                    agentTasks.setWindowOpen(
                        false,
                        project: identity
                    )
                    existing.terminal.setAgentTaskWindowOpen(false)
                    recentProjects.removeAll { $0 == canonical }
                    saveRecentProjects()
                    return nil
                }
                backgroundProjects.remove(canonical)
                agentTasks.setWindowOpen(true, project: identity)
                existing.terminal.setAgentTaskWindowOpen(true)
            }
            addToRecent(canonical)
            return existing
        }
        // Validate that the directory still exists
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDir),
              isDir.boolValue else {
            recentProjects.removeAll { $0 == canonical }
            saveRecentProjects()
            return nil
        }
        var isProjectDir: ObjCBool = false
        guard fileManager.fileExists(
            atPath: identity.canonicalProjectPath,
            isDirectory: &isProjectDir
        ), isProjectDir.boolValue else { return nil }
        guard !isProjectAdmissionFrozenForTermination else { return nil }
        agentTasks.registerProject(identity)
        let pm = ProjectManager(
            lspSettings: lspSettings,
            agentTaskRegistry: agentTasks
        )
        if isAutoSaveFrozenForTermination {
            pm.freezeAutoSaveForTermination()
        }
        pm.loadDirectory(url: canonical, agentTaskProject: identity)
        openProjects[canonical] = pm
        agentTaskProjectsByRoot[canonical] = identity
        addToRecent(canonical)
        #if DEBUG
        seedAgentRecoveryUITestFixture(
            project: identity
        )
        #endif
        return pm
    }

    #if DEBUG
    /// Creates a durable, terminated Pine-owned task only for the explicit
    /// recovery XCUITest. A second launch loads the persisted card instead of
    /// seeding another one, exercising the real restore boundary.
    private func seedAgentRecoveryUITestFixture(
        project: AgentTaskProjectIdentity
    ) {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-recovery"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await agentTasks.flushPersistence(
                maximumDuration: .seconds(2)
            )
            guard !agentTasks.tasks.contains(where: { $0.project == project }) else {
                return
            }
            let startedAt = Date()
            let terminalID = UUID()
            let context = AgentTaskBridgeContext(
                project: project,
                route: AgentTaskRoute(
                    paneID: UUID(),
                    tabID: terminalID,
                    terminalID: terminalID
                ),
                origin: .pineLaunched,
                observedAt: startedAt
            )
            let launch = agentTasks.preparePineLaunch(
                descriptor: AgentDescriptor(
                    agentType: .codex,
                    launchExecutable: "codex"
                ),
                context: context,
                title: "Recovery fixture",
                objective: "Finish the Pine 2.0 release",
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: startedAt
                )
            )
            guard case .reserved(let reservation) = launch,
                  agentTasks.armLaunch(reservation) else { return }
            let session = AgentSession(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000001307"
                ) ?? UUID(),
                agentType: .codex,
                state: .executing,
                startedAt: startedAt
            )
            _ = session.bindProcessEvidence(AgentProcessEvidence(
                processIdentifier: 13_007,
                processGeneration: 1,
                startIdentifier: "ui-recovery-fixture",
                observedStartedAt: startedAt,
                startIsAuthoritative: true
            ))
            agentTasks.bridge(
                session,
                replacing: nil,
                context: context,
                reservation: reservation
            )
            session.applyLiveness(.terminated)
            agentTasks.bridge(session, replacing: session, context: context)
            _ = await agentTasks.flushPersistence(
                maximumDuration: .seconds(2)
            )
        }
    }

    /// Gives the Open Folder lifecycle XCUITest a deterministic live-agent
    /// transition after the project window has installed its native delegate.
    /// The pane runs a deterministic inert child rather than the user's shell;
    /// agent evidence is synthetic and `ps` polling remains disabled.
    /// The fixture exists only in Debug test hosts and only behind an explicit
    /// launch argument (#1407).
    func seedLiveAgentUITestFixture(
        afterWindowBindingFor projectManager: ProjectManager
    ) async {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-live-agent"
        ) else { return }
        guard await projectManager.awaitDialogOwnerWindow() != nil else {
            guard !Task.isCancelled else { return }
            assertionFailure(
                "Live-agent UI fixture requires a bound project window"
            )
            return
        }
        guard let rootURL = projectManager.rootURL,
              let project = agentTaskProjectsByRoot[canonicalProjectURL(rootURL)] else {
            assertionFailure(
                "Live-agent UI fixture requires a registered project"
            )
            return
        }
        guard !projectManager.terminal.allTerminalTabs.contains(where: {
            $0.agentSession?.currentTask == Self.liveAgentUITestTask
        }) else { return }

        let tab: TerminalTab
        if let existing = projectManager.terminal.allTerminalTabs.first {
            tab = existing
        } else {
            projectManager.paneManager.createTerminalPaneAtBottom(
                workingDirectory: rootURL,
                initialProcess: TerminalInitialProcess(
                    executablePath: "/bin/cat",
                    arguments: []
                )
            )
            guard let created = projectManager.terminal.allTerminalTabs.first else {
                assertionFailure("Live-agent UI fixture requires a terminal tab")
                return
            }
            tab = created
        }
        let startedAt = Date()
        let session = AgentSession(
            agentType: .codex,
            state: .executing,
            startedAt: startedAt,
            currentTask: Self.liveAgentUITestTask
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 14_007,
            processGeneration: 1,
            startIdentifier: "ui-live-agent-1407",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        tab.agentSession = session
        // Exercise the same durable registry mutation and project-window
        // observation invalidation as a genuinely detected active agent.
        projectManager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        assert(agentTasks.tasks.contains(where: { $0.project == project }))
    }

    private static let liveAgentUITestTask =
        "Verify Open Folder while an agent is active"
    #endif

    /// Opens a project via folder picker. Returns the project URL if opened.
    @discardableResult
    func openProjectViaPanel(
        context: DialogPresentationContext
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Strings.openPanelMessage
        panel.prompt = Strings.openPanelPrompt

        guard await panel.runSheet(on: context) == .OK,
              let url = panel.url else { return nil }
        let canonical = canonicalProjectURL(url)
        guard projectManager(for: canonical) != nil else { return nil }
        return canonical
    }

    /// Opens a project via folder picker, first waiting for the project
    /// window to bind a dialog owner (#1344).
    ///
    /// Project scenes bind their AppKit owner asynchronously
    /// (`WindowCloseInterceptor` → `DialogPresenter.register` →
    /// `bindDialogOwnerWindow`), so callers that capture the presentation
    /// context synchronously — e.g. the toolbar Open Folder button and the
    /// `openNewProject()` duplicates — fire into a `nil` owner right after a
    /// window appears or is replaced, and `NSSavePanel.runSheet` silently
    /// aborts. This bounds the wait on `awaitDialogOwnerWindow`, then presents
    /// the panel anchored to the freshly bound owner. Returns `nil` if the
    /// owner never becomes eligible or the user cancels.
    @discardableResult
    func openProjectViaPanel(
        for projectManager: ProjectManager,
        maximumAttempts: Int = 80,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        isEligible: (@MainActor (NSWindow) -> Bool)? = nil
    ) async -> URL? {
        guard await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: maximumAttempts,
            waitForNextAttempt: waitForNextAttempt,
            isEligible: isEligible
        ) != nil else {
            Logger.app.error("Open Folder aborted: no eligible project dialog owner after bounded recovery (#1407)")
            return nil
        }
        let context = DialogPresenter.forProject(projectManager)
        return await openProjectViaPanel(context: context)
    }

    /// Closes the project window but keeps the ProjectManager alive. Terminal
    /// sessions and user tasks continue in the background; reopening the
    /// project restores access to their current state and output history.
    func closeProjectWindow(_ url: URL) {
        let canonical = canonicalProjectURL(url)
        guard openProjects[canonical] != nil else { return }
        backgroundProjects.insert(canonical)
        if let identity = agentTaskProjectsByRoot[canonical] {
            agentTasks.setWindowOpen(false, project: identity)
        }
        openProjects[canonical]?.terminal.setAgentTaskWindowOpen(false)
    }

    /// Closes a project and removes it from open projects.
    /// For backwards compatibility, delegates to `closeProjectWindow`.
    func closeProject(_ url: URL) {
        closeProjectWindow(url)
    }

    /// True only when the exact live terminal route is already visible in the
    /// key project window. Merely having Pine active or the project open is not
    /// enough to suppress a notification for another pane or terminal tab.
    func isAgentTaskPresented(_ taskID: UUID) -> Bool {
        guard let task = agentTasks.task(for: taskID),
              task.lifecycle == .active,
              task.route.availability == .available,
              let run = task.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: task.route.terminalID,
                  runID: run.id
              ) else { return false }
        let projectURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        ).standardizedFileURL
        guard !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              manager.paneManager.activePaneID.id == task.route.paneID,
              manager.paneManager.terminalState(
                  for: PaneID(id: task.route.paneID)
              )?.activeTerminalID == task.route.tabID,
              let window = manager.dialogOwnerWindow,
              window.isVisible,
              window.isKeyWindow,
              window.occlusionState.contains(.visible) else { return false }
        return true
    }

    func canOfferAgentTaskVendorResume(_ taskID: UUID) -> Bool {
        guard agentTasks.canResumeTask(taskID),
              let task = agentTasks.task(for: taskID) else { return false }
        return agentRecoveryInspector.canOfferVendorResume(for: task)
    }

    /// Re-resolves a persisted route against current application ownership.
    /// No UI object is retained by the durable registry; every activation must
    /// cross this boundary immediately before use.
    func resolveAgentTaskRoute(
        _ taskID: UUID,
        targetTerminalID: UUID? = nil
    ) async -> AgentTaskRoute? {
        guard let task = agentTasks.task(for: taskID) else { return nil }
        if task.lifecycle == .paused, let targetTerminalID {
            return await resolvePausedAgentTaskRoute(
                task,
                targetTerminalID: targetTerminalID
            )
        }
        guard task.lifecycle == .active,
              task.route.availability == .available,
              let run = task.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: task.route.terminalID,
                  runID: run.id
              ) else { return nil }
        let rawURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await Task.detached {
            Self.canonicalProjectURL(rawURL)
        }.value
        guard let currentTask = agentTasks.task(for: taskID),
              currentTask == task,
              currentTask.lifecycle == .active,
              currentTask.route.availability == .available,
              let currentRun = currentTask.runs.last,
              currentRun == run,
              currentRun.liveness == .live,
              currentRun.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: currentTask.route.terminalID,
                  runID: currentRun.id
              ),
              !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              projectURL.path == task.project.canonicalWorktreePath else {
            return nil
        }

        var matches: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard let state = manager.paneManager.terminalState(for: paneID) else {
                continue
            }
            for tab in state.terminalTabs {
                guard tab.id == task.route.terminalID,
                      let session = tab.agentSession,
                      session.id == run.id,
                      session.liveness == .live,
                      session.agentType == task.descriptor.agentType,
                      let observed = session.processEvidence,
                      observed.identifiesSameProcess(as: run.process),
                      run.terminalID == tab.id,
                      agentTasks.isExactLiveOwner(
                          taskID: taskID,
                          terminalID: tab.id,
                          runID: session.id
                      ) else {
                    continue
                }
                matches.append(AgentTaskRoute(
                    paneID: paneID.id,
                    tabID: tab.id,
                    terminalID: tab.id
                ))
            }
        }
        guard matches.count == 1,
              matches[0] == currentTask.route,
              agentTasks.task(for: taskID) == currentTask,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: currentTask.route.terminalID,
                  runID: currentRun.id
              ),
              !backgroundProjects.contains(projectURL) else { return nil }
        return matches[0]
    }

    /// Opens (when necessary), re-resolves, and focuses one exact live agent
    /// route. Every suspension is followed by the same task/run/process
    /// validation used by `resolveAgentTaskRoute`; a replacement shell or PID
    /// generation therefore degrades to `.routeStale` without navigation.
    func navigateToAgentTaskFromInbox(
        _ taskID: UUID,
        openProjectWindow: @escaping @MainActor (URL) -> Void,
        waitUntilPresented: (@MainActor (ProjectManager) async -> Bool)? = nil,
        activateApplication: (@MainActor (ProjectManager) -> Void)? = nil,
        expectedNotificationRoute: AgentNotificationRouteIdentity? = nil
    ) async -> AgentInboxNavigationResult {
        guard let initialTask = agentTasks.task(for: taskID) else {
            return .taskMissing
        }
        guard initialTask.lifecycle == .active,
              initialTask.route.availability != .missing,
              matches(initialTask, expectedNotificationRoute) else {
            return .routeStale
        }

        let rawURL = URL(
            fileURLWithPath: initialTask.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await Task.detached {
            Self.canonicalProjectURL(rawURL)
        }.value
        guard projectURL.path == initialTask.project.canonicalWorktreePath,
              let manager = projectManager(for: initialTask.project),
              manager.rootURL == projectURL else {
            return .projectUnavailable
        }

        if initialTask.route.availability == .background {
            openProjectWindow(projectURL)
        }
        let presented = if let waitUntilPresented {
            await waitUntilPresented(manager)
        } else {
            await manager.awaitDialogOwnerWindow() != nil
        }
        guard presented else { return .projectUnavailable }

        guard let route = await resolveAgentTaskRoute(taskID),
              let currentTask = agentTasks.task(for: taskID),
              currentTask.lifecycle == .active,
              currentTask.route == route,
              currentTask.route.availability == .available,
              let run = currentTask.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              matches(currentTask, expectedNotificationRoute),
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: route.terminalID,
                  runID: run.id
              ) else {
            return .routeStale
        }

        let activate: @MainActor () -> Void
        if let activateApplication {
            activate = { activateApplication(manager) }
        } else if let window = manager.dialogOwnerWindow {
            activate = {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        } else {
            return .projectUnavailable
        }

        guard manager.paneManager.selectTerminalTab(
            route.tabID,
            in: PaneID(id: route.paneID)
        ) else {
            return .routeStale
        }
        _ = agentTasks.setReviewed(true, taskID: taskID)
        activate()
        return .focused(route)
    }

    /// Recovers a durable task only after an explicit Inbox action. The task,
    /// project binding, executable and adapter version are inspected again
    /// after the project window is presented and immediately before launch.
    func recoverAgentTaskFromInbox(
        _ taskID: UUID,
        action: AgentTaskRecoveryAction,
        openProjectWindow: @escaping @MainActor (URL) -> Void,
        waitUntilPresented: (@MainActor (ProjectManager) async -> Bool)? = nil,
        activateApplication: (@MainActor (ProjectManager) -> Void)? = nil
    ) async -> AgentInboxRecoveryResult {
        guard let initialTask = agentTasks.task(for: taskID) else {
            return .taskMissing
        }
        let rawURL = URL(
            fileURLWithPath: initialTask.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await Task.detached {
            Self.canonicalProjectURL(rawURL)
        }.value
        guard projectURL.path == initialTask.project.canonicalWorktreePath,
              let manager = projectManager(for: initialTask.project),
              manager.rootURL == projectURL else {
            return .projectUnavailable
        }

        if backgroundProjects.contains(projectURL) {
            openProjectWindow(projectURL)
        }
        let presented = if let waitUntilPresented {
            await waitUntilPresented(manager)
        } else {
            await manager.awaitDialogOwnerWindow() != nil
        }
        guard presented else { return .projectUnavailable }
        guard agentTasks.task(for: taskID) == initialTask else {
            return .changedWhilePreparing
        }

        let evaluation = await agentRecoveryInspector.inspect(
            task: initialTask,
            action: action
        )
        guard agentTasks.task(for: taskID) == initialTask else {
            return .changedWhilePreparing
        }
        guard case .ready(let plan) = evaluation else {
            if case .unavailable(let reason) = evaluation {
                return .unavailable(reason)
            }
            return .launchRejected
        }

        let result = manager.terminal.launchAgentRecovery(plan)
        let terminalID: UUID
        switch result {
        case .openedNewSession(let id):
            terminalID = id
        case .resumed(let id):
            terminalID = id
        case .rejected:
            return .launchRejected
        }
        guard let route = resolveAgentRecoveryTerminal(
            terminalID,
            in: manager
        ), manager.paneManager.selectTerminalTab(
            route.tabID,
            in: PaneID(id: route.paneID)
        ) else { return .launchRejected }

        if let activateApplication {
            activateApplication(manager)
        } else if let window = manager.dialogOwnerWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return switch result {
        case .openedNewSession: .openedNewSession(terminalID: terminalID)
        case .resumed: .resumed(terminalID: terminalID)
        case .rejected: .launchRejected
        }
    }

    private func resolveAgentRecoveryTerminal(
        _ terminalID: UUID,
        in manager: ProjectManager
    ) -> AgentTaskRoute? {
        var routes: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard manager.paneManager.terminalState(for: paneID)?
                .terminalTabs.contains(where: { $0.id == terminalID }) == true else {
                continue
            }
            routes.append(AgentTaskRoute(
                paneID: paneID.id,
                tabID: terminalID,
                terminalID: terminalID
            ))
        }
        return routes.count == 1 ? routes[0] : nil
    }

    private func matches(
        _ task: AgentTask,
        _ expected: AgentNotificationRouteIdentity?
    ) -> Bool {
        guard let expected else { return true }
        guard task.id == expected.taskID,
              let run = task.runs.last else { return false }
        return run.id == expected.runID
            && run.process.processGeneration == expected.processGeneration
    }

    private func resolvePausedAgentTaskRoute(
        _ task: AgentTask,
        targetTerminalID: UUID
    ) async -> AgentTaskRoute? {
        let rawURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await Task.detached {
            Self.canonicalProjectURL(rawURL)
        }.value
        guard let currentTask = agentTasks.task(for: task.id),
              currentTask == task,
              agentTasks.canResumeTask(task.id),
              !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              projectURL.path == task.project.canonicalWorktreePath else {
            return nil
        }

        var matches: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard let state = manager.paneManager.terminalState(for: paneID) else {
                continue
            }
            for tab in state.terminalTabs where tab.id == targetTerminalID {
                matches.append(AgentTaskRoute(
                    paneID: paneID.id,
                    tabID: tab.id,
                    terminalID: tab.id
                ))
            }
        }
        guard matches.count == 1,
              agentTasks.task(for: task.id) == currentTask else {
            return nil
        }
        return matches[0]
    }

    func freezeAgentTasksForTermination() {
        isProjectAdmissionFrozenForTermination = true
        for manager in openProjects.values {
            manager.terminal.freezeAgentTasksForTermination()
        }
        for manager in detachedTaskCleanupProjects.values {
            manager.terminal.freezeAgentTasksForTermination()
        }
    }

    func freezeAutoSaveForTermination() {
        guard !isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = true
        openProjects.values.forEach { $0.freezeAutoSaveForTermination() }
        detachedTaskCleanupProjects.values.forEach {
            $0.freezeAutoSaveForTermination()
        }
    }

    func captureApplicationTerminationSaveInventory(
        allowingSaveAs destinationsByTabID: [UUID: URL]
    ) -> TerminationSaveInventoryAuthorization {
        let projectsByRoot = openProjects.mapValues(ObjectIdentifier.init)
        return TerminationSaveInventoryAuthorization(
            projectsByRoot: projectsByRoot,
            tabsByProject: Dictionary(uniqueKeysWithValues: openProjects
                .values.map { projectManager in
                    (
                        ObjectIdentifier(projectManager),
                        projectManager.captureTerminationOpenTabInventory(
                            allowingSaveAs: destinationsByTabID
                        )
                    )
                })
        )
    }

    func applicationTerminationSaveInventoryStillMatches(
        _ authorization: TerminationSaveInventoryAuthorization
    ) -> Bool {
        guard openProjects.mapValues(ObjectIdentifier.init)
                == authorization.projectsByRoot else {
            return false
        }
        return openProjects.values.allSatisfy { projectManager in
            guard let inventory = authorization.tabsByProject[
                ObjectIdentifier(projectManager)
            ] else {
                return false
            }
            return projectManager.terminationOpenTabInventoryStillMatches(
                inventory
            )
        }
    }

    func cancelAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        openProjects.values.forEach {
            $0.cancelAutoSaveTerminationFreeze()
        }
        detachedTaskCleanupProjects.values.forEach {
            $0.cancelAutoSaveTerminationFreeze()
        }
    }

    func finishAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        openProjects.values.forEach {
            $0.finishAutoSaveTerminationFreeze()
        }
        detachedTaskCleanupProjects.values.forEach {
            $0.finishAutoSaveTerminationFreeze()
        }
    }

    @discardableResult
    func cancelAgentTaskTermination(
        maximumDuration: Duration? = nil
    ) async -> Bool {
        let windowOpenByProject = Dictionary(
            agentTaskProjectsByRoot.map { url, identity in
                (identity, !backgroundProjects.contains(url))
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let rollbackWasSaved = await agentTasks
            .cancelApplicationTerminationAndFlush(
                reconcilingWindowOpen: windowOpenByProject,
                maximumDuration: maximumDuration
            )
        for (url, manager) in openProjects {
            let isWindowOpen = !backgroundProjects.contains(url)
            manager.terminal.setAgentTaskWindowOpen(isWindowOpen)
            manager.terminal.cancelAgentTaskTermination()
        }
        for manager in detachedTaskCleanupProjects.values {
            manager.terminal.cancelAgentTaskTermination()
        }
        isProjectAdmissionFrozenForTermination = false
        return rollbackWasSaved
    }

    @discardableResult
    func cancelAgentTaskTermination(
        until deadline: DispatchTime
    ) async -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining: Duration = if now < deadline.uptimeNanoseconds {
            .nanoseconds(
                Int64(clamping: deadline.uptimeNanoseconds - now)
            )
        } else {
            .zero
        }
        return await cancelAgentTaskTermination(
            maximumDuration: remaining
        )
    }

    /// Whether any open or detached project still owns a user-task execution.
    /// Application termination uses this for its aggregated preflight and
    /// final revalidation. Only an explicit Quit Anyway decision authorizes
    /// bounded TERM/KILL cleanup before project ownership is destroyed.
    var hasOutstandingUserTaskExecution: Bool {
        userTaskOwners.contains { $0.hasOutstandingUserTaskExecution }
    }

    func captureUserTaskShutdownAuthorization()
        -> UserTaskShutdownAuthorization {
        UserTaskShutdownAuthorization(byOwner: Dictionary(
            uniqueKeysWithValues: userTaskOwners.map { projectManager in
                (
                    ObjectIdentifier(projectManager),
                    projectManager.captureUserTaskShutdownAuthorization()
                )
            }
        ))
    }

    func userTaskShutdownAuthorizationStillCovers(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        userTaskOwners.allSatisfy { projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownAuthorizationStillCovers(
                captured
            )
        }
    }

    /// Cancels and waits for all project-owned user tasks against one shared
    /// absolute deadline. Blocking process waits happen off the main actor.
    @discardableResult
    func shutdownUserTasks(
        authorizedBy authorization: UserTaskShutdownAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        // Snapshot before the first suspension point. Main-actor reentrancy may
        // otherwise mutate the registry while an iterator is held across an
        // `await`.
        let projectManagers = userTaskOwners
        guard projectManagers.allSatisfy({ projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownAuthorizationStillCovers(
                captured
            )
        }) else {
            return false
        }
        for projectManager in projectManagers {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            guard projectManager.requestUserTaskShutdown(
                authorizedBy: captured
            ) else {
                return false
            }
        }
        var allCompleted = true
        for projectManager in projectManagers {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            let didComplete = await projectManager.waitForUserTaskShutdown(
                authorizedBy: captured,
                until: deadline
            )
            allCompleted = allCompleted && didComplete
        }

        // Waiting is only the prepare phase. Revalidate every original owner
        // and every owner admitted during a suspension before clearing any
        // store, so one later timeout or launch cannot erase an earlier
        // owner's runs and output when application shutdown rolls back.
        guard allCompleted,
              projectManagers.allSatisfy({ projectManager in
                  let captured = authorization.byOwner[
                      ObjectIdentifier(projectManager)
                  ] ?? UserTaskExecutionAuthorization()
                  return projectManager
                      .userTaskShutdownIsPreparedForCommit(
                          authorizedBy: captured
                      )
              }),
              userTaskShutdownAuthorizationStillCovers(authorization) else {
            return false
        }

        // Application Quit performs its final dirty/terminal authorization
        // recheck after this prepare phase. It commits every prepared store
        // only after that global check succeeds.
        return true
    }

    func userTaskShutdownIsPreparedForCommit(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        userTaskOwners.allSatisfy { projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownIsPreparedForCommit(
                authorizedBy: captured
            )
        } && userTaskShutdownAuthorizationStillCovers(authorization)
    }

    @discardableResult
    func commitPreparedUserTaskShutdown(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        guard userTaskShutdownIsPreparedForCommit(authorization) else {
            return false
        }
        // No suspension is allowed between the aggregate preflight above and
        // the last commit below. Main-actor isolation makes this one global
        // commit boundary for all prepared project stores.
        for projectManager in userTaskOwners {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            projectManager.commitPreparedUserTaskShutdown(
                authorizedBy: captured
            )
        }
        detachedTaskCleanupProjects = detachedTaskCleanupProjects.filter {
            $0.value.hasOutstandingUserTaskExecution
        }
        return !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        })
    }

    /// Legacy project-teardown entry point. Its snapshot is captured at the
    /// call boundary, so it cannot cancel executions created after an await.
    @discardableResult
    func shutdownUserTasks(until deadline: DispatchTime) async -> Bool {
        let authorization = captureUserTaskShutdownAuthorization()
        guard await shutdownUserTasks(
            authorizedBy: authorization,
            until: deadline
        ) else { return false }
        return commitPreparedUserTaskShutdown(authorization)
    }

    /// Fully destroys all project managers after task cleanup has completed.
    ///
    /// Fails closed instead of discarding cancellation handles if a caller
    /// attempts teardown while any user-task execution is still owned.
    @discardableResult
    func destroyAllProjects() -> Bool {
        guard !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        }) else {
            for projectManager in userTaskOwners {
                projectManager.requestUserTaskShutdown()
            }
            return false
        }

        lspSettingsChangeTask?.cancel()
        lspSettingsChangeTask = nil
        for (_, pm) in openProjects {
            pm.terminal.terminateAll()
            pm.shutdownLanguageServers()
        }
        openProjects.removeAll()
        agentTaskProjectsByRoot.removeAll()
        backgroundProjects.removeAll()
        detachedTaskCleanupProjects.removeAll()
        return true
    }

    /// Internal lifecycle observability used by unit tests.
    var detachedUserTaskCleanupCount: Int {
        detachedTaskCleanupProjects.count
    }

    /// Returns true if the project has an open (non-background) window.
    func isWindowOpen(_ url: URL) -> Bool {
        let canonical = canonicalProjectURL(url)
        return openProjects[canonical] != nil && !backgroundProjects.contains(canonical)
    }

    /// Checks if a project is already open (including background).
    func isProjectOpen(_ url: URL) -> Bool {
        openProjects[canonicalProjectURL(url)] != nil
    }

    // MARK: - Agent Inbox

    /// Number of durable agent tasks currently in the Agent Inbox's
    /// "needs attention" section, scoped to one open project window. Drives
    /// the per-project toolbar badge (#1337).
    ///
    /// Returns 0 for unknown/closed projects and for projects with no tasks
    /// awaiting input. Reads the cache maintained by
    /// ``recomputeAgentInboxAttentionCounts(tasks:)``, so this is O(1) and safe
    /// to call from a view body. Per-project scoping (rather than a global
    /// count) keeps sibling project windows from showing each other's
    /// attention counts; a global dock-tile badge is a follow-up.
    func agentInboxAttentionCount(for projectURL: URL) -> Int {
        agentInboxAttentionCounts[canonicalProjectURL(projectURL)] ?? 0
    }

    /// Rebuilds ``agentInboxAttentionCounts`` from a durable task snapshot.
    ///
    /// Called once per task mutation and once per project open/close, never
    /// from a view body. Reuses ``AgentInboxSnapshot`` so the badge always
    /// agrees with the `needsAttention` section the Inbox renders, and groups
    /// rows by project identity so all open windows are updated in a single
    /// O(rows + windows) pass rather than one filter per window.
    private func recomputeAgentInboxAttentionCounts(
        tasks: [AgentTask]? = nil
    ) {
        let tasks = tasks ?? agentTasks.tasks
        var counts: [URL: Int] = [:]
        defer {
            // Assigning an equal value still fires an observation transaction,
            // which would invalidate every project window's root view on any
            // task mutation. Durable tasks churn far more often than the
            // attention count moves, so only publish real changes.
            if agentInboxAttentionCounts != counts {
                agentInboxAttentionCounts = counts
            }
        }
        guard !tasks.isEmpty, !agentTaskProjectsByRoot.isEmpty else { return }
        let snapshot = AgentInboxSnapshot(
            tasks: tasks,
            accuracyPolicy: agentTasks.lifecycleAccuracyPolicy
        )
        guard let needsAttention = snapshot.sections.first(where: {
            $0.id == .needsAttention
        }) else { return }
        // Rows in this section are needs-attention by construction, so only
        // the per-project grouping remains.
        var countsByIdentity: [AgentTaskProjectIdentity: Int] = [:]
        for row in needsAttention.rows {
            let identity = AgentTaskProjectIdentity(
                canonicalProjectPath: row.projectPath,
                canonicalWorktreePath: row.worktreePath
            )
            countsByIdentity[identity, default: 0] += 1
        }
        for (url, identity) in agentTaskProjectsByRoot {
            guard let count = countsByIdentity[identity] else { continue }
            counts[url] = count
        }
    }

    // MARK: - Language Server Settings

    func lspSettingsDidChange(_ change: LSPSettingsChange) {
        let previous = lspSettingsChangeTask
        lspSettingsChangeTask = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            let projectManagers = Array(self.openProjects.values)
            for projectManager in projectManagers {
                guard !Task.isCancelled else { return }
                await projectManager.lspManager.applySettingsChange(change)
            }
        }
    }

    /// Test synchronization point for asynchronous graceful restarts.
    func waitForLSPSettingsChanges() async {
        await lspSettingsChangeTask?.value
    }

    // MARK: - Recent Projects

    /// Shared title for File > Open Recent and the Dock menu. Including the
    /// abbreviated full path keeps equal project basenames distinguishable.
    static func recentProjectDisplayTitle(for url: URL) -> String {
        "\(url.lastPathComponent) — \(url.abbreviatedPath)"
    }

    /// Removes a single project from the recent projects list.
    func removeFromRecent(_ url: URL) {
        let canonical = canonicalProjectURL(url)
        recentProjects.removeAll { $0 == canonical }
        saveRecentProjects()
    }

    /// Removes every recent project from all app surfaces (File menu,
    /// Welcome, and Dock menu) through the registry's single shared source.
    func clearRecentProjects() {
        recentProjects.removeAll()
        saveRecentProjects()
    }

    private func addToRecent(_ url: URL) {
        let canonical = canonicalProjectURL(url)
        recentProjects.removeAll { $0 == canonical }
        recentProjects.insert(canonical, at: 0)
        if recentProjects.count > Self.maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(Self.maxRecentProjects))
        }
        saveRecentProjects()
    }

    private func loadRecentProjects() {
        guard let paths = defaults.stringArray(forKey: Self.recentProjectsKey) else {
            return
        }
        var seen: Set<URL> = []
        recentProjects = paths.compactMap { path in
            let canonical = canonicalProjectURL(
                URL(fileURLWithPath: path)
            )
            var isDir: ObjCBool = false
            guard fileManager.fileExists(
                atPath: canonical.path,
                isDirectory: &isDir
            ),
            isDir.boolValue,
            seen.insert(canonical).inserted else {
                return nil
            }
            return canonical
        }
        recentProjects = Array(recentProjects.prefix(Self.maxRecentProjects))
        if paths != recentProjects.map(\.path) {
            saveRecentProjects()
        }
    }

    private func saveRecentProjects() {
        let paths = recentProjects.map(\.path)
        defaults.set(paths, forKey: Self.recentProjectsKey)
    }

    func canonicalProjectURL(_ projectURL: URL) -> URL {
        Self.canonicalProjectURL(projectURL)
    }

    /// Resolves a stable project identity even after the project directory is
    /// deleted. `resolvingSymlinksInPath()` requires the path to exist before
    /// it reliably resolves prefix symlinks such as `/var` → `/private/var`.
    /// Resolve the nearest existing ancestor, then append every missing
    /// component to preserve the key previously stored in `openProjects`.
    nonisolated static func canonicalProjectURL(_ projectURL: URL) -> URL {
        let standardized = projectURL.standardizedFileURL
        var existingAncestor = standardized
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(
            atPath: existingAncestor.path
        ) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return URL(
            fileURLWithPath: canonical.path,
            isDirectory: true
        ).standardizedFileURL
    }

    private var userTaskOwners: [ProjectManager] {
        var owners: [ObjectIdentifier: ProjectManager] =
            detachedTaskCleanupProjects
        for projectManager in openProjects.values {
            owners[ObjectIdentifier(projectManager)] = projectManager
        }
        return Array(owners.values)
    }
}
