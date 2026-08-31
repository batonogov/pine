//
//  TerminalManager.swift
//  Pine
//
//  Coordinator for terminal panes. Routes Cmd+T and Cmd+` to the
//  appropriate terminal pane via PaneManager.
//

import SwiftUI
import os

nonisolated enum AgentTaskRecoveryLaunchResult: Equatable, Sendable {
    case openedNewSession(terminalID: UUID)
    case resumed(terminalID: UUID)
    case rejected
}

nonisolated struct PineAgentLaunchIdentity: Hashable, Sendable {
    let terminalID: UUID
    let reservation: AgentTaskLaunchReservation
}

nonisolated struct PineAgentSettledLaunchIdentity: Hashable, Sendable {
    let launch: PineAgentLaunchIdentity
    let sessionID: UUID
}

/// Immutable process-generation witness carried by one exact terminal binding.
///
/// This mirrors every field compared by
/// ``AgentProcessEvidence/identifiesSameProcess(as:)``. Activity and History
/// ownership must not weaken that comparison to a PID, executable name, or
/// detector-local generation alone.
nonisolated private struct ProjectTerminalAgentProcessGeneration:
    Hashable, Sendable {
    let processIdentifier: Int32
    let processGeneration: UInt64
    let startIdentifier: String
    let observedStartedAt: Date
    let startIsAuthoritative: Bool

    init?(_ evidence: AgentProcessEvidence?) {
        guard let evidence,
              evidence.startIsAuthoritative,
              let processIdentifier = evidence.processIdentifier,
              processIdentifier > 1,
              evidence.processGeneration > 0,
              let startIdentifier = evidence.startIdentifier,
              !startIdentifier.isEmpty,
              evidence.observedStartedAt.timeIntervalSinceReferenceDate
                .isFinite else {
            return nil
        }
        self.processIdentifier = processIdentifier
        self.processGeneration = evidence.processGeneration
        self.startIdentifier = startIdentifier
        self.observedStartedAt = evidence.observedStartedAt
        self.startIsAuthoritative = evidence.startIsAuthoritative
    }
}

/// One Pine session bound to one authoritative process generation.
nonisolated private struct ProjectTerminalAgentSessionGeneration:
    Hashable, Sendable {
    let sessionID: UUID
    let process: ProjectTerminalAgentProcessGeneration
}

@MainActor
struct PineAgentLaunchAuthorization {
    fileprivate let identities: Set<PineAgentLaunchIdentity>
    fileprivate let settledIdentities: Set<PineAgentSettledLaunchIdentity>

    var requiresConfirmation: Bool { !identities.isEmpty }

    func stillCovers(_ current: PineAgentLaunchAuthorization) -> Bool {
        let authorizedLaunches = identities.union(
            settledIdentities.map(\.launch)
        )
        return current.identities.isSubset(of: authorizedLaunches)
            && current.settledIdentities.allSatisfy {
                authorizedLaunches.contains($0.launch)
            }
    }

    /// Covers an idle-to-foreground transition only when the current terminal
    /// still carries the exact Pine reservation captured by the user's Quit
    /// decision. A raw tab id or a newly observed process group is insufficient.
    func coversLaunch(
        in terminalID: UUID,
        settledSessionID: UUID?,
        current: PineAgentLaunchAuthorization
    ) -> Bool {
        let authorizedLaunches = identities.union(
            settledIdentities.map(\.launch)
        )
        if let settledSessionID {
            return current.settledIdentities.contains { settled in
                settled.launch.terminalID == terminalID
                    && settled.sessionID == settledSessionID
                    && authorizedLaunches.contains(settled.launch)
            }
        }
        return current.identities.contains { identity in
            identity.terminalID == terminalID
                && authorizedLaunches.contains(identity)
        }
    }

    fileprivate var reservations: Set<AgentTaskLaunchReservation> {
        Set(identities.map(\.reservation))
    }
}

@MainActor
@Observable
final class TerminalManager {
    private enum OwnedAgentHistoryRecord {
        case owned(AgentSession)
        case quarantined
        case finalized
    }

    /// Mirrors `AgentHistoryStore`'s bounded public history. Entries are
    /// retained only after an exact tab binding and become value-only
    /// tombstones after conflict/finalization, so detached sessions are not
    /// held forever.
    private static let maxOwnedAgentHistoryGenerations = 500

    /// Reference to the pane manager for creating/finding terminal panes.
    weak var paneManager: PaneManager? {
        didSet { installPaneCallbacks() }
    }

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
    /// Shared in production so every project consumes one machine-wide `ps`
    /// snapshot. Nil for standalone managers, which retain their private-poller
    /// test seam through `agentDetectionProcessRunner`.
    private let agentProcessSnapshotPoller: AgentProcessSnapshotPoller?

    /// Application-lifetime registry and canonical project scope. The
    /// registry itself retains value metadata only; terminal objects retain no
    /// back-reference from it.
    private let agentTaskRegistry: AgentTaskRegistry?
    @ObservationIgnored
    private var agentTaskProject: AgentTaskProjectIdentity?
    @ObservationIgnored
    private var agentTaskCallbacksFrozen = false
    /// Final project teardown is irreversible. Stale view/layout callbacks may
    /// still reference this coordinator, but they cannot create, activate, or
    /// start terminal work after invalidation.
    private(set) var isPermanentlyInvalidated = false
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
    /// Exact reservation-to-session lineage retained after the registry
    /// consumes a launch claim. A durable task id can span many resumes and
    /// is therefore never sufficient destructive authorization by itself.
    @ObservationIgnored
    private var settledAgentLaunches: [
        UUID: PineAgentSettledLaunchIdentity
    ] = [:]
    @ObservationIgnored
    private var ownedAgentHistoryLedger: [
        ProjectTerminalAgentSessionGeneration: OwnedAgentHistoryRecord
    ] = [:]
    @ObservationIgnored
    private var ownedAgentHistoryOrder: [
        ProjectTerminalAgentSessionGeneration
    ] = []

    #if DEBUG
    /// Exact route-update count used to prove a tab move publishes one durable
    /// destination change without touching run/process identity.
    private(set) var agentRouteUpdateCountForTesting = 0
    /// Pane-originated destination publications. Canonical manager calls use
    /// their own non-reporting selection path and do not increment this seam.
    private(set) var paneActivationPublicationCountForTesting = 0
    #endif

    /// `true` once agent-detection polling has started. Read-only diagnostic /
    /// test hook. Delegates to the coordinator's `isRunning` so it correctly
    /// reports `false` after a future `stop()`.
    var isAgentDetectionPolling: Bool { agentCoordinator?.isRunning ?? false }
    #if DEBUG
    var receivedAgentSnapshotCountForTesting: Int {
        agentCoordinator?.receivedSnapshotCountForTesting ?? 0
    }
    #endif

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
        agentProcessSnapshotPoller: AgentProcessSnapshotPoller? = nil,
        agentTaskRegistry: AgentTaskRegistry? = nil
    ) {
        self.agentDetectionProcessRunner = agentDetectionProcessRunner
        self.agentProcessSnapshotPoller = agentProcessSnapshotPoller
        self.agentTaskRegistry = agentTaskRegistry
    }

    /// Installs one-way pane callbacks. `PaneManager` retains these closures,
    /// so every capture of this coordinator is weak and cannot form the
    /// reverse strong edge `PaneManager -> TerminalManager`.
    private func installPaneCallbacks() {
        paneManager?.terminalTabDidMove = { [weak self] tab, paneID in
            self?.agentTerminalDidMove(tab, to: paneID)
        }
        paneManager?.terminalTabDidActivate = { [weak self] paneID, tabID in
            self?.recordTerminalActivation(paneID: paneID, tabID: tabID)
        }
        paneManager?.terminalPaneInventoryDidChange = { [weak self] in
            self?.reconcileTerminalDestination()
        }
    }

    /// Receives an already validated identity from `ProjectRegistry`; this
    /// method performs no filesystem work on MainActor.
    func configureAgentTaskProject(_ project: AgentTaskProjectIdentity) {
        guard !isPermanentlyInvalidated else { return }
        if let agentTaskProject, agentTaskProject != project {
            ownedAgentHistoryLedger.removeAll()
            ownedAgentHistoryOrder.removeAll()
        }
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
        guard !isPermanentlyInvalidated else { return }
        agentTaskWindowOpen = isOpen
    }

    func configureAgentLifecycle(for tab: TerminalTab) {
        guard !isPermanentlyInvalidated else {
            tab.stop()
            return
        }
        guard let agentTaskRegistry, let project = agentTaskProject else { return }
        tab.onLifecycleEnded = { [weak self, weak agentTaskRegistry] terminalID in
            if let reservation = self?.launchReservations.removeValue(
                forKey: terminalID
            ) {
                agentTaskRegistry?.cancelLaunch(reservation)
            }
            self?.acknowledgedAgentLaunches.removeValue(forKey: terminalID)
            self?.settledAgentLaunches.removeValue(forKey: terminalID)
            agentTaskRegistry?.markTerminalClosed(
                terminalID: terminalID,
                project: project
            )
        }
    }

    func agentTerminalDidMove(_ tab: TerminalTab, to paneID: PaneID) {
        guard !isPermanentlyInvalidated else { return }
        if let project = agentTaskProject {
            agentTaskRegistry?.updateRoute(
                terminalID: tab.id,
                project: project,
                route: AgentTaskRoute(
                    paneID: paneID.id,
                    tabID: tab.id,
                    terminalID: tab.id
                )
            )
            #if DEBUG
            agentRouteUpdateCountForTesting += 1
            #endif
        }
        _ = activateTerminal(paneID: paneID, tabID: tab.id)
    }

    // MARK: - Terminal destination routing (#1424)

    /// One validated terminal command destination. Pane identity and the
    /// pane-local active tab travel together so callers cannot accidentally
    /// combine a stale pane pointer with a tab from another split.
    struct Destination {
        let paneID: PaneID
        let tab: TerminalTab
    }

    /// Resolves the current command destination without mutating selection.
    /// The durable pointer wins only while it still names a terminal leaf with
    /// a live active tab; fallback then considers the focused terminal and the
    /// remaining terminal leaves in stable tree order.
    func resolvedDestination() -> Destination? {
        guard let paneManager else { return nil }
        let terminalPaneIDs = paneManager.terminalPaneIDs

        func destination(in paneID: PaneID) -> Destination? {
            guard terminalPaneIDs.contains(paneID),
                  let state = paneManager.terminalState(for: paneID),
                  let activeID = state.activeTerminalID,
                  let tab = state.terminalTabs.first(where: {
                      $0.id == activeID
                  }) else {
                return nil
            }
            return Destination(paneID: paneID, tab: tab)
        }

        if let lastActiveTerminalPaneID,
           let destination = destination(in: lastActiveTerminalPaneID) {
            return destination
        }
        if let destination = destination(in: paneManager.activePaneID) {
            return destination
        }
        for paneID in terminalPaneIDs {
            if let destination = destination(in: paneID) {
                return destination
            }
        }
        return nil
    }

    /// Canonical exact activation for terminal navigation. Validation occurs
    /// before any mutation, and the durable destination advances only after
    /// PaneManager atomically selects the requested pane-local tab.
    @discardableResult
    func activateTerminal(paneID: PaneID, tabID: UUID) -> Bool {
        guard !isPermanentlyInvalidated,
              let paneManager,
              paneManager.terminalPaneIDs.contains(paneID),
              let state = paneManager.terminalState(for: paneID),
              state.terminalTabs.contains(where: { $0.id == tabID }),
              paneManager.selectTerminalTab(
                  tabID,
                  in: paneID,
                  reportActivation: false
              ) else {
            return false
        }
        lastActiveTerminalPaneID = paneID
        return true
    }

    /// Accepts pane-originated user activation only when the callback still
    /// describes the pane's exact selected tab.
    private func recordTerminalActivation(paneID: PaneID, tabID: UUID) {
        guard let paneManager,
              paneManager.terminalPaneIDs.contains(paneID),
              paneManager.activePaneID == paneID,
              paneManager.terminalState(for: paneID)?.activeTerminalID
                == tabID else {
            return
        }
        #if DEBUG
        paneActivationPublicationCountForTesting += 1
        #endif
        lastActiveTerminalPaneID = paneID
    }

    /// Resolves and activates the current destination as one operation.
    /// Callers that subsequently write retain the exact tab object selected by
    /// this validation rather than resolving pane and tab independently.
    func activateResolvedDestination() -> Destination? {
        guard let destination = resolvedDestination(),
              activateTerminal(
                  paneID: destination.paneID,
                  tabID: destination.tab.id
              ) else {
            return nil
        }
        return destination
    }

    /// Writes to an already activated exact destination only while that same
    /// tab remains owned by the same terminal pane.
    @discardableResult
    func sendText(_ text: String, to destination: Destination) -> Bool {
        guard !isPermanentlyInvalidated,
              let paneManager,
              paneManager.terminalPaneIDs.contains(destination.paneID),
              let state = paneManager.terminalState(for: destination.paneID),
              state.activeTerminalID == destination.tab.id,
              state.terminalTabs.contains(where: { $0 === destination.tab }) else {
            return false
        }
        return destination.tab.sendText(text)
    }

    /// Reconciles only the durable pointer after a pane-tree mutation. It does
    /// not steal focus: a removed target is replaced deterministically by the
    /// focused valid terminal or the first valid terminal in tree order.
    private func reconcileTerminalDestination() {
        lastActiveTerminalPaneID = resolvedDestination()?.paneID
    }

    /// Restores destination bookkeeping without changing pane/tab focus.
    /// Invalid persisted preferences fall back to the first valid terminal in
    /// stable tree order and an empty terminal inventory restores `nil`.
    func restoreTerminalDestination(preferredPaneID: PaneID?) {
        guard !isPermanentlyInvalidated else { return }
        guard let paneManager else {
            lastActiveTerminalPaneID = nil
            return
        }
        let paneIDs = paneManager.terminalPaneIDs
        let preferredIsValid = preferredPaneID.map { paneID in
            paneIDs.contains(paneID)
                && paneManager.terminalState(for: paneID)?.activeTab != nil
        } ?? false
        if preferredIsValid {
            lastActiveTerminalPaneID = preferredPaneID
            return
        }
        lastActiveTerminalPaneID = paneIDs.first(where: { paneID in
            paneManager.terminalState(for: paneID)?.activeTab != nil
        })
    }

    func agentTaskContext(for tab: TerminalTab) -> AgentTaskBridgeContext? {
        guard !isPermanentlyInvalidated,
              let paneManager,
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
            presentationContext: AgentTaskPresentationContext(
                terminalStableLabel: tab.stableLabel
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
        guard !isPermanentlyInvalidated,
              !agentTaskCallbacksFrozen,
              let base = agentTaskContext(for: tab),
              let agentTaskRegistry else { return }
        let ownedReservation = reservation ?? launchReservations[tab.id]
        if settledAgentLaunches[tab.id]?.sessionID != session.id {
            settledAgentLaunches[tab.id] = nil
        }
        let context = AgentTaskBridgeContext(
            project: base.project,
            route: base.route,
            presentationContext: base.presentationContext,
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
           !agentTaskRegistry.isLaunchPending(ownedReservation),
           agentTaskRegistry.taskID(forSessionID: session.id)
                == ownedReservation.taskID {
            settledAgentLaunches[tab.id] = PineAgentSettledLaunchIdentity(
                launch: PineAgentLaunchIdentity(
                    terminalID: tab.id,
                    reservation: ownedReservation
                ),
                sessionID: session.id
            )
        }
        if let ownedReservation,
           !agentTaskRegistry.isLaunchPending(ownedReservation) {
            launchReservations[tab.id] = nil
            acknowledgedAgentLaunches[tab.id] = nil
        }
    }

    func capturePineAgentLaunchAuthorization()
        -> PineAgentLaunchAuthorization {
        var identities = Set<PineAgentLaunchIdentity>()
        let staleReservationTerminalIDs = launchReservations.compactMap { terminalID, reservation in
            agentTaskRegistry?.isLaunchPending(reservation) == true
                ? nil
                : terminalID
        }
        for terminalID in staleReservationTerminalIDs {
            launchReservations[terminalID] = nil
            acknowledgedAgentLaunches[terminalID] = nil
        }
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
        let tabsByID = Dictionary(
            uniqueKeysWithValues: allTerminalTabs.map { ($0.id, $0) }
        )
        let staleSettledTerminalIDs = settledAgentLaunches.compactMap { terminalID, settled in
            guard let tab = tabsByID[terminalID],
                  tab.agentSession?.id == settled.sessionID,
                  agentTaskRegistry?.taskID(
                      forSessionID: settled.sessionID
                  ) == settled.launch.reservation.taskID else {
                return terminalID
            }
            return nil
        }
        for terminalID in staleSettledTerminalIDs {
            settledAgentLaunches[terminalID] = nil
        }
        return PineAgentLaunchAuthorization(
            identities: identities,
            settledIdentities: Set(settledAgentLaunches.values)
        )
    }

    /// Pins every exact launch covered by the preflight while the user reads
    /// Quit sheets. The registry retains the claim's remaining lease rather
    /// than charging unbounded human decision time against a short TTL.
    func pauseAuthorizedAgentLaunchesForTerminationDecision(
        _ authorization: PineAgentLaunchAuthorization
    ) -> Bool {
        agentTaskRegistry?.pauseLaunchExpirationForTerminationDecision(
            authorization.reservations
        ) ?? authorization.reservations.isEmpty
    }

    /// Releases a cancelled Quit's lease and drops acknowledgement-only UI
    /// state. Armed reservations remain represented by `launchReservations`;
    /// an acknowledgement whose durable claim disappeared must not continue
    /// authorizing later destructive actions.
    func cancelAuthorizedAgentLaunchTerminationDecision(
        _ authorization: PineAgentLaunchAuthorization
    ) {
        agentTaskRegistry?.resumeLaunchExpirationAfterTerminationDecision(
            authorization.reservations
        )
        acknowledgedAgentLaunches.removeAll()
    }

    /// Waits for every exact PTY write covered by the user's decision to
    /// settle. Pine performs another persistence barrier after this returns,
    /// so a late successful acknowledgement cannot be killed without its
    /// durable interruption marker.
    func waitForAuthorizedAgentLaunchSettlement(
        _ authorization: PineAgentLaunchAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        let clock = ContinuousClock()
        while authorization.identities.contains(where: { identity in
            launchWritesInFlight[identity.terminalID] == identity.reservation
        }) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return false }
            let remaining = deadline.uptimeNanoseconds - now
            do {
                try await clock.sleep(for: .nanoseconds(Int64(clamping: min(
                    remaining,
                    5_000_000
                ))))
            } catch {
                return false
            }
        }
        return true
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
        guard !isPermanentlyInvalidated,
              !agentTaskCallbacksFrozen,
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
            presentationContext: base.presentationContext,
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

    /// Creates an ordinary shell terminal rooted in an isolated worktree,
    /// waits for its exact PTY generation to become writable, then uses the
    /// existing Pine-owned reservation path to launch one known agent token.
    /// The shell remains interactive after the agent exits.
    ///
    /// The wait budget has to cover the whole chain that stands between tab
    /// creation and a live shell: SwiftUI mounting the just-transitioned
    /// worktree project, AppKit giving the terminal container real bounds
    /// (a zero-sized placeholder must not spawn the PTY), the async
    /// working-directory admission validation, and SwiftTerm's fork. Three
    /// seconds covered none of that on a large first render (issue #1590), so
    /// the budget is generous while the deterministic dead ends — admission
    /// refusal, a tab that died first — fail in one hop.
    func launchAgentInNewTerminal(
        _ command: String,
        descriptor: AgentDescriptor,
        workingDirectory: URL,
        maximumAttempts: Int = TerminalManager
            .agentLaunchProcessStartAttempts,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil
    ) async -> AgentTaskLaunchResult {
        let descriptorMatches =
            Self.exactAgentLaunchDescriptor(for: command) == descriptor
        guard descriptorMatches, !isPermanentlyInvalidated else {
            Logger.agent.error(
                "Agent launch rejected before terminal creation (descriptor \(descriptorMatches), invalidated \(self.isPermanentlyInvalidated))"
            )
            return .rejected
        }
        ensureAgentDetectionStarted()
        guard let (_, tab) = createTerminalTabForRecovery(
            workingDirectory: workingDirectory,
            initialProcess: nil
        ) else {
            Logger.agent.error(
                "Agent launch could not create a terminal tab at \(workingDirectory.path, privacy: .public)"
            )
            return .rejected
        }

        let wait = waitForNextAttempt ?? {
            try? await Task.sleep(for: .milliseconds(25))
        }
        var attempts = 0
        var refusalRekicks = 0
        for _ in 0..<max(0, maximumAttempts) where !tab.isProcessRunning {
            guard !Task.isCancelled else {
                cancelAgentLaunch(in: tab)
                return .rejected
            }
            if tab.isTerminated {
                Logger.agent.error(
                    "Agent launch terminal ended before its shell started (after \(attempts) waits)"
                )
                return .rejected
            }
            if tab.processStartAdmissionRefused {
                // The mark means "the last attempt was refused", not "this
                // directory is forbidden": a transient admission miss must
                // not turn into the launch failure it is meant to prevent
                // (#1590). Re-arm one fresh validation before believing it;
                // a genuine refusal repeats and still fails fast.
                guard refusalRekicks < 2 else {
                    Logger.agent.error(
                        "Agent launch shell start was refused by working-directory admission twice (after \(attempts) waits)"
                    )
                    return .rejected
                }
                refusalRekicks += 1
                Logger.agent.debug(
                    "Agent launch re-arming terminal validation after a refused admission (re-kick \(refusalRekicks))"
                )
                tab.startIfNeeded()
                await wait()
                continue
            }
            attempts += 1
            await wait()
        }
        guard tab.isProcessRunning else {
            Logger.agent.error(
                "Agent launch shell never started: \(attempts) waits exhausted at \(workingDirectory.path, privacy: .public)"
            )
            return .rejected
        }
        Logger.agent.debug(
            "Agent launch shell started after \(attempts) waits at \(workingDirectory.path, privacy: .public)"
        )
        let launch = await launchAgentCommand(
            command,
            descriptor: descriptor,
            in: tab
        )
        switch launch {
        case .reserved:
            Logger.agent.debug("Agent launch reserved its terminal")
        case .sentWithoutReservation:
            // The command reached the shell but no reservation was armed —
            // an agent may be running unmanaged. Operational, hence error.
            Logger.agent.error(
                "Agent launch command was sent without a reservation at \(workingDirectory.path, privacy: .public)"
            )
        case .rejected:
            Logger.agent.error(
                "Agent launch command was rejected after the shell started at \(workingDirectory.path, privacy: .public)"
            )
        }
        return launch
    }

    /// 25 ms per attempt × 800 attempts = a 20 s ceiling for the shell to
    /// come up — measured in idle main-actor time: each hop resumes on the
    /// main actor, so heavy contention stretches the wall clock further.
    /// Real mounts finish far inside it; the ceiling exists so a launch that
    /// can never succeed still reports, rather than hanging the session's
    /// `isLaunchingAgent` gate forever.
    static let agentLaunchProcessStartAttempts = 800

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
        guard agentTaskRegistry?.pauseLaunchExpirationForAcknowledgedWrite(
            reservation
        ) == true else {
            cancelAgentLaunch(reservation, in: tab)
            return .rejected
        }
        launchWritesInFlight[tab.id] = reservation
        let acknowledged = await acknowledgedWrite()
        launchWritesInFlight[tab.id] = nil
        agentTaskRegistry?.resumeLaunchExpirationAfterAcknowledgedWrite(
            reservation
        )
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
        if acknowledgedAgentLaunches[tab.id] == reservation {
            acknowledgedAgentLaunches[tab.id] = nil
        }
        agentTaskRegistry?.cancelLaunch(reservation)
    }

    func resumeAgentTaskCommand(
        taskID: UUID,
        command: String,
        in tab: TerminalTab
    ) async -> AgentTaskLaunchResult {
        guard !isPermanentlyInvalidated,
              let agentTaskRegistry,
              let task = agentTaskRegistry.task(for: taskID),
              task.descriptor.launchExecutable == command,
              Self.exactAgentLaunchDescriptor(for: command) == task.descriptor,
              launchWritesInFlight[tab.id] == nil else {
            return .rejected
        }
        let result = prepareAgentResume(taskID: taskID, in: tab)
        guard case .reserved(let reservation) = result else { return result }
        guard agentTaskRegistry.pauseLaunchExpirationForAcknowledgedWrite(
            reservation
        ) else {
            cancelAgentLaunch(reservation, in: tab)
            return .rejected
        }
        launchWritesInFlight[tab.id] = reservation
        let acknowledged = await tab.sendTextAcknowledged(command + "\n")
        launchWritesInFlight[tab.id] = nil
        agentTaskRegistry.resumeLaunchExpirationAfterAcknowledgedWrite(
            reservation
        )
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
        guard !isPermanentlyInvalidated,
              !agentTaskCallbacksFrozen,
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
            presentationContext: base.presentationContext,
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
        agentCoordinator?.suspendForTermination()
    }

    func cancelAgentTaskTermination() {
        guard !isPermanentlyInvalidated,
              agentTaskCallbacksFrozen else { return }
        agentTaskCallbacksFrozen = false
        acknowledgedAgentLaunches.removeAll()
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
        guard !isPermanentlyInvalidated,
              let pm = paneManager,
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
        if let destination = resolvedDestination(),
           let state = pm.terminalState(for: destination.paneID) {
            let tab = state.addTab(
                workingDirectory: workingDirectory,
                initialProcess: initialProcess
            )
            guard activateTerminal(
                paneID: destination.paneID,
                tabID: tab.id
            ) else {
                state.removeTab(id: tab.id)
                return nil
            }
            return (destination.paneID, tab)
        }
        let paneID = pm.createTerminalPaneAtBottom(
            workingDirectory: workingDirectory,
            initialProcess: initialProcess
        )
        pm.pruneEmptyEditorLeaves()
        guard let tab = pm.terminalState(for: paneID)?.activeTab,
              activateTerminal(paneID: paneID, tabID: tab.id) else {
            return nil
        }
        return (paneID, tab)
    }

    /// Adds a tab to one exact existing terminal pane and makes it the shared
    /// command destination. Used by the pane-local plus button so it cannot
    /// bypass destination bookkeeping.
    @discardableResult
    func createTerminalTab(
        in paneID: PaneID,
        workingDirectory: URL?
    ) -> TerminalTab? {
        guard !isPermanentlyInvalidated,
              let pm = paneManager,
              pm.terminalPaneIDs.contains(paneID) else { return nil }
        ensureAgentDetectionStarted()
        guard let tab = pm.addTerminalTab(
            in: paneID,
            workingDirectory: workingDirectory
        ) else { return nil }
        guard activateTerminal(paneID: paneID, tabID: tab.id) else {
            pm.terminalState(for: paneID)?.removeTab(id: tab.id)
            return nil
        }
        return tab
    }

    /// Creates a terminal tab in the last-used terminal pane.
    /// If no terminal pane exists, creates one below the given editor pane.
    func createTerminalTab(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard !isPermanentlyInvalidated, let pm = paneManager else { return }
        // Boot agent detection on the first terminal creation. Idempotent —
        // the guard inside makes repeated calls a no-op. The coordinator
        // lives for the lifetime of this `TerminalManager` and reconciles
        // against all terminal tabs on each 2s poll, so terminals created
        // later are picked up automatically (vision #933, issues #950/#951).
        ensureAgentDetectionStarted()

        if let destination = resolvedDestination(),
           createTerminalTab(
               in: destination.paneID,
               workingDirectory: workingDirectory
           ) != nil {
            // Adding a tab to an existing terminal pane is not a structural
            // mutation — the layout already includes a terminal, so any
            // adjacent empty editor was already pruned (or kept on purpose).
            // No prune needed here.
        } else {
            // Create terminal pane spanning full width at bottom
            let newID = pm.createTerminalPaneAtBottom(workingDirectory: workingDirectory)
            // Collapse any empty editor placeholder that was sitting next to
            // the new terminal — the user clearly wants the screen real estate
            // for terminals, not for "No File Selected".
            pm.pruneEmptyEditorLeaves()
            if let tabID = pm.terminalState(for: newID)?.activeTerminalID {
                _ = activateTerminal(paneID: newID, tabID: tabID)
            }
        }
    }

    /// Focuses the nearest terminal pane, or creates one.
    func focusOrCreateTerminal(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard !isPermanentlyInvalidated, paneManager != nil else { return }

        if let destination = resolvedDestination() {
            _ = activateTerminal(
                paneID: destination.paneID,
                tabID: destination.tab.id
            )
        } else {
            createTerminalTab(relativeTo: editorPaneID, workingDirectory: workingDirectory)
        }
    }

    // MARK: - Display recovery

    /// Rebuilds the presentation layer of every terminal the user can actually
    /// see in this project, recovering panes stuck on a renderer that refuses
    /// every frame (see `TerminalTab.recoverDisplay()`).
    ///
    /// Scoped to the active tab of each terminal pane rather than to
    /// `allTerminalTabs`: a background tab is detached, so recovery there is a
    /// no-op that would still pay a renderer rebuild, and its own re-attach
    /// already repaints it. Every visible pane is covered rather than only the
    /// focused one — the stuck pane is frequently not the one holding focus,
    /// and a user reaching for this command should not have to guess which.
    ///
    /// A permanently invalidated manager owns no live PTYs worth repainting.
    func recoverVisibleTerminalDisplays() {
        guard !isPermanentlyInvalidated, let pm = paneManager else { return }
        for state in pm.terminalStates.values {
            state.activeTab?.recoverDisplay()
        }
    }

    // MARK: - Queries (delegate to PaneManager)

    var allTerminalTabs: [TerminalTab] {
        paneManager?.allTerminalTabs ?? []
    }

    /// Live Activity candidates for this exact project/worktree. The detector
    /// intentionally remains machine-wide until #1421; ownership comes only
    /// from authoritative sessions currently attached to this manager's pane
    /// inventory and attested by an earlier coordinator capture. The ledger
    /// cannot contribute a detached candidate; it only validates the current
    /// object/identity binding.
    var projectOwnedActiveAgentSessions: [AgentSession] {
        guard agentTaskProject != nil else { return [] }
        return exactCurrentAgentBindings()
            .map(\.session)
            .filter { $0.state != .done && $0.liveness == .live }
    }

    /// Captures one exact coordinator-established terminal binding for later
    /// History finalization. Detached sessions cannot enter through this API:
    /// the same tab object must still belong to this pane tree and point to the
    /// same session object at capture time.
    func captureProjectAgentOwnership(
        of session: AgentSession,
        in tab: TerminalTab
    ) {
        guard agentTaskProject != nil,
              allTerminalTabs.contains(where: { $0 === tab }),
              tab.agentSession === session,
              session.liveness == .live,
              session.state != .done,
              let identity = projectTerminalIdentity(for: session) else {
            return
        }

        let conflicts = ownedAgentHistoryLedger.keys.filter { existing in
            (existing.sessionID == identity.sessionID
                && existing.process != identity.process)
                || (existing.process == identity.process
                    && existing.sessionID != identity.sessionID)
        }
        if !conflicts.isEmpty {
            for conflict in conflicts {
                ownedAgentHistoryLedger[conflict] = .quarantined
            }
            ownedAgentHistoryLedger[identity] = .quarantined
            touchOwnedAgentHistoryIdentity(identity)
            trimOwnedAgentHistoryLedger()
            return
        }

        switch ownedAgentHistoryLedger[identity] {
        case .quarantined?, .finalized?:
            break
        case .owned(let existing)? where existing !== session:
            ownedAgentHistoryLedger[identity] = .quarantined
        case .owned?, nil:
            ownedAgentHistoryLedger[identity] = .owned(session)
        }
        touchOwnedAgentHistoryIdentity(identity)
        trimOwnedAgentHistoryLedger()
    }

    /// Atomically consumes exact, terminated owner generations. Retaining a
    /// finalized tombstone prevents a repeated coordinator/application
    /// callback from recreating the same History entry without keeping the
    /// observable session alive.
    func takeProjectOwnedCompletedAgentSessions() -> [AgentSession] {
        var completed: [(ProjectTerminalAgentSessionGeneration, AgentSession)] = []
        for identity in ownedAgentHistoryOrder {
            guard case .owned(let session) = ownedAgentHistoryLedger[identity],
                  session.state == .done,
                  session.liveness == .terminated else {
                continue
            }
            completed.append((identity, session))
        }
        for (identity, _) in completed {
            ownedAgentHistoryLedger[identity] = .finalized
        }
        return completed.map(\.1)
    }

    /// Exact current bindings with conflicts removed fail-closed. Repeating
    /// one session/generation in two tabs deduplicates; reusing a session ID
    /// for another generation or a generation for another session excludes
    /// every conflicting representation.
    private func exactCurrentAgentBindings() -> [(
        identity: ProjectTerminalAgentSessionGeneration,
        session: AgentSession
    )] {
        var bindings: [
            ProjectTerminalAgentSessionGeneration: AgentSession
        ] = [:]
        var conflicting = Set<ProjectTerminalAgentSessionGeneration>()
        for tab in allTerminalTabs {
            guard let session = tab.agentSession,
                  let identity = projectTerminalIdentity(for: session) else {
                continue
            }
            if let existing = bindings[identity], existing !== session {
                conflicting.insert(identity)
            }
            bindings[identity] = session
        }

        let identities = Array(bindings.keys)
        conflicting.formUnion(identities.filter { identity in
            identities.contains { other in
                other != identity
                    && (other.sessionID == identity.sessionID
                        || other.process == identity.process)
            }
        })
        return identities
            .filter { !conflicting.contains($0) }
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
            .compactMap { identity in
                guard let session = bindings[identity],
                      case .owned(let captured) = ownedAgentHistoryLedger[
                        identity
                      ],
                      captured === session else {
                    return nil
                }
                return (identity, session)
            }
    }

    private func projectTerminalIdentity(
        for session: AgentSession
    ) -> ProjectTerminalAgentSessionGeneration? {
        guard let process = ProjectTerminalAgentProcessGeneration(
            session.processEvidence
        ) else {
            return nil
        }
        return ProjectTerminalAgentSessionGeneration(
            sessionID: session.id,
            process: process
        )
    }

    private func touchOwnedAgentHistoryIdentity(
        _ identity: ProjectTerminalAgentSessionGeneration
    ) {
        ownedAgentHistoryOrder.removeAll { $0 == identity }
        ownedAgentHistoryOrder.append(identity)
    }

    private func trimOwnedAgentHistoryLedger() {
        let overflow = ownedAgentHistoryOrder.count
            - Self.maxOwnedAgentHistoryGenerations
        guard overflow > 0 else { return }
        let evicted = ownedAgentHistoryOrder.prefix(overflow)
        for identity in evicted {
            ownedAgentHistoryLedger[identity] = nil
        }
        ownedAgentHistoryOrder.removeFirst(overflow)
    }

    var hasActiveProcesses: Bool {
        allTerminalTabs.contains { $0.hasForegroundProcess }
    }

    /// Exact process/launch evidence that requires a background project to
    /// retain its terminal objects. Stale agent evidence is uncertainty and
    /// therefore fails closed until a later successful shared snapshot.
    var requiresBackgroundRetention: Bool {
        !launchReservations.isEmpty
            || !launchWritesInFlight.isEmpty
            || !acknowledgedAgentLaunches.isEmpty
            || allTerminalTabs.contains { tab in
                tab.isProcessRunning
                    || tab.agentSession.map {
                        $0.liveness != .terminated
                    } == true
            }
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
        guard !isPermanentlyInvalidated, let pm = paneManager else { return }
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
        guard !isPermanentlyInvalidated,
              !agentTaskCallbacksFrozen,
              agentCoordinator == nil else { return }
        // Allow UI tests (and users hitting the macos-26 fork/spawn hang,
        // #1060) to disable the coordinator entirely. Without this gate the
        // repeated 2s `ps` fork hangs the terminal UI-test shards on macos-26
        // runners — unit tests inject a no-op runner instead, so they do not
        // set this flag and still exercise the boot path.
        if Self.isAgentDetectionDisabled { return }
        let coord: AgentDetectionCoordinator
        if let agentProcessSnapshotPoller {
            coord = AgentDetectionCoordinator(
                detector: agentDetector,
                terminalManager: self,
                poller: agentProcessSnapshotPoller
            )
        } else {
            coord = AgentDetectionCoordinator(
                detector: agentDetector,
                terminalManager: self,
                processRunner: agentDetectionProcessRunner
            )
        }
        agentCoordinator = coord
        coord.start()
    }

    /// Removes this project from application-wide process observation. Final
    /// reclamation calls this only after proving no live/stale process owner
    /// remains, so clearing tab-local detector state cannot lose live work.
    func shutdownAgentDetection() {
        agentCoordinator?.stop()
        agentCoordinator = nil
    }

    /// Permanently tears down every PTY and rejects all later terminal work.
    /// This is distinct from reversible project-window suspension.
    func shutdownPermanently() {
        guard !isPermanentlyInvalidated else { return }
        isPermanentlyInvalidated = true
        terminateAll()
        agentTaskCallbacksFrozen = true
        shutdownAgentDetection()
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
