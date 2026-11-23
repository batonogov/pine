#if PINE_TEST_HOST
import AppKit
import SwiftUI

/// Test-host-only result window. Callbacks record UI intent in view state;
/// this fixture contains no executor, acceptance mutation, Git, or persistence.
@MainActor
private final class AgentTaskResultUITestWindow {
    static let shared = AgentTaskResultUITestWindow()
    private var window: NSWindow?

    func show(needsDecision: Bool) {
        let root = AgentTaskResultUITestRoot(needsDecision: needsDecision)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.identifier = NSUserInterfaceItemIdentifier("agentTaskResultUITest")
        window.title = "Task Result"
        window.setContentSize(NSSize(width: 800, height: 900))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
enum AgentTaskResultUITestLauncher {
    static func present(needsDecision: Bool) {
        AgentTaskResultUITestWindow.shared.show(needsDecision: needsDecision)
    }
}

@MainActor
private struct AgentTaskResultUITestRoot: View {
    @State private var launchRequests = 0
    @State private var reply: String?
    private let needsDecision: Bool

    init(needsDecision: Bool) {
        self.needsDecision = needsDecision
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentTaskResultView(
                model: Self.model(needsDecision: needsDecision),
                onLaunch: { launchRequests += 1 },
                onReply: { reply = $0 }
            )
            if launchRequests > 0 {
                Text("Launch requested")
                    .accessibilityIdentifier(AccessibilityID.agentTaskResultLaunchEvidence)
            }
            if let reply {
                Text(verbatim: reply)
                    .accessibilityIdentifier(AccessibilityID.agentTaskResultReplyEvidence)
            }
        }
    }

    private static func model(needsDecision: Bool) -> AgentTaskResultPresentation {
        let now = Date(timeIntervalSince1970: 1_000)
        let code = AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: String(repeating: "a", count: 64),
            untrackedFingerprint: String(repeating: "b", count: 64),
            ignoredRelevantFingerprint: String(repeating: "c", count: 64)
        )
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g", toolchain: "Xcode 27.0",
            configurationFingerprint: String(repeating: "d", count: 64)
        )
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/result-project",
                canonicalWorktreePath: "/tmp/result-task"
            ),
            route: AgentTaskRoute(
                paneID: UUID(), tabID: UUID(), terminalID: nil, availability: .missing
            ),
            origin: .discoveredInTerminal, observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .openCode),
            context: context, objective: "Provide a runnable example"
        )
        let runID = UUID()
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: runID, terminalID: nil,
            process: AgentProcessEvidence(
                processIdentifier: 42, processGeneration: 1, startIdentifier: "result-ui",
                observedStartedAt: now.addingTimeInterval(-10), startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: now)
        ))]
        task.evidence = [
            AgentTaskEvidenceFact(
                kind: .agentReportedCompletion, runID: runID, processGeneration: 1,
                trust: .verified, result: .reported, observedAt: now,
                codeState: code, environment: environment, sourceSequence: 1
            ),
            AgentTaskEvidenceFact(
                kind: .independentCheck, runID: runID, processGeneration: 1,
                trust: .verified, result: .succeeded, observedAt: now,
                codeState: code, environment: environment, sourceSequence: 2,
                preOperationCodeState: code, postOperationCodeState: code
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome, runID: runID, processGeneration: 1,
                trust: .verified, result: .succeeded, observedAt: now,
                codeState: code, environment: environment, sourceSequence: 3,
                preOperationCodeState: code, postOperationCodeState: code
            ),
        ]
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)

        let recipe = AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/Example/main.swift"],
            for: task.project
        )
        let selection = try? AgentProjectRecipe.select(projectCheckedIn: recipe, for: task.project)
        let snapshot = AgentVerificationIdentitySnapshot(code: code, environment: environment)
        let binding = selection.flatMap {
            AgentTaskResultActionBinding(
                task: task, selection: $0, actionID: "run-example", snapshot: snapshot
            )
        }
        let action = binding.map(AgentTaskResultActionState.init)
        let check = AgentTaskResultCheckEntry(
            result: AgentTaskCheckObservation.CommandResult(
                operationID: UUID(),
                fingerprint: String(repeating: "e", count: 64),
                required: true, status: .succeeded
            ),
            codeState: code, environment: environment, exitCode: 0
        )
        let changes = AgentRevisionChangeSummary(
            agentSummary: "Added a runnable example.",
            items: [AgentRevisionChangeItem(
                relativePath: "Sources/Example/main.swift", kind: .modified,
                attribution: .verified
            )]
        )
        if needsDecision {
            var cycle = AgentTaskCorrectionCycle(
                taskID: task.id, runID: runID, codeState: code, environment: environment,
                requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
                checkPlanIdentity: String(repeating: "f", count: 64),
                reviewerControl: .writeDisabledAtAdapter
            )
            cycle.stop(.checksFailed)
            task.reviewCycle = cycle
            task.verificationState = .stale
        }
        return AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, changes: changes,
            action: action, checkJournal: [check],
            limitations: ["The fixture records one required build check."]
        )
    }
}
#endif
