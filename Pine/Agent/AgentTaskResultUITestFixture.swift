#if PINE_TEST_HOST
import AppKit
import SwiftUI

/// One result-window fixture per test-host launch argument.
@MainActor
enum AgentTaskResultUITestFixture: String, CaseIterable {
    /// Ready with a selected, prepared result action.
    case ready = "--ui-test-agent-result"
    /// Ready as the production controller presents it on first open: the
    /// identity is proven, no result action has been chosen.
    case readyFirstOpen = "--ui-test-agent-result-first-open"
    case needsDecision = "--ui-test-agent-result-decision"
    /// A decision request that belongs to an earlier result.
    case staleDecision = "--ui-test-agent-result-decision-stale"

    var needsDecision: Bool { self == .needsDecision || self == .staleDecision }

    static func matching(_ arguments: [String]) -> Self? {
        allCases.first { arguments.contains($0.rawValue) }
    }
}

/// Test-host-only result window. Callbacks record UI intent in view state;
/// this fixture contains no executor, acceptance mutation, Git, or persistence.
@MainActor
private final class AgentTaskResultUITestWindow {
    static let shared = AgentTaskResultUITestWindow()
    private var window: NSWindow?

    func show(fixture: AgentTaskResultUITestFixture) {
        let root = AgentTaskResultUITestRoot(fixture: fixture)
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
    static func present(_ fixture: AgentTaskResultUITestFixture) {
        AgentTaskResultUITestWindow.shared.show(fixture: fixture)
    }
}

@MainActor
private struct AgentTaskResultUITestRoot: View {
    @State private var launchRequests = 0
    @State private var reply: String?
    private let fixture: AgentTaskResultUITestFixture

    init(fixture: AgentTaskResultUITestFixture) {
        self.fixture = fixture
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentTaskResultView(
                model: Self.model(fixture),
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

    private static func model(_ fixture: AgentTaskResultUITestFixture) -> AgentTaskResultPresentation {
        let now = Date(timeIntervalSince1970: 1_000)
        func identity(_ tracked: Character) -> AgentTaskCodeStateIdentity {
            AgentTaskCodeStateIdentity(
                headCommit: String(repeating: "b", count: 40),
                trackedFingerprint: String(repeating: tracked, count: 64),
                untrackedFingerprint: String(repeating: "b", count: 64),
                ignoredRelevantFingerprint: String(repeating: "c", count: 64)
            )
        }
        let code = identity("a")
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
        task.checkExecution = AgentTaskCheckExecution(
            id: UUID(), runID: runID, processGeneration: 1, passID: UUID(), attempt: 1,
            grantID: UUID(), planFingerprint: String(repeating: "e", count: 64),
            requiredCommands: [String(repeating: "f", count: 64)],
            code: code, environment: environment,
            operations: [.init(
                id: UUID(), commandFingerprint: String(repeating: "f", count: 64),
                required: true, startedAt: now, finishedAt: now,
                status: .succeeded, exitCode: 0, identitiesMatched: true
            )]
        )
        let changes = AgentRevisionChangeSummary(
            agentSummary: "Added a runnable example.",
            items: [AgentRevisionChangeItem(
                relativePath: "Sources/Example/main.swift", kind: .modified,
                attribution: .verified
            )]
        )
        if fixture.needsDecision {
            var cycle = AgentTaskCorrectionCycle(
                taskID: task.id, runID: runID, codeState: code, environment: environment,
                requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
                checkPlanIdentity: String(repeating: "e", count: 64),
                reviewerControl: .writeDisabledAtAdapter
            )
            cycle.recordRejectedReference(String(repeating: "9", count: 64))
            cycle.stop(.checksFailed)
            task.reviewCycle = cycle
            task.verificationState = .stale
        }
        if fixture == .readyFirstOpen {
            return AgentTaskResultPresentation(
                task: task, codeState: code, environment: environment, changes: changes
            )
        }
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
        // A Ready result is launchable only behind a current, usable
        // preparation (AgentTaskResultPresentation.canLaunchAction). Drive
        // the fixture's one to `.usable` so the explicit-launch UI is
        // exercised; without it the primary action renders disabled and the
        // keyboard/focus tests fail on every OS.
        let preparation: AgentProjectPreparation? = selection.map { selected in
            var prep = AgentProjectPreparation(recipe: selected.recipe)
            for name in prep.prerequisiteNames {
                prep = prep.reduced(by: .prerequisiteResolved(name))
            }
            for id in prep.setupActionIDs {
                prep = prep.reduced(by: .setupSucceeded(id))
            }
            return prep
        }
        return AgentTaskResultPresentation(
            task: task,
            // The stale fixture proves another identity than the one the
            // decision request was raised against.
            codeState: fixture == .staleDecision ? identity("5") : code,
            environment: environment, changes: changes,
            action: action, preparation: preparation,
            findingText: fixture.needsDecision
                ? "The example exits with code 1 when it is run without arguments." : nil
        )
    }
}
#endif
