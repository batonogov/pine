//
//  AgentInboxHostRouting.swift
//  Pine
//
//  Deterministic host selection for the application-level Agent Inbox (#1491).
//

import Foundation

/// AppKit-free projection of one window that could own the application-level
/// Agent Inbox popover.
///
/// This mirrors `NativeCommandRoutingCandidate`: keeping the identity rule
/// pure is what makes multi-window Inbox routing verifiable without mutating
/// `NSApplication.shared.windows`.
struct AgentInboxHostCandidate: Equatable {
    enum Kind: Equatable {
        /// A project window, addressed through its `CloseDelegate`.
        case project
        /// The singleton Welcome window.
        case welcome
    }

    let kind: Kind
    /// True when this window is currently the application's key window.
    let isKeyWindow: Bool
    /// Closing, hidden, or unregistered windows can still sit in
    /// `NSApp.windows`. They must never receive a newly delivered request.
    let isEligibleWindow: Bool
    /// True for the project window showing the most recently activated
    /// project session. It becomes the destination when an auxiliary window
    /// — Settings, About, a panel — holds key and cannot host the Inbox.
    let showsMostRecentlyActiveProject: Bool

    init(
        kind: Kind,
        isKeyWindow: Bool,
        isEligibleWindow: Bool = true,
        showsMostRecentlyActiveProject: Bool = false
    ) {
        self.kind = kind
        self.isKeyWindow = isKeyWindow
        self.isEligibleWindow = isEligibleWindow
        self.showsMostRecentlyActiveProject = showsMostRecentlyActiveProject
    }
}

/// The single ordering rule that decides which window owns one Agent Inbox
/// request. Exactly one candidate wins, so a request can never fan out into
/// more than one window.
enum AgentInboxHostRouting {
    enum Decision: Equatable {
        /// Route the request into the candidate at this index.
        case existingHost(index: Int)
        /// No existing window may host the Inbox; Welcome has to be created
        /// so the popover still has a stable, discoverable anchor (#1486).
        case createWelcomeHost
    }

    /// Preference order, highest first:
    ///
    /// 1. the key project window — the user's current working context;
    /// 2. the key Welcome window — chosen only when no project is eligible;
    /// 3. the project window showing the most recently active project — the
    ///    destination when an auxiliary window such as Settings holds key;
    /// 4. any eligible Welcome window — the final existing-window fallback.
    static func decision(
        among candidates: [AgentInboxHostCandidate]
    ) -> Decision {
        let preferences: [(AgentInboxHostCandidate) -> Bool] = [
            { $0.kind == .project && $0.isKeyWindow },
            { $0.kind == .welcome && $0.isKeyWindow },
            { $0.kind == .project && $0.showsMostRecentlyActiveProject },
            { $0.kind == .welcome },
        ]
        for preference in preferences {
            let index = candidates.firstIndex {
                $0.isEligibleWindow && preference($0)
            }
            if let index {
                return .existingHost(index: index)
            }
        }
        return .createWelcomeHost
    }
}
