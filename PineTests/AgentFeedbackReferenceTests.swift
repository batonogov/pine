//
//  AgentFeedbackReferenceTests.swift
//  PineTests
//
//  Revision-bound feedback reference model (#1758): candidate binding,
//  freshness classification, anchors, attachments, the text-only path, and
//  the content fingerprint.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Revision-bound feedback reference model", .serialized)
struct AgentFeedbackReferenceTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012X", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("c")
        )
    }

    private func candidate(
        run: UUID,
        outcome: AgentTaskOutcome = .success,
        code: AgentTaskCodeStateIdentity,
        recorded: Double
    ) -> AgentTaskResultSnapshot {
        AgentTaskResultSnapshot(
            runID: run,
            outcome: outcome,
            codeState: code,
            environment: environment,
            recordedAt: date(recorded)
        )
    }

    private func image(
        _ seed: Int,
        sha: String,
        basis: AgentFeedbackCaptureBasis = .immutableCapture
    ) -> AgentFeedbackAttachment {
        AgentFeedbackAttachment(
            id: uuid(seed),
            kind: .image,
            captureBasis: basis,
            sha256: sha,
            byteCount: 12_345,
            label: "preview capture"
        )
    }

    private func visualReference(
        candidate: AgentTaskResultSnapshot,
        createdAt: Double = 150
    ) -> AgentFeedbackReference {
        AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidate,
            artifactKind: .visualPreview,
            anchor: .capturedRegion(x: 4, y: 8, width: 200, height: 100),
            userText: "Make this header easier to read",
            attachments: [image(50, sha: hex("7"), basis: .livePreviewObservation)],
            createdAt: date(createdAt)
        )
    }

    @MainActor
    private func makeTask(runIDs: [UUID]) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/pine-feedback",
                canonicalWorktreePath: "/tmp/pine-feedback"
            ),
            route: AgentTaskRoute(
                paneID: uuid(1),
                tabID: uuid(2),
                terminalID: uuid(2)
            ),
            origin: .discoveredInTerminal,
            observedAt: date(180)
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = runIDs.enumerated().map { index, runID in
            AgentTaskRun(AgentTaskRunInput(
                id: runID,
                terminalID: uuid(2),
                process: AgentProcessEvidence(
                    processIdentifier: Int32(1_000 + index),
                    processGeneration: UInt64(index + 1),
                    startIdentifier: "run-\(index)",
                    observedStartedAt: date(100 + Double(index) * 30),
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done,
                    liveness: .terminated,
                    observedAt: date(120 + Double(index) * 50)
                )
            ))
        }
        task.updatedAt = date(200)
        task.lastActivityAt = date(200)
        return task
    }

    // MARK: - Acceptance 1 + 2: binding, identity, relaunch

    @Test("Reference retains the exact viewed candidate across a relaunch round trip")
    func referenceSurvivesRelaunch() throws {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let reference = visualReference(candidate: candidateA)
        #expect(reference.isValid)

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(AgentFeedbackReference.self, from: data)

        #expect(decoded == reference)
        #expect(decoded.candidate == candidateA)
        #expect(decoded.fingerprint == reference.fingerprint)
        #expect(decoded.fingerprint.utf8.count == 64)
    }

    @Test("A reference to a run the task no longer contains is unresolvable, not re-targeted")
    func candidateIsKnown() {
        let task = makeTask(runIDs: [uuid(10)])
        let foreign = visualReference(
            candidate: candidate(run: uuid(99), code: codeState("a"), recorded: 120)
        )
        let known = visualReference(
            candidate: candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        )
        #expect(!foreign.candidateIsKnown(to: task))
        #expect(known.candidateIsKnown(to: task))
    }

    @Test("A newer candidate does not re-target a composing draft")
    func newerCandidateKeepsDraftBound() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let candidateB = candidate(run: uuid(11), code: codeState("b"), recorded: 170)
        let reference = visualReference(candidate: candidateA, createdAt: 150)
        var draft = AgentFeedbackDraft(reference: reference)
        #expect(draft.freshness == .current)

        let fingerprintBefore = draft.reference.fingerprint
        draft.noteCandidateArrived(candidateB)

        #expect(draft.freshness == .superseded(latestRunID: candidateB.runID))
        #expect(draft.reference.fingerprint == fingerprintBefore)
        #expect(draft.reference.candidate == candidateA)
    }

    @Test("Intentional feedback on an older result is classified, not silent")
    func intentionalHistoricalFeedback() {
        let older = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let latest = candidate(run: uuid(11), code: codeState("b"), recorded: 170)
        // The draft was created after `latest` settled: the user chose the
        // older candidate on purpose.
        let reference = visualReference(candidate: older, createdAt: 300)
        var draft = AgentFeedbackDraft(reference: reference)
        draft.noteCandidateArrived(latest)
        #expect(draft.freshness == .historical(latestRunID: latest.runID))
        #expect(draft.reference.candidate == older)
    }

    // MARK: - Acceptance 3 + audit: honest recoverable fallbacks

    @Test("The text-only path keeps the revision binding and downgrades a visual anchor")
    func textOnlyVariant() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let visual = visualReference(candidate: candidateA)
        let variant = visual.textOnlyVariant

        #expect(variant.attachments.isEmpty)
        #expect(variant.anchor == .plainText)
        #expect(variant.candidate == candidateA)
        #expect(variant.taskID == visual.taskID)
        #expect(variant.userText == visual.userText)
        #expect(variant.isValid)

        let codeReference = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .code,
            anchor: .lineRange(path: "Pine/View.swift", start: 10, end: 20),
            userText: "This range is wrong"
        )
        let codeVariant = codeReference.textOnlyVariant
        #expect(codeVariant.anchor == codeReference.anchor)
        #expect(codeVariant.attachments.isEmpty)
    }

    @Test("A future anchor kind decodes fail-closed: readable, unresolvable, not submittable")
    func unknownAnchorFailsClosed() throws {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let reference = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .code,
            anchor: .lineRange(path: "Pine/View.swift", start: 10, end: 20),
            userText: "This range is wrong"
        )
        let data = try JSONEncoder().encode(reference)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("unexpected encoding shape")
            return
        }
        json["anchor"] = ["kind": "pixelCloud", "path": "Pine/View.swift", "start": 10, "end": 20]
        let decoded = try JSONDecoder().decode(
            AgentFeedbackReference.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        #expect(decoded.anchor == .unsupported("pixelCloud"))
        #expect(decoded.candidate == candidateA)
        #expect(decoded.userText == "This range is wrong")
        #expect(!decoded.isValid)
    }

    @Test("A captured region requires the image it points into")
    func capturedRegionRequiresImage() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let reference = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .visualPreview,
            anchor: .capturedRegion(x: 4, y: 8, width: 200, height: 100),
            userText: "This region"
        )
        #expect(!reference.isValid)
    }

    @Test("Semantic element context is bounded and only ever supplied, never synthesized")
    func semanticElementBounds() {
        #expect(AgentFeedbackLocationAnchor
            .semanticElement(source: "browser", identifier: "main#title").isValid)
        #expect(!AgentFeedbackLocationAnchor
            .semanticElement(source: "", identifier: "main#title").isValid)
        #expect(!AgentFeedbackLocationAnchor
            .semanticElement(source: String(repeating: "s", count: 65), identifier: "id").isValid)
        #expect(!AgentFeedbackLocationAnchor
            .semanticElement(source: "browser", identifier: "id\u{0}").isValid)
    }

    @Test("Plain text identifies the same target without drawing")
    func plainTextEquivalence() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let visual = visualReference(candidate: candidateA)
        let textual = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .visualPreview,
            anchor: .plainText,
            userText: "Make this header easier to read",
            createdAt: date(150)
        )
        #expect(visual.isValid && textual.isValid)
        #expect(visual.candidate == textual.candidate)
    }

    @Test("Attachments fail closed on bounds")
    func attachmentBounds() {
        #expect(!AgentFeedbackAttachment(
            id: uuid(1), kind: .image, sha256: hex("a"),
            byteCount: AgentFeedbackAttachment.maximumImageBytes + 1,
            label: "shot"
        ).isValid)
        #expect(!AgentFeedbackAttachment(
            id: uuid(1), kind: .binaryBlob,
            captureBasis: .livePreviewObservation,
            sha256: hex("a"), byteCount: 10, label: "blob"
        ).isValid)
        #expect(!AgentFeedbackAttachment(
            id: uuid(1), kind: .image, sha256: "nothex",
            byteCount: 10, label: "shot"
        ).isValid)
        #expect(image(1, sha: hex("a"), basis: .livePreviewObservation).isValid)
    }

    @Test("The fingerprint covers the whole reference")
    func fingerprintCoversAll() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let candidateB = candidate(run: uuid(11), code: codeState("b"), recorded: 170)
        let base = visualReference(candidate: candidateA)

        func variant(
            userText: String? = nil,
            artifactVersion: String? = nil,
            anchor: AgentFeedbackLocationAnchor? = nil,
            attachments: [AgentFeedbackAttachment]? = nil,
            candidate: AgentTaskResultSnapshot? = nil
        ) -> String {
            AgentFeedbackReference(
                taskID: uuid(10),
                candidate: candidate ?? base.candidate,
                artifactKind: .visualPreview,
                artifactVersion: artifactVersion ?? base.artifactVersion,
                anchor: anchor ?? base.anchor,
                userText: userText ?? base.userText,
                attachments: attachments ?? base.attachments,
                createdAt: base.createdAt
            ).fingerprint
        }

        #expect(base.fingerprint == base.fingerprint)
        #expect(variant(userText: "Keep the spacing") != base.fingerprint)
        #expect(variant(artifactVersion: "build-1") != base.fingerprint)
        #expect(variant(anchor: .plainText) != base.fingerprint)
        #expect(variant(attachments: []) != base.fingerprint)
        #expect(variant(candidate: candidateB) != base.fingerprint)
    }

    // MARK: - Acceptance 7 (contract level): privacy

    @Test("References carry no paths in anchors other than worktree-relative targets")
    func privacyBounds() {
        let candidateA = candidate(run: uuid(10), code: codeState("a"), recorded: 120)
        let reference = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .code,
            anchor: .lineRange(path: "Pine/View.swift", start: 10, end: 20),
            userText: "This range is wrong"
        )
        #expect(reference.isValid)
        // An absolute path is not a supported anchor.
        let absolute = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .code,
            anchor: .lineRange(path: "/Users/someone/Pine/View.swift", start: 10, end: 20),
            userText: "This range is wrong"
        )
        #expect(!absolute.isValid)
    }
}
