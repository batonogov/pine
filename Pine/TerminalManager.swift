//
//  TerminalManager.swift
//  Pine
//
//  Coordinator for terminal panes. Routes Cmd+T and Cmd+` to the
//  appropriate terminal pane via PaneManager.
//

import SwiftUI

nonisolated enum AgentTaskRecoveryLaunchResult: Equatable, Sendable {
    case openedNewSession(terminalID: UUID)
    case resumed(terminalID: UUID)
    case rejected
}

nonisolated struct PineAgentLaunchIdentity: Hashable, Sendable {
    let terminalID: UUID
    let reservation: AgentTaskLaunchReservation
}

@MainActor
struct PineAgentLaunchAuthorization {
    fileprivate let identities: Set<PineAgentLaunchIdentity>

    var requiresConfirmation: Bool { !identities.isEmpty }

    func stillCovers(_ current: PineAgentLaunchAuthorization) -> Bool {
        current.identities.isSubset(of: identities)
    }
}

@MainActor
@Observable
final class TerminalManager {
    /// Reference to the pane manager for creating/finding terminal panes.
    weak var paneManager: PaneManager?

    /// ID of the last-focused terminal pane (for Cmd+T routing).
    var lastActiveTerminalPaneID: PaneID?

    // MARK: - Agent detection (#950, #951)

    /// The agent detector fed by `agentCoordinator`. Exposed read-only so
    /// future consumers (status bar #952) can observe it.
    private(set) var agentDetector = AgentDetector()

    /// Process runner used by the agent-detection coordinator to capture the
    /// `ps` snapshot. Defaults to real subprocess execution (`runRealProcess`);
    /// tests inject a no-op at construction to avoid forking `/bin/ps` (and
    /// the macos-26 fork/spawn hang, #1060). Read once at boot; stored
    /// privately so it cannot be mutated after construction.
    private let agentDetectionProcessRunner: ProcessRunner

    /// Application-lifetime registry and canonical project scope. The
    /// registry itself retains value metadata only; terminal objects retain no
    /// back-reference from it.
    private let agentTaskRegistry: AgentTaskRegistry?
    @ObservationIgnored
    private var agentTaskProject: AgentTaskProjectIdentity?
    @ObservationIgnored
    private var agentTaskCallbacksFrozen = false
    @ObservationIgnored
    private var agentTaskWindowOpen = true
    @ObservationIgnored
    private var launchReservations: [UUID: AgentTaskLaunchReservation] = [:]
    @ObservationIgnored
    private var launchWritesInFlight: [
        UUID: AgentTaskLaunchReservation
    ] = [:]
    /// A successful PTY write remains destructive work even when its durable
    /// claim expires or cannot be armed before detector evidence arrives.
    @ObservationIgnored
    private var acknowledgedAgentLaunches: [
        UUID: AgentTaskLaunchReservation
    ] = [:]

    /// `true` once agent-detection polling has started. Read-only diagnostic /
    /// test hook. Delegates to the coordinator's `isRunning` so it correctly
    /// reports `false` after a future `stop()`.
    var isAgentDetectionPolling: Bool { agentCoordinator?.isRunning ?? false }

    /// Coordinator that polls `ps` off the main thread and reconciles agent
    /// sessions with terminal tabs. Started lazily by
    /// ``ensureAgentDetectionStarted()`` — invoked on the first terminal
    /// creation via ``createTerminalTab(relativeTo:workingDirectory:)``, on
    /// session restore (`ContentView.restoreSessionIfNeeded`), and via
    /// ``startTerminals(workingDirectory:)``.
    private var agentCoordinator: AgentDetectionCoordinator?

    /// Creates a terminal manager. `agentDetectionProcessRunner` is injected
    /// here (rather than exposed as a mutable property) so the coordinator's
    /// runner is fixed for the manager's lifetime — matches the init-param
    /// injection pattern used by `ExternalFileFormatter` / `FileFormatter`.
    init(
        agentDetectionProcessRunner: @escaping ProcessRunner = runRealProcess,
        agentTaskRegistry: AgentTaskRegistry? = nil
    ) {
        self.agentDetectionProcessRunner = agentDetectionProcessRunner
        self.agentTaskRegistry = agentTaskRegistry
    }

    /// Receives an already validated identity from `ProjectRegistry`; this
    /// method performs no filesystem work on MainActor.
    func configureAgentTaskProject(_ project: AgentTaskProjectIdentity) {
        agentTaskProject = project
    }

    func configureAgentTaskProject(_ projectURL: URL) {
        let path = projectURL.standardizedFileURL.path
        configureAgentTaskProject(AgentTaskProjectIdentity(
            canonicalProjectPath: path,
            canonicalWorktreePath: path
        ))
    }

    func setAgentTaskWindowOpen(_ isOpen: Bool) {
        agentTaskWindowOpen = isOpen
    }

    func configureAgentLifecycle(for tab: TerminalTab) {
        guard let agentTaskRegistry, let project = agentTaskProject else { return }
        tab.onLifecycleEnded = { [weak self, weak agentTaskRegistry] terminalID in
            if let reservation = self?.launchReservations.removeValue(
                forKey: terminalID
            ) {
                agentTaskRegistry?.cancelLaunch(reservation)
            }
            self?.acknowledgedAgentLaunches.removeValue(forKey: terminalID)
            agentTaskRegistry?.markTerminalClosed(
                terminalID: terminalID,
                project: project
            )
        }
    }

    func agentTerminalDidMove(_ tab: TerminalTab, to paneID: PaneID) {
        guard let project = agentTaskProject else { return }
        agentTaskRegistry?.updateRoute(
            terminalID: tab.id,
            project: project,
            route: AgentTaskRoute(
                paneID: paneID.id,
                tabID: tab.id,
                terminalID: tab.id
            )
        )
    }

    func agentTaskContext(for tab: TerminalTab) -> AgentTaskBridgeContext? {
        guard let paneManager,
              let project = agentTaskProject,
              let paneID = paneManager.terminalPaneIDs.first(where: { paneID in
                  paneManager.terminalState(for: paneID)?
                      .terminalTabs.contains(where: { $0 === tab }) == true
              }) else {
            return nil
        }
        return AgentTaskBridgeContext(
            project: project,
            route: AgentTaskRoute(
                paneID: paneID.id,
                tabID: tab.id,
                terminalID: tab.id,
                availability: agentTaskWindowOpen ? .available : .background
            ),
            origin: .discoveredInTerminal
        )
    }

    func bridgeAgentSession(
        _ session: AgentSession,
        replacing previous: AgentSession?,
        in tab: TerminalTab,
        reservation: AgentTaskLaunchReservation? = nil
    ) {
        guard !agentTaskCallbacksFrozen,
              let base = agentTaskContext(for: tab),
              let agentTaskRegistry else { return }
        let ownedReservation = reservation ?? launchReservations[tab.id]
        let context = AgentTaskBridgeContext(
            project: base.project,
            route: base.route,
            origin: ownedReservation == nil
                ? .discoveredInTerminal
                : .pineLaunched,
            observedAt: base.observedAt
        )
        agentTaskRegistry.bridge(
            session,
            replacing: previous,
            context: context,
            reservation: ownedReservation
        )
        if let ownedReservation,
           !agentTaskRegistry.isLaunchPending(ownedReservation) {
            launchReservations[tab.id] = nil
            acknowledgedAgentLaunches[tab.id] = nil
        }
    }

    func capturePineAgentLaunchAuthorization()
        -> PineAgentLaunchAuthorization {
        var identities = Set<PineAgentLaunchIdentity>()
        for (terminalID, reservation) in launchReservations {
            identities.insert(PineAgentLaunchIdentity(
                terminalID: terminalID,
                reservation: reservation
            ))
        }
        for (terminalID, reservation) in launchWritesInFlight {
            identities.insert(PineAgentLaunchIdentity(
                terminalID: terminalID,
                reservation: reservation
            ))
        }
        for (terminalID, reservation) in acknowledgedAgentLaunches {
            identities.insert(PineAgentLaunchIdentity(
                terminalID: terminalID,
                reservation: reservation
            ))
        }
        return PineAgentLaunchAuthorization(identities: identities)
    }

    /// Captures the detector boundary and reserves durable identity for the
    /// exact terminal launch. The caller must invoke this immediately before
    /// starting the process and cancel on launch failure.
    func prepareAgentLaunch(
        in tab: TerminalTab,
        descriptor: AgentDescriptor,
        title: String? = nil,
        objective: String? = nil
    ) -> AgentTaskLaunchResult {
        guard !agentTaskCallbacksFrozen,
              let base = agentTaskContext(for: tab),
              let agentTaskRegistry else { return .rejected }
        if let reservation = launchReservations[tab.id] {
            guard !agentTaskRegistry.isLaunchPending(reservation) else {
                return .rejected
            }
            launchReservations[tab.id] = nil
        }
        let boundary = Date()
        let context = AgentTaskBridgeContext(
            project: base.project,
            route: base.route,
            origin: .pineLaunched,
            observedAt: boundary
        )
        let result = agentTaskRegistry.preparePineLaunch(
            descriptor: descriptor,
            context: context,
            title: title,
            objective: objective,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: agentDetector.processGenerationFloor,
                capturedAt: boundary
            )
        )
        if case .reserved(let reservation) = result {
            launchReservations[tab.id] = reservation
        }
        return result
    }

    /// Owns the exact production handoff for Pine's existing Send to Terminal
    /// action. Only a single known executable token receives launch authority;
    /// arbitrary shell text remains untrusted detector input.
    static func exactAgentLaunchDescriptor(
        for command: String
    ) -> AgentDescriptor? {
        let token = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == token,
              !token.isEmpty,
              !token.contains(where: { $0.isWhitespace }),
              let agentType = AgentType.resolve(fromProcessName: token),
              agentType.cliNames.contains(token) else { return nil }
        return AgentDescriptor(
            agentType: agentType,
            launchExecutable: token
        )
    }

    func launchAgentCommand(
        _ command: String,
        descriptor: AgentDescriptor,
        in tab: TerminalTab
    ) async -> AgentTaskLaunchResult {
        await performAgentLaunch(
            command,
            descriptor: descriptor,
            in: tab
        ) {
            await tab.sendTextAcknowledged(command + "\n")
        }
    }

#if DEBUG
    var agentCallbacksFrozenForTesting: Bool {
        agentTaskCallbacksFrozen
    }

    var hasAcknowledgedAgentLaunchForTesting: Bool {
        !acknowledgedAgentLaunches.isEmpty
    }

    func launchAgentCommandForTesting(
        _ command: String,
        descriptor: AgentDescriptor,
        in tab: TerminalTab,
        acknowledgedWrite: () async -> Bool
    ) async -> AgentTaskLaunchResult {
        await performAgentLaunch(
            command,
            descriptor: descriptor,
            in: tab,
            acknowledgedWrite: acknowledgedWrite
        )
    }
#endif

    private func performAgentLaunch(
        _ command: String,
        descriptor: AgentDescriptor,
        in tab: TerminalTab,
        acknowledgedWrite: () async -> Bool
    ) async -> AgentTaskLaunchResult {
        guard Self.exactAgentLaunchDescriptor(for: command) == descriptor else {
            return .rejected
        }
        guard agentTaskRegistry != nil,
              agentTaskContext(for: tab) != nil else {
            return await acknowledgedWrite()
                ? .sentWithoutReservation
                : .rejected
        }
        guard launchWritesInFlight[tab.id] == nil else {
            return .rejected
        }
        if let existing = launchReservations[tab.id],
           agentTaskRegistry?.isLaunchPending(existing) == true {
            return .rejected
        }
        let result = prepareAgentLaunch(
            in: tab,
            descriptor: descriptor,
            title: nil,
            objective: nil
        )
        guard case .reserved(let reservation) = result else {
            return .rejected
        }
        launchWritesInFlight[tab.id] = reservation
        let acknowledged = await acknowledgedWrite()
        launchWritesInFlight[tab.id] = nil
        guard acknowledged else {
            cancelAgentLaunch(reservation, in: tab)
            return .rejected
        }
        acknowledgedAgentLaunches[tab.id] = reservation
        guard launchReservations[tab.id] == reservation,
              agentTaskRegistry?.armLaunch(reservation) == true else {
            cancelAgentLaunch(reservation, in: tab)
            return .sentWithoutReservation
        }
        return .reserved(reservation)
    }

    func cancelAgentLaunch(in tab: TerminalTab) {
        guard let reservation = launchReservations[tab.id] else { return }
        cancelAgentLaunch(reservation, in: tab)
    }

    private func cancelAgentLaunch(
        _ reservation: AgentTaskLaunchReservation,
        in tab: TerminalTab
    ) {
        if launchReservations[tab.id] == reservation {
            launchReservations[tab.id] = nil
        }
        agentTaskRegistry?.cancelLaunch(reservation)
    }

    func resumeAgentTaskCommand(
        taskID: UUID,
        command: String,
        in tab: TerminalTab
    ) async -> AgentTaskLaunchResult {
        guard let agentTaskRegistry,
              let task = agentTaskRegistry.task(for: taskID),
              task.descriptor.launchExecutable == command,
              Self.exactAgentLaunchDescriptor(for: command) == task.descriptor,
              launchWritesInFlight[tab.id] == nil else {
            return .rejected
        }
        let result = prepareAgentResume(taskID: taskID, in: tab)
        guard case .reserved(let reservation) = result else { return result }
        launchWritesInFlight[tab.id] = reservation
        let acknowledged = await tab.sendTextAcknowledged(command + "\n")
        launchWritesInFlight[tab.id] = nil
        guard acknowledged else {
            cancelAgentLaunch(reservation, in: tab)
            return .rejected
        }
        acknowledgedAgentLaunches[tab.id] = reservation
        guard launchReservations[tab.id] == reservation,
              agentTaskRegistry.armLaunch(reservation) else {
            cancelAgentLaunch(reservation, in: tab)
            return .sentWithoutReservation
        }
        return .reserved(reservation)
    }

    func prepareAgentResume(
        taskID: UUID,
        in tab: TerminalTab
    ) -> AgentTaskLaunchResult {
        guard !agentTaskCallbacksFrozen,
              let base = agentTaskContext(for: tab),
              let agentTaskRegistry else { return .rejected }
        if let reservation = launchReservations[tab.id] {
            guard !agentTaskRegistry.isLaunchPending(reservation) else {
                return .rejected
            }
            launchReservations[tab.id] = nil
        }
        let capturedAt = Date()
        let context = AgentTaskBridgeContext(
            project: base.project,
            route: base.route,
            origin: .pineLaunched,
            observedAt: capturedAt
        )
        let result = agentTaskRegistry.prepareResume(
            taskID: taskID,
            context: context,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: agentDetector.processGenerationFloor,
                capturedAt: capturedAt
            )
        )
        if case .reserved(let reservation) = result {
            launchReservations[tab.id] = reservation
        }
        return result
    }

    func refreshAgentTasks() {
        guard !agentTaskCallbacksFrozen else { return }
        agentTaskRegistry?.refresh(sessions: agentDetector.detectedSessions)
    }

    func markAgentEvidenceUnavailable() {
        guard !agentTaskCallbacksFrozen else { return }
        agentTaskRegistry?.markEvidenceUnavailable(
            sessionIDs: agentDetector.detectedSessions.map(\.id)
        )
    }

    /// Stops polling and invalidates already captured generations before the
    /// app takes its final durable-task snapshot. Late callbacks are ignored.
    func freezeAgentTasksForTermination() {
        guard !agentTaskCallbacksFrozen else { return }
        agentTaskCallbacksFrozen = true
        agentCoordinator?.stop()
    }

    func cancelAgentTaskTermination() {
        guard agentTaskCallbacksFrozen else { return }
        agentTaskCallbacksFrozen = false
        if paneManager?.allTerminalTabs.isEmpty == false {
            if let agentCoordinator {
                agentCoordinator.start()
            } else {
                ensureAgentDetectionStarted()
            }
        }
    }

    // MARK: - Tab creation

    /// Applies a freshly inspected recovery plan. Vendor resume is reserved
    /// and armed before SwiftUI can mount the tab and start its direct child.
    /// A failed reservation removes the unstarted tab and leaves prior task
    /// history untouched.
    func launchAgentRecovery(
        _ plan: AgentTaskRecoveryPlan
    ) -> AgentTaskRecoveryLaunchResult {
        guard let pm = paneManager,
              let project = agentTaskProject,
              project == plan.project,
              project.canonicalWorktreePath
                == plan.workingDirectory.standardizedFileURL.path else {
            return .rejected
        }
        let initialProcess = plan.process.map {
            TerminalInitialProcess(
                executablePath: $0.executablePath,
                arguments: $0.arguments
            )
        }
        guard let (paneID, tab) = createTerminalTabForRecovery(
            workingDirectory: plan.workingDirectory,
            initialProcess: initialProcess
        ) else { return .rejected }

        switch plan.action {
        case .startNewSession:
            return .openedNewSession(terminalID: tab.id)
        case .resumeVendorSession:
            let result = prepareAgentResume(taskID: plan.taskID, in: tab)
            guard case .reserved(let reservation) = result,
                  agentTaskRegistry?.armLaunch(reservation) == true else {
                cancelAgentLaunch(in: tab)
                pm.terminalState(for: paneID)?.removeTab(id: tab.id)
                return .rejected
            }
            return .resumed(terminalID: tab.id)
        }
    }

    private func createTerminalTabForRecovery(
        workingDirectory: URL,
        initialProcess: TerminalInitialProcess?
    ) -> (PaneID, TerminalTab)? {
        guard let pm = paneManager else { return nil }
        ensureAgentDetectionStarted()
        if let paneID = lastActiveTerminalPaneID,
           let state = pm.terminalState(for: paneID) {
            let tab = state.addTab(
                workingDirectory: workingDirectory,
                initialProcess: initialProcess
            )
            pm.activePaneID = paneID
            return (paneID, tab)
        }
        let paneID = pm.createTerminalPaneAtBottom(
            workingDirectory: workingDirectory,
            initialProcess: initialProcess
        )
        lastActiveTerminalPaneID = paneID
        pm.pruneEmptyEditorLeaves()
        guard let tab = pm.terminalState(for: paneID)?.activeTab else {
            return nil
        }
        return (paneID, tab)
    }

    /// Creates a terminal tab in the last-used terminal pane.
    /// If no terminal pane exists, creates one below the given editor pane.
    func createTerminalTab(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }
        // Boot agent detection on the first terminal creation. Idempotent —
        // the guard inside makes repeated calls a no-op. The coordinator
        // lives for the lifetime of this `TerminalManager` and reconciles
        // against all terminal tabs on each 2s poll, so terminals created
        // later are picked up automatically (vision #933, issues #950/#951).
        ensureAgentDetectionStarted()

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            // Adding a tab to an existing terminal pane is not a structural
            // mutation — the layout already includes a terminal, so any
            // adjacent empty editor was already pruned (or kept on purpose).
            // No prune needed here.
            pm.terminalState(for: tpID)?.addTab(workingDirectory: workingDirectory)
            pm.activePaneID = tpID
        } else {
            // Create terminal pane spanning full width at bottom
            let newID = pm.createTerminalPaneAtBottom(workingDirectory: workingDirectory)
            lastActiveTerminalPaneID = newID
            // Collapse any empty editor placeholder that was sitting next to
            // the new terminal — the user clearly wants the screen real estate
            // for terminals, not for "No File Selected".
            pm.pruneEmptyEditorLeaves()
        }
    }

    /// Focuses the nearest terminal pane, or creates one.
    func focusOrCreateTerminal(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }

        if let tpID = lastActiveTerminalPaneID,
           let state = pm.terminalState(for: tpID) {
            pm.activePaneID = tpID
            state.pendingFocusTabID = state.activeTerminalID
        } else if let firstTP = pm.terminalPaneIDs.first,
                  let state = pm.terminalState(for: firstTP) {
            pm.activePaneID = firstTP
            lastActiveTerminalPaneID = firstTP
            state.pendingFocusTabID = state.activeTerminalID
        } else {
            createTerminalTab(relativeTo: editorPaneID, workingDirectory: workingDirectory)
        }
    }

    // MARK: - Queries (delegate to PaneManager)

    var allTerminalTabs: [TerminalTab] {
        paneManager?.allTerminalTabs ?? []
    }

    var hasActiveProcesses: Bool {
        allTerminalTabs.contains { $0.hasForegroundProcess }
    }

    var tabsWithForegroundProcesses: [TerminalTab] {
        allTerminalTabs.filter { $0.hasForegroundProcess }
    }

    func terminateAll() {
        for tab in allTerminalTabs {
            tab.stop()
        }
    }

    func startTerminals(workingDirectory: URL?) {
        guard let pm = paneManager else { return }
        for state in pm.terminalStates.values {
            state.startTabs(workingDirectory: workingDirectory)
        }

        // Start agent detection polling once terminals are live (#951).
        ensureAgentDetectionStarted()
    }

    /// Ensures the agent-detection coordinator is polling `ps` and reconciling
    /// agent sessions with terminal tabs. Idempotent: a no-op once the
    /// coordinator exists, so safe to call on every terminal creation.
    ///
    /// This is the sole boot path for agent detection. It MUST be invoked when
    /// a terminal comes alive — otherwise the coordinator never starts, `ps`
    /// is never polled, and no `AgentSession` is ever attached to a tab, so
    /// agent badges/status-bar items never appear (regression: `startTerminals`
    /// was previously the only caller and was never wired into the app
    /// lifecycle, leaving detection dead in shipped builds).
    ///
    /// Callers: `createTerminalTab` (interactive creation), `startTerminals`
    /// (legacy), and `ContentView.restoreSessionIfNeeded` (session restore
    /// creates tabs via `state.addTab` directly, bypassing `createTerminalTab`).
    /// Internal rather than private so the restore path can reach it.
    func ensureAgentDetectionStarted() {
        guard agentCoordinator == nil else { return }
        // Allow UI tests (and users hitting the macos-26 fork/spawn hang,
        // #1060) to disable the coordinator entirely. Without this gate the
        // repeated 2s `ps` fork hangs the terminal UI-test shards on macos-26
        // runners — unit tests inject a no-op runner instead, so they do not
        // set this flag and still exercise the boot path.
        if Self.isAgentDetectionDisabled { return }
        let coord = AgentDetectionCoordinator(
            detector: agentDetector,
            terminalManager: self,
            processRunner: agentDetectionProcessRunner
        )
        agentCoordinator = coord
        coord.start()
    }

    /// `true` when agent detection is explicitly disabled via the
    /// `--disable-agent-detection` launch argument or the
    /// `PINE_DISABLE_AGENT_DETECTION` environment variable. Used by UI tests
    /// to avoid the macos-26 fork/spawn hang (#1060) and as a production
    /// opt-out for affected users.
    private static var isAgentDetectionDisabled: Bool {
        CommandLine.arguments.contains("--disable-agent-detection")
            || ProcessInfo.processInfo.environment["PINE_DISABLE_AGENT_DETECTION"] != nil
    }

    #if DEBUG
    /// Synchronous one-shot poll for unit tests: runs a single snapshot using
    /// the injected `agentDetectionProcessRunner` so tests can assert detector
    /// state without waiting for the 2s timer. No-op if detection has not
    /// booted. Proves the injected runner is wired through to the coordinator.
    @MainActor internal func runAgentSnapshotForTesting() {
        agentCoordinator?.runSnapshotForTesting()
    }
    #endif
}
