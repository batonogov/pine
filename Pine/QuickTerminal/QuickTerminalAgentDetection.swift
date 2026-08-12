//
//  QuickTerminalAgentDetection.swift
//  Pine
//
//  Snapshot-consuming agent detection for the application-wide Quick Terminal.
//  Snapshot capture is intentionally owned elsewhere so this seam can attach
//  to the application-level source introduced by #1421 without creating a
//  second ps timer.
//

import Foundation

/// Reconciles injected process snapshots against one keep-alive terminal
/// inventory. This type never captures processes or schedules polling.
@MainActor
final class QuickTerminalAgentDetection: AgentProcessSnapshotConsuming {
    let detector = AgentDetector()

    private weak var controller: QuickTerminalController?
    private var isFrozenForTermination = false
    #if DEBUG
    private(set) var receivedSnapshotCountForTesting = 0
    #endif

    init(controller: QuickTerminalController? = nil) {
        self.controller = controller
    }

    func bind(controller: QuickTerminalController) {
        self.controller = controller
    }

    func consumeAgentProcessSnapshot(
        _ processes: [DetectedProcess],
        observation: AgentObservationStamp
    ) {
        guard !isFrozenForTermination, let controller else { return }
        #if DEBUG
        receivedSnapshotCountForTesting += 1
        #endif
        let newlyTerminated = detector.processSnapshotDidUpdate(
            processes,
            observation: observation
        )
        for tab in controller.agentTerminalTabs {
            let previous = tab.agentSession
            let current = AgentDetectionCoordinator.reconciledSession(
                previous: previous,
                ownership: TerminalAgentOwnershipEvidence(
                    foreground: tab.foregroundProcessSnapshot(),
                    processes: processes
                ),
                detector: detector,
                agentIdentityStillMatches: {
                    tab.agentProcessIdentityStillMatches($0)
                },
                newlyTerminated: newlyTerminated
            )
            if let current {
                controller.bridgeQuickTerminalAgentSession(
                    current,
                    replacing: previous,
                    in: tab
                )
            }
            tab.agentSession = current
        }
        controller.refreshQuickTerminalAgentTasks(
            sessions: detector.detectedSessions
        )
    }

    func consumeAgentProcessSnapshotFailure(
        observation: AgentObservationStamp
    ) {
        guard !isFrozenForTermination, let controller else { return }
        #if DEBUG
        receivedSnapshotCountForTesting += 1
        #endif
        detector.processSnapshotDidFail(observation: observation)
        controller.refreshQuickTerminalAgentTasks(
            sessions: detector.detectedSessions
        )
        for tab in controller.agentTerminalTabs
        where AgentDetectionCoordinator.shouldExpireAfterFailedSnapshot(
            tab.agentSession
        ) {
            tab.agentSession = nil
        }
    }

    func freezeForTermination() {
        isFrozenForTermination = true
    }

    func cancelTermination() {
        isFrozenForTermination = false
    }

    func stop() {
        isFrozenForTermination = true
        guard let controller else { return }
        controller.markQuickTerminalAgentEvidenceUnavailable(
            sessionIDs: detector.detectedSessions.map(\.id)
        )
        controller.agentTerminalTabs.forEach { $0.agentSession = nil }
    }
}
