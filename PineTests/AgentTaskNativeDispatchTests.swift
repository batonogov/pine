import Foundation
import Testing
@testable import Pine

/// Pure journal state-machine tests. Receipt-bearing transitions
/// (submissionAcknowledged/submissionResponseObserved) are exercised through
/// the registry and ownership in AgentTaskNativeAdmissionTests; this file
/// covers everything the journal validates without a runtime receipt.
@MainActor
struct AgentTaskNativeDispatchTests {
    private let taskID = UUID()
    private let runID = UUID()

    private func makeTask(
        id: UUID? = nil,
        route: AgentTaskRoute? = nil,
        vendorIdentity: AgentVendorSessionIdentity? = nil
    ) -> AgentTask {
        let theRoute = route ?? AgentTaskRoute(ownedProcessAvailability: .missing)
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(canonicalProjectPath: "/tmp/pine-native", canonicalWorktreePath: "/tmp/pine-native"),
            route: theRoute,
            origin: .pineLaunched
        )
        var task = AgentTask(descriptor: AgentDescriptor(agentType: .codex), context: context)
        if let vendorIdentity {
            task.runs.append(Self.makeRun(id: runID, vendorIdentity: vendorIdentity))
        }
        return Self.rewriteID(task, to: id ?? taskID)
    }

    /// `AgentTask.id` is fixed at init; the durable schema is the rewrite path.
    private static func rewriteID(_ task: AgentTask, to id: UUID) -> AgentTask {
        do {
            let data = try JSONEncoder().encode(task)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            json?["id"] = id.uuidString
            let rewritten = try JSONSerialization.data(withJSONObject: json ?? [:])
            return try JSONDecoder().decode(AgentTask.self, from: rewritten)
        } catch {
            preconditionFailure("Test fixture rewrite failed: \(error)")
        }
    }

    private static func makeRun(
        id: UUID,
        vendorIdentity: AgentVendorSessionIdentity?
    ) -> AgentTaskRun {
        var run = AgentTaskRun(AgentTaskRunInput(
            id: id,
            terminalID: nil,
            process: AgentProcessEvidence(
                processIdentifier: nil,
                processGeneration: 1,
                startIdentifier: nil,
                observedStartedAt: Date()
            ),
            status: AgentTaskRunStatus(state: .idle, liveness: .live, observedAt: Date())
        ))
        run.vendorIdentity = vendorIdentity
        return run
    }

    private func freshJournal() -> AgentTaskNativeDispatch {
        AgentTaskNativeDispatch(taskID: taskID, runID: runID)
    }

    /// The registry's own launch-intent publication: a direct checkpoint
    /// assignment, not a transition.
    private func launchedJournal(bindingID: UUID = UUID()) -> AgentTaskNativeDispatch {
        var journal = freshJournal()
        journal.bindingID = bindingID
        journal.phase = .launchIntent
        return journal
    }

    @Test func reservedJournalValidatesOnlyItsExactOwnedProcessTask() throws {
        let journal = freshJournal()
        let taskID = journal.taskID
        let task = makeTask(id: taskID)
        // Owned-process routes carry no terminal identity.
        #expect(task.route.paneID == nil && task.route.tabID == nil && task.route.terminalID == nil)
        #expect(journal.isValid(for: task))
        #expect(!journal.isValid(for: makeTask(id: UUID())))
        #expect(!journal.isValid(for: makeTask(id: taskID, route: AgentTaskRoute(
            surface: .projectWindow, paneID: UUID(), tabID: UUID(), terminalID: UUID()))))
    }

    @Test func launchIntentBindsTheBindingAndRefusesFurtherIntents() throws {
        let journal = freshJournal()
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")))
        }
        let launched = launchedJournal()
        #expect(launched.phase == .launchIntent)
        #expect(launched.bindingID != nil)
        #expect(launched.isValid(for: makeTask()))
        // The intent is the registry's to publish; the journal never
        // re-enters it from another phase.
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try launched.applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")))
                .applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_2")))
        }
    }

    @Test func happyPathStopsAtAcknowledgementWithoutARuntimeReceipt() throws {
        let identity = AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1", executableVersion: "codex-cli 0.169.0")
        var journal = launchedJournal()
        journal = try journal.applying(.sessionBound(identity))
        #expect(journal.conversation == identity)
        #expect(journal.phase == .sessionBound)
        journal = try journal.applying(.initialInputIntent)
        #expect(journal.phase == .inputIntent)
        #expect(journal.submissions.count == 1 && journal.submissions[0].afterResponseTo == nil)
        journal = try journal.applying(.initialInputAcknowledged(operationID: "turn_1"))
        #expect(journal.phase == .inputAcknowledged)
        #expect(journal.operationID == "turn_1")
        #expect(journal.submissions[0].phase == .acknowledged)
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.initialInputIntent)
        }
    }

    @Test func cancellationStaysRequestedUntilConfirmed() throws {
        var journal = try launchedJournal()
            .applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")))
            .applying(.initialInputIntent)
            .applying(.initialInputAcknowledged(operationID: "turn_1"))
        #expect(!journal.cancellationRequested)
        journal = try journal.applying(.cancellationRequested)
        #expect(journal.cancellationRequested)
        #expect(journal.phase == .inputAcknowledged)
        // Requested is not confirmed: duplicate request is rejected.
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.cancellationRequested)
        }
        journal = try journal.applying(.cancellationConfirmed)
        #expect(journal.phase == .cancellationConfirmed)
        // Confirmation is idempotent, re-requesting after confirmation is not.
        journal = try journal.applying(.cancellationConfirmed)
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.cancellationRequested)
        }
    }

    @Test func unknownSubmissionIsIdempotentAndNeverRetried() throws {
        var journal = try launchedJournal()
            .applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")))
            .applying(.initialInputIntent)
        let firstID = journal.submissions[0].id
        journal = try journal.applying(.submissionUnknown(submissionID: firstID))
        #expect(journal.phase == .inputUnknown)
        #expect(journal.submissions[0].phase == .unknown)
        let unknown = try journal.applying(.submissionUnknown(submissionID: firstID))
        #expect(journal == unknown)
        // A lost intent is never retried as a fresh follow-up or new initial.
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.initialInputIntent)
        }
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.followupInputIntent(submissionID: UUID(), afterResponseTo: firstID))
        }
    }

    @Test func parentSettlementIsTheOnlyFollowupGate() throws {
        let identity = AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")
        var journal = try launchedJournal()
            .applying(.sessionBound(identity))
            .applying(.initialInputIntent)
        let firstID = journal.submissions[0].id
        journal = try journal.applying(.initialInputAcknowledged(operationID: "turn_1"))
        // Acknowledgement alone does not open the next input.
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try journal.applying(.followupInputIntent(submissionID: UUID(), afterResponseTo: firstID))
        }
        // The response observation (receipt-bearing in production) moves the
        // phase; model the settled state the journal admits it in.
        var settled = journal
        settled.phase = .parentSettlementUnknown
        settled.submissions[0].phase = .responseObserved
        #expect(settled.isValid(for: makeTask(vendorIdentity: identity)))
        let followup = try settled.applying(.followupInputIntent(submissionID: UUID(), afterResponseTo: firstID))
        #expect(followup.phase == .inputIntent)
        #expect(followup.submissions.count == 2)
        #expect(followup.submissions[1].afterResponseTo == firstID)
        #expect(followup.operationID == nil)
        // A terminal phase forbids further input entirely.
        let failed = try settled.applying(.operationFailed)
        #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            _ = try failed.applying(.followupInputIntent(submissionID: UUID(), afterResponseTo: firstID))
        }
    }

    @Test func stampedRunMustCarryTheExactVendorIdentity() throws {
        let identity = AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")
        let journal = try launchedJournal()
            .applying(.sessionBound(identity))
        let taskID = journal.taskID
        #expect(!journal.isValid(for: makeTask(id: taskID)))
        #expect(journal.isValid(for: makeTask(id: taskID, vendorIdentity: identity)))
        #expect(!journal.isValid(for: makeTask(
            id: taskID,
            vendorIdentity: AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_other")
        )))
        #expect(!journal.isValid(for: makeTask(
            id: taskID,
            vendorIdentity: AgentVendorSessionIdentity(provider: "other", opaqueIdentifier: "thr_1")
        )))
    }

    @Test func unavailableIsTerminalForEveryPhase() throws {
        let journal = freshJournal()
        #expect(try journal.applying(.unavailable).phase == .unavailable)
        var journal2 = launchedJournal()
        #expect(try journal2.applying(.unavailable).phase == .unavailable)
        journal2 = try journal2.applying(.sessionBound(AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_1")))
        #expect(try journal2.applying(.unavailable).phase == .unavailable)
    }

    @Test func journalRoundTripsAndRedacts() throws {
        let identity = AgentVendorSessionIdentity(provider: "codex", opaqueIdentifier: "thr_secret", executableVersion: "codex-cli 0.169.0")
        var journal = try launchedJournal()
            .applying(.sessionBound(identity))
            .applying(.initialInputIntent)
            .applying(.initialInputAcknowledged(operationID: "turn_secret"))
        let data = try JSONEncoder().encode(journal)
        let decoded = try JSONDecoder().decode(AgentTaskNativeDispatch.self, from: data)
        #expect(decoded.taskID == journal.taskID)
        #expect(decoded == journal)
        // Durable bytes carry the exact references; diagnostics redact them.
        var diagnostic = ""
        dump(journal, to: &diagnostic)
        #expect(!diagnostic.contains("thr_secret"))
        #expect(!diagnostic.contains("turn_secret"))
        #expect(journal.description == "<redacted:native-dispatch>")
        #expect(journal.debugDescription.contains("redacted"))
    }
}
