import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Pine

@MainActor
@Suite("Ready result presentation", .serialized)
struct AgentTaskResultPresentationTests {
    private let code = ADEContractFixtures.codeState("a")
    private let environment = ADEContractFixtures.environment

    @Test func nativeSettledTaskIsReachableFromExistingInbox() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1735, codeState: code, environment: environment
        )
        task.route = AgentTaskRoute(ownedProcessAvailability: .missing)
        let row = try #require(AgentInboxSnapshot(tasks: [task]).rows.first)
        #expect(row.canOpenResult)
        #expect(!row.canNavigateToLiveRun)
    }

    @Test func realInboxReturnActivationOpensSelectedResult() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1738, codeState: code, environment: environment
        )
        task.route = AgentTaskRoute(ownedProcessAvailability: .missing)
        let tasks = AgentTaskRegistry()
        tasks.setTasksForTesting([task])
        let view = AgentInboxView(registry: ProjectRegistry(agentTasks: tasks))
        #expect(tasks.task(for: task.id)?.isUnread == true)

        // The Return handler delegates here after resolving its focused selection.
        view.activateSelection(taskID: task.id)

        // Opening a result, unlike navigating or recovering it, marks it viewed
        // and creates the controller that the sheet presents.
        #expect(tasks.task(for: task.id)?.isUnread == false)
        #expect(view.resultStore.taskID == task.id)
        #expect(view.resultStore.controllers[task.id]?.presentation.taskID == task.id)
    }

    @Test func returnKeyPresentsActualResultSheet() async throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1739, codeState: code, environment: environment
        )
        task.route = AgentTaskRoute(ownedProcessAvailability: .missing)
        let tasks = AgentTaskRegistry()
        tasks.setTasksForTesting([task])
        let view = AgentInboxView(registry: ProjectRegistry(agentTasks: tasks))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 540)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let previousKeyWindow = NSApp.keyWindow
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hosting)
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))

        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }

        try #require(await waitUntilMainActor {
            view.resultStore.taskID == task.id && !window.sheets.isEmpty
        })
        let sheet = try #require(window.sheets.first)
        let content = try #require(sheet.contentView)
        AccessibilityTreeProbe.awaken()
        #expect(AccessibilityTreeProbe.element(
            under: content, identifier: AccessibilityID.agentTaskResult
        ) != nil)
    }

    @Test func readySectionsKeepTheirRequiredOrder() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1725, codeState: code, environment: environment
        )
        let model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        #expect(model.readiness.isReady)
        #expect(AgentTaskResultPresentation.sectionOrder == [
            .outcome, .tryResult, .evidence, .changesSinceReview, .commandContext,
        ])
        #expect(model.snapshotChanges.map(\.status) == [.unchanged, .notRecorded])
    }

    @Test func everyGapMapsToItsActionableBoundary() {
        let expectations: [(AgentTaskReadinessGap, AgentTaskResultGapAction)] = [
            (.attemptInProgress, .working),
            (.noSettledAttempt, .continueAttempt),
            (.unverifiedOutcome, .unverified),
            (.failedAttempt, .continueAttempt),
            (.cancelledAttempt, .continueAttempt),
            (.supersededAttempt, .continueAttempt),
            (.verificationNotCurrent, .reverify),
            (.missingEvidence(.independentCheck), .repeatEvidence(.independentCheck)),
            (.failingEvidence(.reviewerOutcome), .repeatEvidence(.reviewerOutcome)),
            (.staleEvidence(.independentCheck), .repeatEvidence(.independentCheck)),
            (.codeStateUnknown, .failClosed),
            (.environmentUnknown, .failClosed),
            (.environmentChanged, .failClosed),
        ]
        for (gap, action) in expectations {
            #expect(AgentTaskResultPresentation.action(for: gap) == action)
        }
    }

    @Test func snapshotsHighlightDivergenceAndUnknownInsteadOfInheriting() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1726, codeState: code, environment: environment
        )
        let reviewed = try #require(task.reviewedSnapshot)
        task.acceptedSnapshot = AgentTaskResultSnapshot(
            runID: reviewed.runID, outcome: .success, codeState: code,
            environment: environment, recordedAt: reviewed.recordedAt
        )
        task.acceptanceState = .accepted

        let unchanged = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        #expect(unchanged.snapshotChanges.map(\.status) == [.unchanged, .unchanged])
        #expect(unchanged.acceptanceState == .accepted)

        let changed = AgentTaskResultPresentation(
            task: task, codeState: ADEContractFixtures.codeState("b"),
            environment: environment
        )
        #expect(changed.snapshotChanges.map(\.status) == [.diverged, .diverged])
        #expect(!changed.readiness.isReady)
        #expect(changed.acceptanceState == .accepted) // recorded dimension, not projection

        let unknown = AgentTaskResultPresentation(
            task: task, codeState: nil, environment: nil
        )
        #expect(unknown.snapshotChanges.map(\.status) == [.unknown, .unknown])
    }

    @Test func actionCannotCrossTaskOrCandidateIdentity() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1729, codeState: code, environment: environment
        )
        let snapshot = AgentVerificationIdentitySnapshot(code: code, environment: environment)
        let foreign = AgentTaskResultActionState(binding: AgentTaskResultActionBinding(
            taskID: UUID(), project: task.project, recipeFingerprint: String(repeating: "a", count: 64),
            resultActionID: "run", output: .cli, snapshot: snapshot
        ))
        let foreignModel = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, action: foreign,
            lastOutcome: UserTaskOutcome(
                taskID: "foreign", stdout: "foreign", stderr: "", exitCode: 0, timedOut: false
            )
        )
        #expect(foreignModel.action == nil)
        #expect(foreignModel.lastOutcome == nil)

        let bound = AgentTaskResultActionState(binding: AgentTaskResultActionBinding(
            taskID: task.id, project: task.project, recipeFingerprint: String(repeating: "a", count: 64),
            resultActionID: "run", output: .cli, snapshot: snapshot
        ))
        let current = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, action: bound
        )
        #expect(current.actionMatchesCurrentCandidate)
        let changed = AgentTaskResultPresentation(
            task: task, codeState: ADEContractFixtures.codeState("b"),
            environment: environment, action: bound
        )
        #expect(!changed.actionMatchesCurrentCandidate)
    }

    @Test func needsDecisionCarriesConcreteBlockerAndPreservedCandidate() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1727, codeState: code, environment: environment
        )
        let run = try #require(task.runs.last)
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id, runID: run.id, codeState: code, environment: environment,
            requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
            checkPlanIdentity: String(repeating: "a", count: 64),
            reviewerControl: .writeDisabledAtAdapter
        )
        cycle.stop(.checksFailed)
        task.reviewCycle = cycle

        let model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        #expect(model.needsDecision)
        #expect(model.decision?.blocker == .checksFailed)
        #expect(model.decision?.candidateCodeState == code)
        #expect(model.decision?.candidateEnvironment == environment)
    }

    @Test func staleDecisionCannotBeAnswered() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1730, codeState: code, environment: environment
        )
        let run = try #require(task.runs.last)
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id, runID: run.id, codeState: code, environment: environment,
            requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
            checkPlanIdentity: String(repeating: "a", count: 64),
            reviewerControl: .writeDisabledAtAdapter
        )
        cycle.stop(.checksFailed)
        task.reviewCycle = cycle

        let current = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        #expect(current.canReplyToDecision)
        let stale = AgentTaskResultPresentation(
            task: task, codeState: ADEContractFixtures.codeState("b"), environment: environment
        )
        #expect(stale.hasStaleDecision)
        #expect(stale.decision == nil)
        #expect(!stale.canReplyToDecision)
    }

    @Test func reviewerEvidenceMustMatchCurrentIdentityAndOperationFingerprints() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1731, codeState: code, environment: environment
        )
        let current = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        #expect(current.reviewerOutcomeIsCurrent)
        #expect(current.reviewerOutcome?.result == .succeeded)

        let historical = AgentTaskResultPresentation(
            task: task, codeState: ADEContractFixtures.codeState("b"), environment: environment
        )
        #expect(!historical.reviewerOutcomeIsCurrent)
        #expect(historical.reviewerOutcome?.codeState == code)
    }

    @Test func reviewerEvidenceRejectsEachMismatchedIdentityDimension() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1737, codeState: code, environment: environment
        )
        let run = try #require(task.runs.last)
        let review = try #require(task.evidence.last)
        let otherCode = ADEContractFixtures.codeState("b")
        let otherEnvironment = AgentTaskEnvironmentIdentity(
            osBuild: "other", toolchain: "other",
            configurationFingerprint: ADEContractFixtures.hex("e")
        )
        let cases: [String: AgentTaskEvidenceFact] = [
            "code": ADEContractFixtures.fact(
                .reviewerOutcome, runID: run.id, generation: review.processGeneration,
                result: .succeeded, at: review.observedAt.addingTimeInterval(1),
                codeState: otherCode, environment: environment,
                sequence: review.sourceSequence, pre: otherCode, post: otherCode
            ),
            "environment": ADEContractFixtures.fact(
                .reviewerOutcome, runID: run.id, generation: review.processGeneration,
                result: .succeeded, at: review.observedAt.addingTimeInterval(1),
                codeState: code, environment: otherEnvironment,
                sequence: review.sourceSequence, pre: code, post: code
            ),
            "pre-operation": ADEContractFixtures.fact(
                .reviewerOutcome, runID: run.id, generation: review.processGeneration,
                result: .succeeded, at: review.observedAt.addingTimeInterval(1),
                codeState: code, environment: environment,
                sequence: review.sourceSequence, pre: otherCode, post: code
            ),
            "post-operation": ADEContractFixtures.fact(
                .reviewerOutcome, runID: run.id, generation: review.processGeneration,
                result: .succeeded, at: review.observedAt.addingTimeInterval(1),
                codeState: code, environment: environment,
                sequence: review.sourceSequence, pre: code, post: otherCode
            ),
        ]
        for (name, mismatch) in cases {
            var candidate = task
            candidate.evidence.removeLast()
            candidate.evidence.append(mismatch)
            let model = AgentTaskResultPresentation(
                task: candidate, codeState: code, environment: environment
            )
            #expect(!model.reviewerOutcomeIsCurrent, "Mismatch: \(name)")
            #expect(model.reviewerOutcome == mismatch, "Mismatch: \(name)")
        }
    }

    @Test func accessibilityRetainsCompleteEvidenceAndOutput() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1732, codeState: code, environment: environment
        )
        let snapshot = AgentVerificationIdentitySnapshot(code: code, environment: environment)
        let action = AgentTaskResultActionState(binding: AgentTaskResultActionBinding(
            taskID: task.id, project: task.project, recipeFingerprint: String(repeating: "a", count: 64),
            resultActionID: "run", output: .cli, snapshot: snapshot
        ))
        let model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, action: action,
            lastOutcome: UserTaskOutcome(
                taskID: "run", stdout: "complete bounded output", stderr: "",
                exitCode: 0, timedOut: false
            )
        )
        let hosted = AccessibilityTreeProbe.host(
            AgentTaskResultView(model: model), size: NSSize(width: 760, height: 900)
        )
        defer { hosted.tearDown() }
        let labels = AccessibilityTreeProbe.labels(under: hosted.root).joined(separator: "\n")
        #expect(labels.contains("complete bounded output"))
        #expect(labels.contains(code.trackedFingerprint))
        #expect(labels.contains(environment.configurationFingerprint ?? ""))
    }

    @Test func preparationIsRequiredBeforeLaunchAndTracksRunningState() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1736, codeState: code, environment: environment
        )
        let recipe = try #require(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/Example/main.swift"], for: task.project
        ))
        let selection = try AgentProjectRecipe.select(projectCheckedIn: recipe, for: task.project)
        let snapshot = AgentVerificationIdentitySnapshot(code: code, environment: environment)
        let binding = try #require(AgentTaskResultActionBinding(
            task: task, selection: selection, actionID: "run-example", snapshot: snapshot
        ))
        var preparation = AgentProjectPreparation(recipe: recipe)
        var model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment,
            action: AgentTaskResultActionState(binding: binding), preparation: preparation
        )
        #expect(!model.canLaunchAction)
        #expect(!model.preparationIsRunning)
        let missingPreparation = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, action: model.action
        )
        #expect(!missingPreparation.canLaunchAction)
        model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment,
            action: model.action, preparation: preparation, preparationIsRunning: true
        )
        #expect(model.preparationIsRunning)
        for prerequisite in preparation.prerequisiteNames {
            preparation = preparation.reduced(by: .prerequisiteResolved(prerequisite))
        }
        for action in preparation.setupActionIDs {
            preparation = preparation.reduced(by: .setupSucceeded(action))
        }
        model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment,
            action: model.action, preparation: preparation
        )
        #expect(model.canLaunchAction)
    }

    @Test func unsupportedOutputHasExplanationButNoLaunchControl() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1733, codeState: code, environment: environment
        )
        let snapshot = AgentVerificationIdentitySnapshot(code: code, environment: environment)
        let action = AgentTaskResultActionState(binding: AgentTaskResultActionBinding(
            taskID: task.id, project: task.project, recipeFingerprint: String(repeating: "a", count: 64),
            resultActionID: "preview", output: .server(host: "127.0.0.1", port: 8080),
            snapshot: snapshot
        ))
        let model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment, action: action
        )
        let hosted = AccessibilityTreeProbe.host(
            AgentTaskResultView(model: model, onLaunch: {}),
            size: NSSize(width: 760, height: 900)
        )
        defer { hosted.tearDown() }
        #expect(!model.actionSupportsExecution)
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentTaskResultPrimaryAction
        ) == nil)
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentTaskResultUnsupported
        ) != nil)
    }

    @Test func openingAndHostingNeverLaunchOrAccept() throws {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1728, codeState: code, environment: environment
        )
        task.objective = "Run the example"
        let before = task
        var launches = 0
        var replies = 0
        let model = AgentTaskResultPresentation(
            task: task, codeState: code, environment: environment
        )
        let hosted = NSHostingView(rootView: AgentTaskResultView(
            model: model,
            onLaunch: { launches += 1 },
            onReply: { _ in replies += 1 }
        ))
        hosted.frame = NSRect(x: 0, y: 0, width: 720, height: 800)
        hosted.layoutSubtreeIfNeeded()

        #expect(launches == 0)
        #expect(replies == 0)
        #expect(task == before)
        #expect(model.acceptanceState == .notAccepted)
        #expect(model.lastOutcome == nil)
    }

    @Test func checkJournalShowsFingerprintRequirementExitAndEnvironment() {
        let result = AgentTaskCheckObservation.CommandResult(
            operationID: UUID(),
            fingerprint: String(repeating: "a", count: 64),
            required: true, status: .failed
        )
        let entry = AgentTaskResultCheckEntry(
            result: result, codeState: code, environment: environment, exitCode: 17
        )
        #expect(entry.commandFingerprint == result.fingerprint)
        #expect(entry.required)
        #expect(entry.status == .failed)
        #expect(entry.exitCode == 17)
        #expect(entry.codeState == code)
        #expect(entry.environment == environment)
    }

    @Test func resultCopyHasAnEntryForEveryLocale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Pine/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let locales = Set(["de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"])
        for value in Strings.AgentResultCopy.allCases {
            let entry = try #require(strings["agentResult.\(value.rawValue)"] as? [String: Any])
            let translations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(translations.keys) == locales)
        }
    }
}
