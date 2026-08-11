//
//  TabCloseHelper.swift
//  Pine
//
//  Shared tab close confirmation dialogs used by both ContentView and PaneLeafView.
//  Also provides the shared terminal foreground-process confirmation used by
//  the status bar toggle, tab close, and pane close paths.
//
//  Dialogs attach to a captured owning window and are queued per window.
//  Missing or closed owners cancel the operation instead of falling back to
//  a detached application-modal alert.
//

import AppKit

/// Exact foreground job identity covered by a destructive terminal prompt.
/// A new process group in the same terminal tab is a new authorization
/// generation and must not be covered by the previous answer.
nonisolated struct TerminalForegroundProcessIdentity: Hashable, Sendable {
    let tabID: UUID
    let processGroupID: Int32
    let startIdentity: TerminalProcessStartIdentity?
}

nonisolated struct TerminalProcessStartIdentity: Hashable, Sendable {
    let processID: pid_t
    let seconds: UInt64
    let microseconds: UInt64

    init(
        processID: pid_t,
        seconds: UInt64,
        microseconds: UInt64
    ) {
        self.processID = processID
        self.seconds = seconds
        self.microseconds = microseconds
    }

    init?(processEvidence: AgentProcessEvidence) {
        guard processEvidence.startIsAuthoritative,
              let processID = processEvidence.processIdentifier,
              processID > 1 else { return nil }
        self.init(
            processID: processID,
            startedAt: processEvidence.observedStartedAt
        )
    }

    init?(processID: pid_t, startedAt: Date) {
        guard processID > 1 else { return nil }
        let interval = startedAt.timeIntervalSince1970
        guard interval.isFinite, interval >= 0 else { return nil }
        var seconds = UInt64(interval.rounded(.down))
        var microseconds = UInt64(
            ((interval - Double(seconds)) * 1_000_000).rounded()
        )
        if microseconds == 1_000_000 {
            guard seconds < UInt64.max else { return nil }
            seconds += 1
            microseconds = 0
        }
        self.init(
            processID: processID,
            seconds: seconds,
            microseconds: microseconds
        )
    }
}

/// One coherent foreground-job observation. `.unavailable` is distinct from
/// `.idle`: it means a process group existed but changed or could not be
/// identified exactly while Pine sampled it, so ownership must fail closed.
nonisolated enum TerminalForegroundProcessSnapshot: Equatable, Sendable {
    case idle
    case running(
        processGroupID: Int32,
        identity: TerminalProcessStartIdentity
    )
    case unavailable
}

/// Per-tab coverage captured when a destructive terminal close/stop is
/// authorized. An AI-agent tab (#1335) is covered by its stable
/// agent-session identity rather than its volatile foreground process group:
/// agents constantly spawn short-lived children, so the foreground pgid
/// churns on nearly every poll and must not invalidate a confirmation the
/// user already gave.
nonisolated enum TerminalTabCloseCoverage: Hashable, Sendable {
    /// A non-agent tab is covered by an exact foreground process-group
    /// generation. A new process group in the same tab is a new
    /// authorization generation (existing safety semantics).
    case foregroundProcess(TerminalForegroundProcessIdentity)
    /// An agent tab is covered by its stable session id plus the immutable OS
    /// process-start witness that backs that run. Foreground child churn is
    /// covered only while this exact agent generation remains alive.
    case agentSession(
        sessionID: UUID,
        processIdentity: TerminalProcessStartIdentity?
    )
}

/// Snapshot of the destructive-process coverage authorized for a set of
/// terminal tabs. Re-checked after the user answers the confirmation sheet so
/// a confirmation cannot be silently invalidated by the normal process-group
/// churn of an AI-agent tab (#1335).
@MainActor
struct TerminalTabCloseAuthorization {
    private let coverage: [UUID: TerminalTabCloseCoverage]
    private let foregroundIdentities: Set<TerminalForegroundProcessIdentity>

    /// `true` when at least one tab has a running agent session or foreground
    /// process and therefore needs confirmation.
    var requiresConfirmation: Bool { !coverage.isEmpty }

    /// Deduplication key. Agent tabs contribute only their (stable) tab id —
    /// never a volatile foreground pgid — so repeated close gestures on the
    /// same agent tab collapse to one in-flight request.
    var deduplicationKey: DialogRequestKey {
        .terminalTabs(
            tabIDs: Set(coverage.keys),
            foregroundProcesses: foregroundIdentities
        )
    }

    static func authorizing(tabs: [TerminalTab]) -> TerminalTabCloseAuthorization {
        var coverage: [UUID: TerminalTabCloseCoverage] = [:]
        var foregroundIdentities: Set<TerminalForegroundProcessIdentity> = []
        for tab in tabs {
            if let session = tab.agentSession {
                coverage[tab.id] = .agentSession(
                    sessionID: session.id,
                    processIdentity: session.processEvidence.flatMap(
                        TerminalProcessStartIdentity.init(processEvidence:)
                    )
                )
            } else {
                let processGroupID = tab.foregroundProcessID
                guard processGroupID > 0 else { continue }
                let identity = TerminalForegroundProcessIdentity(
                    tabID: tab.id,
                    processGroupID: processGroupID,
                    startIdentity: tab.foregroundProcessIdentity(
                        in: processGroupID
                    )
                )
                coverage[tab.id] = .foregroundProcess(identity)
                foregroundIdentities.insert(identity)
            }
        }
        return TerminalTabCloseAuthorization(
            coverage: coverage,
            foregroundIdentities: foregroundIdentities
        )
    }

    /// `true` when every authorized tab is still covered by the identity
    /// captured at authorization time. A process that exited while the sheet
    /// was visible is always covered (nothing remains to protect).
    func stillCovers(_ tabs: [TerminalTab]) -> Bool {
        stillCovers(
            tabs,
            pineAgentLaunches: nil,
            currentPineAgentLaunches: nil
        )
    }

    /// Composes foreground-process coverage with Pine's exact launch
    /// reservation. An idle tab may legitimately become foreground while the
    /// Quit sheet is visible when that same launch was already part of the
    /// prompt; unrelated jobs still fail closed.
    func stillCovers(
        _ tabs: [TerminalTab],
        pineAgentLaunches: PineAgentLaunchAuthorization?,
        currentPineAgentLaunches: PineAgentLaunchAuthorization?
    ) -> Bool {
        for tab in tabs {
            // Idle tabs are absent from `coverage`, but they remain safe only
            // while they are still idle. A foreground process or agent that
            // appears after the prompt must be the exact Pine launch separately
            // captured by that same prompt; raw foreground identity is not
            // sufficient to inherit authorization.
            guard let captured = coverage[tab.id] else {
                if tab.agentSession != nil || tab.foregroundProcessID > 0 {
                    guard let pineAgentLaunches,
                          let currentPineAgentLaunches,
                          pineAgentLaunches.coversLaunch(
                              in: tab.id,
                              settledSessionID: tab.agentSession?.id,
                              current: currentPineAgentLaunches
                          ) else {
                        return false
                    }
                }
                continue
            }
            switch captured {
            case .agentSession(let sessionID, let processIdentity):
                // Same agent session: covered (pgid churn is normal agent
                // behaviour) only while the agent's exact OS generation is
                // still alive. Once it exits, only a genuinely idle tab is
                // covered; a replacement foreground job is new work.
                if let currentSession = tab.agentSession {
                    guard currentSession.id == sessionID else { return false }
                    if tab.foregroundProcessID > 0 {
                        guard processIdentity.map({
                            tab.agentProcessIdentityStillMatches($0)
                        }) == true else {
                            return false
                        }
                    }
                } else if tab.foregroundProcessID > 0 {
                    return false
                }
            case .foregroundProcess(let identity):
                // A foreground job may settle into the agent session launched
                // by the exact Pine reservation already covered by this Quit
                // decision. A manually launched job may also be labelled as
                // an agent while the dialog is open; its exact process witness
                // remains the authority in that case.
                let current = tab.foregroundProcessID
                let sameForegroundGeneration = current > 0
                    && current == identity.processGroupID
                    && identity.startIdentity.map {
                        tab.foregroundProcessIdentityStillMatches(
                            $0,
                            in: current
                        )
                    } == true
                if tab.agentSession != nil {
                    let sessionMatchesForegroundWitness =
                        tab.agentSession?.processEvidence?.processIdentifier
                            == identity.startIdentity?.processID
                    if sameForegroundGeneration,
                       sessionMatchesForegroundWitness {
                        continue
                    }
                    guard let pineAgentLaunches,
                          let currentPineAgentLaunches,
                          pineAgentLaunches.coversLaunch(
                              in: tab.id,
                              settledSessionID: tab.agentSession?.id,
                              current: currentPineAgentLaunches
                          ) else {
                        return false
                    }
                    continue
                }
                // Process exited: covered. A new non-zero process group is a
                // new, unauthorized generation.
                if current > 0, !sameForegroundGeneration {
                    return false
                }
            }
        }
        return true
    }
}

@MainActor
enum TabCloseHelper {

    /// Closes a single tab with unsaved-changes protection.
    ///
    /// When `context` resolves a window, the unsaved-changes alert is
    /// presented as a sheet on that window (issue #1241). The save-failure
    /// error alert (if any) is likewise window-scoped.
    ///
    /// - Returns: `true` if the tab was actually closed.
    @discardableResult
    static func closeTab(
        _ tab: EditorTab,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        // Callers commonly create the Task from a SwiftUI value snapshot.
        // Re-resolve identity at async entry so a clean captured value cannot
        // bypass a prompt after the live tab becomes dirty (and a disappeared
        // tab cannot produce a false "closed" result).
        guard let entryTab = tabManager.tabs.first(where: {
            $0.id == tab.id
        }) else {
            return false
        }
        guard !entryTab.isPinned else { return false }
        let tabID = entryTab.id
        let entryContent = entryTab.content
        guard entryTab.isDirty else {
            return tabManager.closeTab(id: tabID) == .closed
        }

        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.unsavedChangesSingle.runSheet(
                on: context,
                deduplicationKey: .editorTabs(
                    tabManager: ObjectIdentifier(tabManager),
                    tabIDs: [tabID]
                ),
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesMessage
            )
        }
        switch response {
        case .alertFirstButtonReturn:
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
                return false
            }
            let didSave: Bool
            if let saveTab {
                didSave = await saveTab(index)
            } else {
                didSave = await tabManager.saveTab(at: index, context: context)
            }
            guard didSave else {
                return false
            }
            // An async/injected saver can suspend. Never let the original
            // Save decision close content dirtied after that save completed.
            guard let currentTab = tabManager.tabs.first(where: {
                $0.id == tabID
            }), !currentTab.isDirty else {
                return false
            }
            Task { await gitProvider.refreshAsync() }
            return tabManager.closeTab(id: tabID) == .closed
        case .alertSecondButtonReturn:
            guard let currentTab = tabManager.tabs.first(where: { $0.id == tabID }) else {
                return false
            }
            // The sheet suspends this task. If background work changed the
            // dirty buffer while it was visible, the user's earlier discard
            // decision no longer covers the current content.
            guard !currentTab.isDirty || currentTab.content == entryContent else {
                return false
            }
            return tabManager.closeTab(id: tabID) == .closed
        default:
            return false
        }
    }

    /// Shows a confirmation dialog for bulk close operations when there are dirty tabs.
    ///
    /// `presentAlert` is invoked to produce the modal response. Production
    /// callers pass a closure that runs the window-scoped sheet; tests inject
    /// an async stub. Returns `true` if the operation should proceed.
    ///
    /// - Parameters:
    ///   - presentAlert: Async closure that presents the confirmation alert
    ///     and returns the modal response. When `nil`, the alert is presented
    ///     as a window-scoped sheet via `context`.
    ///   - saveTab: Optional save override for testing.
    static func confirmBulkClose(
        dirtyTabs: [EditorTab],
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil,
        targetTabIDs: Set<UUID>? = nil
    ) async -> Bool {
        guard !dirtyTabs.isEmpty else { return true }

        let displayedDirtyContent = Dictionary(
            dirtyTabs.map { ($0.id, $0.content) },
            uniquingKeysWith: { _, latest in latest }
        )
        let targetTabIDs = targetTabIDs ?? Set(dirtyTabs.map(\.id))
        let fileList = dirtyTabs.map { "  \u{2022} \($0.fileName)" }.joined(separator: "\n")
        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.unsavedChangesBulk.runSheet(
                on: context,
                deduplicationKey: .editorTabs(
                    tabManager: ObjectIdentifier(tabManager),
                    tabIDs: targetTabIDs
                ),
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesListMessage(fileList)
            )
        }
        switch response {
        case .alertFirstButtonReturn:
            // Save the latest dirty state, including a tab that became dirty
            // while the sheet was visible. Saving is non-destructive and
            // therefore does not need a second confirmation.
            let currentDirtyTabs = tabManager.tabs.filter {
                targetTabIDs.contains($0.id) && $0.isDirty
            }
            for tab in currentDirtyTabs {
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
                let didSave: Bool
                if let saveTab {
                    didSave = await saveTab(index)
                } else {
                    didSave = await tabManager.saveTab(at: index, context: context)
                }
                guard didSave else { return false }
            }
            // A previously saved target can be edited again while a later
            // save or error sheet is suspended. Do not force-close it.
            guard !tabManager.tabs.contains(where: {
                targetTabIDs.contains($0.id) && $0.isDirty
            }) else {
                return false
            }
            Task { await gitProvider.refreshAsync() }
            return true
        case .alertSecondButtonReturn:
            // Do not apply "Don't Save" to a new or changed dirty buffer that
            // was not represented by the sheet the user answered.
            let currentDirtyTabs = tabManager.tabs.filter {
                targetTabIDs.contains($0.id) && $0.isDirty
            }
            guard currentDirtyTabs.allSatisfy({
                displayedDirtyContent[$0.id] == $0.content
            }) else {
                return false
            }
            return true
        default:
            return false
        }
    }

    /// Closes all tabs except the one with the given ID, with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeOtherTabs(
        keeping tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs = Set(
            tabManager.tabs
                .filter { $0.id != tabID && !$0.isPinned }
                .map(\.id)
        )
        let dirty = tabManager.dirtyTabsForCloseOthers(keeping: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        guard tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        tabManager.activeTabID = tabID
        return true
    }

    /// Closes all tabs to the right of the given tab, with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeTabsToTheRight(
        of tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs: Set<UUID>
        if let index = tabManager.tabs.firstIndex(where: { $0.id == tabID }) {
            targetTabIDs = Set(
                tabManager.tabs[(index + 1)...]
                    .filter { !$0.isPinned }
                    .map(\.id)
            )
        } else {
            targetTabIDs = []
        }
        let dirty = tabManager.dirtyTabsForCloseRight(of: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        guard tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        return true
    }

    /// Closes all tabs with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeAllTabs(
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs = Set(tabManager.tabs.map(\.id))
        let dirty = tabManager.dirtyTabsForCloseAll()
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        // A tab created while the sheet was visible was not part of this
        // close authorization and must survive.
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        return true
    }

    private static func closeTabs(
        withIDs tabIDs: Set<UUID>,
        in tabManager: TabManager
    ) {
        tabManager.tabs
            .filter { tabIDs.contains($0.id) }
            .map(\.id)
            .forEach { tabManager.closeTab(id: $0, force: true) }
    }

    // MARK: - Terminal foreground-process confirmation

    /// Decides whether a terminal stop/close operation should proceed when
    /// foreground processes are running.
    ///
    /// - Parameters:
    ///   - hasForegroundProcess: Whether any terminal tab in scope has a
    ///     running foreground process.
    ///   - context: Presentation context for the window-scoped sheet.
    ///   - presentAlert: Async closure that presents the confirmation alert
    ///     and returns the modal response. Injected for testing; defaults to
    ///     the standard `terminalTabCloseWarning` sheet.
    /// - Returns: `true` if there is no foreground process (no warning needed)
    ///     or the user confirmed. `false` to abort the stop/close.
    static func confirmTerminalStop(
        hasForegroundProcess: Bool,
        context: DialogPresentationContext = .unscoped,
        deduplicationKey: DialogRequestKey? = nil,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil
    ) async -> Bool {
        guard hasForegroundProcess else { return true }
        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.terminalTabCloseWarning.runSheet(
                on: context,
                deduplicationKey: deduplicationKey,
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
        return response == .alertFirstButtonReturn
    }

    /// Convenience overload that checks the foreground-process predicate on
    /// a collection of terminal tabs before presenting the shared alert.
    ///
    /// - Parameters:
    ///   - tabs: The terminal tabs to inspect.
    ///   - context: Presentation context for the window-scoped sheet.
    ///   - presentAlert: Async closure that presents the confirmation alert.
    ///     Injected for testing; defaults to the standard sheet.
    /// - Returns: `true` if none of the tabs has a foreground process or the
    ///     user confirmed. `false` to abort.
    static func confirmTerminalProcessStop(
        tabs: [TerminalTab],
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil
    ) async -> Bool {
        // An agent tab is authorized by its stable session identity rather
        // than its volatile foreground pgid, so the normal child-process
        // churn of an AI agent cannot silently abort a confirmation (#1335).
        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: tabs)
        guard authorization.requiresConfirmation else { return true }
        guard await confirmTerminalStop(
            hasForegroundProcess: true,
            context: context,
            deduplicationKey: authorization.deduplicationKey,
            presentAlert: presentAlert
        ) else {
            return false
        }
        return authorization.stillCovers(tabs)
    }

    /// Resolves a presentation context for a terminal close/stop, resilient
    /// to a transiently-missing project owner (#1335 H3).
    ///
    /// `DialogPresenter.forProject` reads a weak project→window anchor that
    /// can be `nil` for a brief moment during SwiftUI scene restoration. A
    /// close captured at that instant would otherwise resolve to an unscoped
    /// context and silently abort. This resolves the project owner, falls
    /// back to the key project window, and retries once after a short
    /// main-queue hop so a transient miss does not lose the close gesture.
    static func terminalCloseContext(
        for projectManager: ProjectManager?
    ) async -> DialogPresentationContext {
        func resolve() -> DialogPresentationContext {
            guard let projectManager else { return .unscoped }
            let projectContext = DialogPresenter.forProject(projectManager)
            if projectContext.nsWindow != nil { return projectContext }
            let keyContext = DialogPresenter.forKeyProject()
            return keyContext.nsWindow != nil ? keyContext : projectContext
        }

        let first = resolve()
        if first.nsWindow != nil { return first }
        try? await Task.sleep(nanoseconds: 50_000_000)
        return resolve()
    }
}
