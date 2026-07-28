//
//  AgentActivityTerminalRouting.swift
//  Pine
//
//  Truthful, exact terminal ownership and navigation for Agent Activity.
//

import Foundation

/// One currently verified terminal destination for an Activity action.
///
/// Pane and tab identity are intentionally atomic: a tab UUID alone cannot
/// select the correct owner in a multi-pane layout. The session identity is
/// retained so activation can fail closed if agent detection reassigns the
/// tab between rendering the detail sheet and pressing "Go to Terminal".
struct AgentActivityTerminalTarget: Equatable, Sendable {
    let paneID: PaneID
    let tabID: UUID
    let sessionID: UUID
    let agentType: AgentType
    /// Process-evidence freshness captured with this exact session owner.
    let liveness: AgentLiveness
    let label: String
    let workingDirectory: URL?
}

/// Resolves an Activity attribution against live terminal ownership.
///
/// A destination exists only when one and exactly one terminal tab owns the
/// action's unambiguous session identity. Ambiguous attribution, a missing
/// session, an agent-type mismatch, and duplicate ownership all return `nil`
/// so the detail view cannot display a terminal label or navigation action it
/// cannot substantiate.
@MainActor
enum AgentActivityTerminalTargetResolver {
    static func resolve(
        attribution: AgentActionAttribution,
        in paneManager: PaneManager
    ) -> AgentActivityTerminalTarget? {
        guard let candidate = attribution.unambiguousCandidate else {
            return nil
        }

        var resolvedTarget: AgentActivityTerminalTarget?
        for paneID in paneManager.terminalPaneIDs {
            guard let state = paneManager.terminalState(for: paneID) else {
                continue
            }
            for tab in state.terminalTabs {
                guard let session = tab.agentSession,
                      session.id == candidate.sessionID,
                      session.agentType == candidate.agentType else {
                    continue
                }

                // Duplicate ownership is not a deterministic destination.
                guard resolvedTarget == nil else { return nil }
                let trimmedName = tab.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                resolvedTarget = AgentActivityTerminalTarget(
                    paneID: paneID,
                    tabID: tab.id,
                    sessionID: session.id,
                    agentType: session.agentType,
                    liveness: session.liveness,
                    label: trimmedName.isEmpty ? tab.stableLabel : trimmedName,
                    workingDirectory: tab.workingDirectoryURL
                )
            }
        }
        return resolvedTarget
    }
}

/// Activates a previously resolved target through PaneManager's canonical
/// selection API. Revalidating terminal/session ownership prevents a stale
/// detail sheet from routing to a tab now owned by another agent.
@MainActor
enum AgentActivityTerminalRouter {
    @discardableResult
    static func route(
        to target: AgentActivityTerminalTarget,
        paneManager: PaneManager,
        terminalManager: TerminalManager
    ) -> Bool {
        guard let state = paneManager.terminalState(for: target.paneID),
              let tab = state.terminalTabs.first(where: { $0.id == target.tabID }),
              let session = tab.agentSession,
              session.id == target.sessionID,
              session.agentType == target.agentType,
              paneManager.selectTerminalTab(target.tabID, in: target.paneID) else {
            return false
        }
        terminalManager.lastActiveTerminalPaneID = target.paneID
        return true
    }
}
