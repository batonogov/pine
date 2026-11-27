#if PINE_TEST_HOST
import AppKit
import SwiftUI

// MARK: - Revision-bound feedback and comparison fixture (#1758)

/// Test-host-only feedback window. It renders the composer and the
/// comparison from fixture presentation values; callbacks record intent in
/// view state, and nothing here reaches a registry, a session, or persistence.
@MainActor
private final class AgentFeedbackUITestWindow {
    static let shared = AgentFeedbackUITestWindow()
    private var window: NSWindow?

    func show() {
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: AgentFeedbackUITestRoot())
        )
        window.identifier = NSUserInterfaceItemIdentifier("agentFeedbackUITest")
        window.title = "Task Feedback"
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
enum AgentFeedbackUITestLauncher {
    static func present() {
        AgentFeedbackUITestWindow.shared.show()
    }
}

@MainActor
private struct AgentFeedbackUITestRoot: View {
    @State private var lastSend: String?

    var body: some View {
        VStack(spacing: 0) {
            // Evidence sits above the scroll area so a test never scrolls.
            if let lastSend {
                Text(verbatim: lastSend)
                    .accessibilityIdentifier(AccessibilityID.agentFeedbackSendEvidence)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AgentFeedbackComposerView(
                        model: Self.composer,
                        onSend: { lastSend = "full" },
                        onSendTextOnly: { lastSend = "text-only" }
                    )
                    Divider()
                    AgentRevisionComparisonView(model: Self.comparison)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One task holding the result the user commented on and a newer one.
    private static func taskFixture() -> (task: AgentTask, commented: AgentTaskResultSnapshot) {
        let now = Date()
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/feedback-project",
                canonicalWorktreePath: "/tmp/feedback-task"
            ),
            route: AgentTaskRoute(
                paneID: UUID(), tabID: UUID(), terminalID: nil, availability: .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .openCode),
            context: context,
            objective: "Provide a runnable example"
        )
        let runID = UUID()
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: runID,
            terminalID: nil,
            process: AgentProcessEvidence(
                processIdentifier: 44, processGeneration: 1, startIdentifier: "feedback-ui",
                observedStartedAt: now.addingTimeInterval(-20), startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: now)
        ))]
        let commented = Self.snapshot("a", runID: runID, recordedAt: now.addingTimeInterval(-10))
        task.reviewedSnapshot = Self.snapshot("d", runID: runID, recordedAt: now)
        let reference = AgentFeedbackReference(
            taskID: task.id,
            candidate: commented,
            artifactKind: .code,
            anchor: .lineRange(path: "Sources/Example/main.swift", start: 1, end: 12),
            userText: "Make the greeting shorter",
            createdAt: now.addingTimeInterval(-10)
        )
        var submission = AgentFeedbackSubmission(
            reference: reference, submittedAt: now.addingTimeInterval(-9)
        )
        _ = submission.apply(
            receipt: AgentFeedbackDeliveryReceipt(submissionID: submission.id)
        )
        _ = submission.noteAgentReportedAddressed()
        task.feedbackSubmissions = [AgentFeedbackSubmissionRecord(submission)]
        return (task, commented)
    }

    private static func snapshot(
        _ tag: Character, runID: UUID, recordedAt: Date
    ) -> AgentTaskResultSnapshot {
        AgentTaskResultSnapshot(
            runID: runID,
            outcome: .success,
            codeState: AgentTaskCodeStateIdentity(
                headCommit: String(repeating: "b", count: 40),
                trackedFingerprint: String(repeating: String(tag), count: 64),
                untrackedFingerprint: String(repeating: "b", count: 64),
                ignoredRelevantFingerprint: String(repeating: "c", count: 64)
            ),
            environment: AgentTaskEnvironmentIdentity(
                osBuild: "26A5388g",
                toolchain: "Xcode 27.0",
                configurationFingerprint: String(repeating: "d", count: 64)
            ),
            recordedAt: recordedAt
        )
    }

    /// A draft about the older result with one image the agent cannot take.
    private static var composer: AgentFeedbackComposerPresentation {
        let (task, commented) = taskFixture()
        let image = AgentFeedbackAttachment(
            id: UUID(),
            kind: .image,
            captureBasis: .livePreviewObservation,
            sha256: String(repeating: "7", count: 64),
            byteCount: 123_456,
            label: "preview capture"
        )
        return AgentFeedbackComposerPresentation(
            availability: .available,
            recipientName: "OpenCode",
            recipientIsReachable: true,
            candidate: commented,
            freshness: .current,
            anchorOptions: [
                AgentFeedbackComposerPresentation.AnchorOption(path: "", isMissing: false),
                AgentFeedbackComposerPresentation.AnchorOption(
                    path: "Sources/Example/main.swift", isMissing: false
                ),
            ],
            selectedAnchorPath: "",
            anchorResolution: .resolved,
            text: "Make the greeting shorter",
            attachments: [
                AgentFeedbackComposerPresentation.AttachmentNotice(
                    attachment: image, rejection: .unsupportedKind
                ),
            ],
            phase: .idle,
            failure: nil,
            history: [AgentFeedbackHistoryEntry(record: task.feedbackSubmissions[0], text: nil)]
        )
    }

    /// The same task as a comparison: two real revisions, no kept output.
    private static var comparison: AgentRevisionComparisonPresentation {
        let (task, _) = taskFixture()
        return AgentRevisionComparisonPresentation.build(
            task: task, captures: [], changes: [], live: [], selectedSubmissionID: nil
        )
    }
}

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
            action: action, preparation: preparation, checkJournal: [check],
            limitations: ["The fixture records one required build check."]
        )
    }
}
#endif
