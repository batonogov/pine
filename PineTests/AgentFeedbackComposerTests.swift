//
//  AgentFeedbackComposerTests.swift
//  PineTests
//
//  The feedback composer (#1758): the draft binds to the viewed revision and
//  is explained, not moved, when a newer result arrives; the capability gate
//  keeps an unsupported image with the draft and offers only the explicit
//  text-only path; a stale location keeps its reference and says so; and the
//  surface names the recipient, previews the transmission, and never acts by
//  itself. These hosted tests stand in for the CI-only UI assertions.
//

import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import Pine

/// In-memory task store whose next save waits on the test, so a send can be
/// cancelled while its durable record is still being written.
private actor AgentFeedbackPausingStore: AgentTaskPersisting {
    private var data = Data()
    private var gate: CheckedContinuation<Void, Never>?
    private var pausesNextSave = false
    nonisolated let paused = Mutex(false)

    func pauseNextSave() {
        pausesNextSave = true
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func storedSubmissions() -> [AgentFeedbackSubmissionRecord] {
        (try? JSONDecoder().decode([AgentTask].self, from: data))?
            .first?.feedbackSubmissions ?? []
    }

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil,
            requiresMigration: false,
            envelope: .empty
        )
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        await save(tasks: tasks, envelope: .empty, project: project, authorization: authorization)
    }

    func save(
        tasks: [AgentTask],
        envelope: AgentTaskEnvelopeState,
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        if pausesNextSave {
            pausesNextSave = false
            paused.withLock { $0 = true }
            await withCheckedContinuation { gate = $0 }
            paused.withLock { $0 = false }
        }
        guard let encoded = try? JSONEncoder().encode(tasks) else {
            return .rejected(.invalidMetadata)
        }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

@MainActor
@Suite("Revision-bound feedback composer", .serialized)
struct AgentFeedbackComposerTests {
    private var code: AgentTaskCodeStateIdentity { AgentFeedbackTestSupport.code }
    private var environment: AgentTaskEnvironmentIdentity { AgentFeedbackTestSupport.environment }

    private func makeModel(
        _ harness: AgentFeedbackTestSupport.Harness,
        route: AgentFeedbackRecordingRoute,
        changes: [AgentRevisionChangeItem] = []
    ) -> AgentFeedbackComposerModel {
        AgentFeedbackComposerModel(
            registry: harness.registry, taskID: harness.task.id, route: route.route,
            changes: changes
        )
    }

    // MARK: - Binding and freshness

    @Test("The draft binds to the viewed revision and is explained, not moved, when a newer result arrives")
    func bindsToTheViewedRevision() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        let viewed = try #require(harness.task.reviewedSnapshot)
        #expect(model.presentation.availability == .available)
        #expect(model.presentation.candidate == viewed)
        #expect(model.presentation.freshness == .current)
        model.text = "  Keep the previous spacing  "

        // A newer candidate is reviewed and verified while the user writes.
        let newer = AgentFeedbackTestSupport.withNewerResult(harness.task)
        harness.registry.setTasksForTesting([newer])
        model.sync()
        #expect(model.presentation.freshness == .superseded(latestRunID: viewed.runID))
        #expect(model.presentation.candidate == viewed, "the binding never moves by itself")

        // Intentional feedback on the older result stays submittable.
        #expect(model.presentation.canSend)
        await model.send(textOnly: true)
        #expect(model.presentation.failure == nil)
        #expect(route.requests.count == 1)
        #expect(route.requests.first?.reference.candidate == viewed)
        #expect(route.requests.first?.reference.userText == "Keep the previous spacing")
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).first?.candidate == viewed)
        guard case .delivered? = model.presentation.history.first?.state else {
            Issue.record("the intentional feedback on the older result should deliver")
            return
        }
    }

    @Test("Pointing at the newest result is a new draft that keeps the words")
    func retargetIsExplicit() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        model.text = "Keep the previous spacing"
        let newer = AgentFeedbackTestSupport.withNewerResult(harness.task)
        harness.registry.setTasksForTesting([newer])
        model.sync()
        #expect(model.presentation.freshness != .current)
        let oldBinding = model.presentation.candidate

        model.retargetToLatest()

        #expect(model.presentation.candidate == newer.reviewedSnapshot)
        #expect(model.presentation.candidate != oldBinding)
        #expect(model.presentation.freshness == .current)
        #expect(model.text == "Keep the previous spacing")
        // Re-pointing is the user's explicit act; nothing was sent for it.
        #expect(route.requests.isEmpty)
    }

    // MARK: - Capability gate

    @Test("An image the agent cannot take stays in the draft and sends only by the explicit text-only path")
    func unsupportedImageKeepsTheDraft() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        model.text = "Make this header easier to read"
        let image = AgentFeedbackTestSupport.image()
        model.attach(image)

        var presentation = model.presentation
        #expect(presentation.attachments.map(\.attachment) == [image])
        #expect(presentation.attachments.first?.rejection == .unsupportedKind)
        #expect(!presentation.canSend, "a whole-draft send is fenced by the gate")
        #expect(presentation.canSendTextOnly)

        await model.send(textOnly: false)
        #expect(route.requests.isEmpty, "the gate fences the whole-draft send")
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).isEmpty)

        await model.send(textOnly: true)
        #expect(route.requests.count == 1)
        #expect(route.requests.first?.reference.attachments.isEmpty == true)
        #expect(route.requests.first?.reference.userText == "Make this header easier to read")
        // The omission is disclosed and durable.
        let record = try #require(harness.registry.feedbackSubmissions(for: harness.task.id).first)
        #expect(record.disclosedOmissions.map(\.attachmentID) == [image.id])
        #expect(record.attachmentIDs == [image.id])
        // The attachment is kept with the composer, never dropped silently.
        presentation = model.presentation
        #expect(presentation.attachments.map(\.attachment) == [image])
        #expect(presentation.text == "")

        // Removing it is the user's own explicit act.
        model.detach(attachmentID: image.id)
        #expect(model.presentation.attachments.isEmpty)
    }

    @Test("Without a live session nothing can be sent and every word is kept")
    func unreachableRecipientBlocksSending() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        route.reachable = false
        let model = makeModel(harness, route: route)
        model.text = "Keep the previous spacing"

        #expect(model.presentation.recipientIsReachable == false)
        #expect(!model.presentation.canSend)
        #expect(!model.presentation.canSendTextOnly)
        await model.send(textOnly: true)
        #expect(route.requests.isEmpty)
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).isEmpty)
        #expect(harness.registry.task(for: harness.task.id)?.revisions.isEmpty == true)
        #expect(model.text == "Keep the previous spacing")
    }

    // MARK: - Anchors

    @Test("A location that no longer exists keeps its reference and says so in what is sent")
    func missingLocationKeepsItsReference() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let present = "Sources/Example/main.swift"
        let root = URL(fileURLWithPath: harness.task.project.canonicalWorktreePath)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Example"),
            withIntermediateDirectories: true
        )
        try "line one\nline two\nline three".write(
            to: root.appendingPathComponent(present), atomically: true, encoding: .utf8
        )
        let model = makeModel(harness, route: route, changes: [
            AgentRevisionChangeItem(relativePath: present, kind: .modified, attribution: .verified),
            AgentRevisionChangeItem(
                relativePath: "Sources/Gone.swift", kind: .deleted, attribution: .verified
            ),
        ])

        // Changed files are located off the main thread; until then only text is offered.
        #expect(model.presentation.anchorOptions.map(\.path) == [""])
        try #require(await waitUntilMainActor { model.presentation.anchorOptions.count == 3 })
        #expect(model.presentation.anchorOptions.map(\.path) == [
            "", present, "Sources/Gone.swift",
        ])
        #expect(model.presentation.anchorOptions.map(\.isMissing) == [false, false, true])

        model.text = "This file is wrong"
        model.selectAnchor(path: "Sources/Gone.swift")
        #expect(model.presentation.anchorResolution == .targetMissing)
        #expect(model.presentation.canSend, "intentional feedback on a stale location")
        await model.send(textOnly: false)
        #expect(route.requests.count == 1)
        #expect(route.requests.first?.anchorResolution == .targetMissing)
        #expect(route.requests.first?.reference.anchor
            == .lineRange(path: "Sources/Gone.swift", start: 1, end: 1))
        #expect(route.requests.first?.instruction
            == "About file Sources/Gone.swift, which no longer exists:\nThis file is wrong")
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).first?
            .anchorResolutionAtSubmission == .targetMissing)

        // A file that is still there anchors its whole range.
        model.selectAnchor(path: present)
        #expect(model.presentation.anchorResolution == .resolved)
        model.text = "Tighten the wording"
        await model.send(textOnly: false)
        #expect(route.requests.count == 2)
        #expect(route.requests.last?.reference.anchor == .lineRange(path: present, start: 1, end: 3))
        #expect(route.requests.last?.instruction
            == "In file Sources/Example/main.swift, lines 1–3:\nTighten the wording")
    }

    @Test("A plain-text anchor sends the words alone")
    func plainTextAnchor() throws {
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1_764, codeState: code, environment: environment
        )
        let submission = try AgentFeedbackTestSupport.submission(for: task)
        #expect(submission.dispatchRequest.instruction == submission.reference.userText)
        #expect(submission.dispatchRequest.anchorResolution == .resolved)
    }

    @Test("File location is read off the main thread and fails closed")
    func anchorTargetResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineFeedbackAnchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "a\nb\nc".write(
            to: directory.appendingPathComponent("three.swift"), atomically: true, encoding: .utf8
        )
        try "a\nb\n".write(
            to: directory.appendingPathComponent("two.swift"), atomically: true, encoding: .utf8
        )
        try Data().write(to: directory.appendingPathComponent("empty.swift"))

        #expect(await AgentFeedbackAnchorTarget.lineCount(
            of: directory.appendingPathComponent("three.swift")
        ) == 3)
        #expect(await AgentFeedbackAnchorTarget.lineCount(
            of: directory.appendingPathComponent("two.swift")
        ) == 2)
        // An empty file is still one addressable line; a missing one is not locatable.
        #expect(await AgentFeedbackAnchorTarget.lineCount(
            of: directory.appendingPathComponent("empty.swift")
        ) == 1)
        #expect(await AgentFeedbackAnchorTarget.lineCount(
            of: directory.appendingPathComponent("Gone.swift")
        ) == nil)
    }

    // MARK: - One dispatch per draft

    @Test("Two sends of one draft produce one submission and one dispatch")
    func doubleSendIsFenced() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        model.text = "Keep the previous spacing"

        async let first: Void = model.send(textOnly: false)
        async let second: Void = model.send(textOnly: false)
        _ = await (first, second)

        #expect(route.requests.count == 1)
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).count == 1)
        #expect(harness.registry.task(for: harness.task.id)?.revisions.count == 1)
        #expect(model.presentation.phase == .idle)
    }

    @Test("A refused send keeps every word and records nothing")
    func refusedSendKeepsTheDraft() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        var stale = harness.task
        stale.verificationState = .stale
        harness.registry.setTasksForTesting([stale])
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        model.text = "Keep the previous spacing"

        await model.send(textOnly: false)

        #expect(model.presentation.failure == .notReady)
        #expect(model.presentation.phase == .idle)
        #expect(model.text == "Keep the previous spacing")
        #expect(route.requests.isEmpty)
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).isEmpty)
        #expect(harness.registry.task(for: harness.task.id)?.revisions.isEmpty == true)
    }

    @Test("Cancelling while the record is still being written sends nothing and keeps the draft")
    func cancelWhileRecording() async throws {
        let store = AgentFeedbackPausingStore()
        let registry = AgentTaskRegistry(persistence: store)
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1_765, codeState: code, environment: environment,
            projectPath: "/tmp/pine-feedback-cancel"
        )
        registry.registerProject(task.project)
        #expect(await registry.flushPersistence() == .saved)
        registry.setTasksForTesting([task])
        let route = AgentFeedbackRecordingRoute()
        let model = AgentFeedbackComposerModel(
            registry: registry, taskID: task.id, route: route.route
        )
        model.text = "Keep the previous spacing"

        await store.pauseNextSave()
        let sending = Task { await model.send(textOnly: false) }
        // The durable write is now in flight: the only moment a cancel is real.
        try #require(await waitUntilMainActor { store.paused.withLock { $0 } })
        #expect(model.presentation.phase == .recording)
        model.cancelSend()
        await store.release()
        await sending.value
        // The host re-syncs on the registry's change; mirror that here.
        model.sync()

        #expect(route.requests.isEmpty, "a cancelled record is never dispatched")
        #expect(model.presentation.phase == .idle)
        #expect(model.text == "Keep the previous spacing", "the draft is untouched")
        #expect(model.presentation.history.first?.state == .cancelled)
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.storedSubmissions().first?.state == .cancelled)
    }

    // MARK: - Delivery states in history

    @Test("Retry re-arms the same submission under the same key and records one revision")
    func retryReArmsTheSameSubmission() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        let model = makeModel(harness, route: route)
        func refuse() async throws -> AgentFeedbackDeliveryReceipt? {
            throw AgentFeedbackDeliveryFailure.providerRejected
        }
        route.answer = { _ in try await refuse() }
        model.text = "Keep the previous spacing"
        await model.send(textOnly: false)

        #expect(model.presentation.history.first?.state == .failed(.providerRejected))
        #expect(model.text == "", "the sent words now live in the submission")
        // Nothing was resent on its own.
        #expect(route.requests.count == 1)

        route.answer = { request in
            AgentFeedbackDeliveryReceipt(submissionID: request.submissionID)
        }
        await model.retry(try #require(model.presentation.history.first))
        // The host re-syncs on the registry's change; mirror that here.
        model.sync()

        #expect(route.requests.count == 2)
        #expect(Set(route.requests.map(\.submissionID)).count == 1)
        #expect(route.requests.last?.reference.userText == "Keep the previous spacing")
        guard case .delivered? = model.presentation.history.first?.state else {
            Issue.record("the explicit retry should deliver")
            return
        }
        #expect(harness.registry.task(for: harness.task.id)?.revisions.count == 1)
    }

    @Test("Delivery-unknown history offers no retry and is never resent")
    func deliveryUnknownIsNeverRetried() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let route = AgentFeedbackRecordingRoute()
        route.answer = { _ in nil }
        let model = makeModel(harness, route: route)
        model.text = "Keep the previous spacing"
        await model.send(textOnly: false)
        let entry = try #require(model.presentation.history.first)
        #expect(entry.state == .deliveryUnknown)

        await model.retry(entry)

        #expect(route.requests.count == 1)
        #expect(model.presentation.history.first?.state == .deliveryUnknown)
    }
}

/// The composer surface as VoiceOver and the keyboard see it. These mirror
/// the UI tests that only CI can run.
@MainActor
@Suite("Feedback composer surface", .serialized)
struct AgentFeedbackComposerSurfaceTests {
    private func readyTask() throws -> AgentTask {
        try ADEContractFixtures.verifiedSuccessTask(
            seed: 1_766,
            codeState: AgentFeedbackTestSupport.code,
            environment: AgentFeedbackTestSupport.environment
        )
    }

    private func presentation(
        source: AgentTask? = nil,
        attachments: [AgentFeedbackAttachment] = [],
        inputSupport: AgentFeedbackInputSupport = .none,
        history: [AgentFeedbackSubmissionRecord] = [],
        freshness: AgentFeedbackRevisionFreshness = .current,
        text: String = "Make the greeting shorter"
    ) throws -> AgentFeedbackComposerPresentation {
        let task = try source ?? readyTask()
        let gate = AgentFeedbackSubmissionGate.validate(AgentFeedbackReference(
            taskID: task.id,
            candidate: try #require(task.reviewedSnapshot),
            artifactKind: .code,
            anchor: .plainText,
            userText: text,
            attachments: attachments
        ), against: inputSupport)
        let reasons = Dictionary(
            gate.rejections.map { ($0.attachmentID, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        return AgentFeedbackComposerPresentation(
            availability: .available,
            recipientName: "OpenCode",
            recipientIsReachable: true,
            candidate: task.reviewedSnapshot,
            freshness: freshness,
            anchorOptions: [
                AgentFeedbackComposerPresentation.AnchorOption(path: "", isMissing: false),
                AgentFeedbackComposerPresentation.AnchorOption(
                    path: "Sources/Example/main.swift", isMissing: false
                ),
            ],
            selectedAnchorPath: "",
            anchorResolution: .resolved,
            text: text,
            attachments: attachments.map {
                AgentFeedbackComposerPresentation.AttachmentNotice(
                    attachment: $0, rejection: reasons[$0.id]
                )
            },
            phase: .idle,
            failure: nil,
            history: history.map { AgentFeedbackHistoryEntry(record: $0, text: nil) }
        )
    }

    private func entry(
        _ task: AgentTask,
        text: String,
        state: AgentFeedbackDeliveryState,
        resolution: AgentFeedbackResolution = .unresolved
    ) throws -> AgentFeedbackSubmissionRecord {
        var record = AgentFeedbackSubmissionRecord(
            try AgentFeedbackTestSupport.submission(for: task, text: text)
        )
        record.state = state
        record.resolution = resolution
        return record
    }

    private func labels(_ root: NSObject) -> String {
        AccessibilityTreeProbe.labels(under: root).joined(separator: "\n")
    }

    @Test("The surface names the recipient and the bound revision in the transmission preview")
    func namesRecipientAndRevision() throws {
        let model = try presentation()
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }
        let text = labels(hosted.root)

        #expect(text.contains("Give feedback"))
        #expect(text.contains("Sends to OpenCode"))
        let bound = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackBoundRevision
        ))
        #expect(AccessibilityTreeProbe.label(of: bound)?.hasPrefix("About revision aaaaaaaa") == true)
        let recipient = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackRecipient
        ))
        #expect(AccessibilityTreeProbe.label(of: recipient)?.contains("OpenCode") == true)
        // The transmission preview repeats recipient and revision, and lists attachments.
        let preview = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackPreview
        ))
        let previewText = labels(preview)
        #expect(previewText.contains("Review before sending"))
        #expect(previewText.contains("Sends to OpenCode"))
        #expect(previewText.contains("About revision aaaaaaaa"))
        #expect(previewText.contains("Attachments: none"))
        // The honest statement about the deferred visual slice.
        #expect(text.contains(
            "Images and selections aren’t supported for this result yet. Feedback is sent as text."
        ))
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackText
        ) != nil)
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackLocation
        ) != nil)
    }

    @Test("An unsupported image makes the text-only path the default button and keeps the image listed")
    func textOnlyIsTheDefaultButton() throws {
        let image = AgentFeedbackTestSupport.image()
        let model = try presentation(attachments: [image])
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }

        let textOnly = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackSendTextOnly
        ))
        #expect(AccessibilityTreeProbe.label(of: textOnly) == "Send text only")
        #expect(AccessibilityTreeProbe.attribute("isAccessibilityEnabled", of: textOnly) as? Bool == true)
        // A whole-draft send is not offered at all while the gate rejects an attachment.
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackSend
        ) == nil)
        let text = labels(hosted.root)
        #expect(text.contains(
            "SECRET preview capture · kept in this draft, not sent: this agent doesn’t accept it"
        ))
        #expect(text.contains(
            "Text only sends your words and the result you commented on. "
                + "The attachments listed above stay in this draft."
        ))
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root,
            identifier: AccessibilityID.agentFeedbackRemoveAttachment(image.id)
        ) != nil)
    }

    @Test("A fully accepted draft offers one whole-draft send as the default button")
    func acceptedDraftSendsWhole() throws {
        let image = AgentFeedbackTestSupport.image()
        let model = try presentation(
            attachments: [image], inputSupport: AgentFeedbackInputSupport(
                image: .init(maximumBytes: 1_048_576),
                textResource: .init(maximumBytes: nil),
                binaryBlob: .init(maximumBytes: nil)
            )
        )
        #expect(model.attachmentsAreSupported)
        #expect(model.canSend)
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }

        let send = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackSend
        ))
        #expect(AccessibilityTreeProbe.label(of: send) == "Send feedback")
        #expect(AccessibilityTreeProbe.attribute("isAccessibilityEnabled", of: send) as? Bool == true)
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackSendTextOnly
        ) == nil)
        #expect(labels(hosted.root).contains("SECRET preview capture · will be sent"))
    }

    @Test("History keeps queued, delivered, failed, cancelled, and unconfirmed delivery distinguishable")
    func historyDistinguishesDeliveryStates() throws {
        let task = try readyTask()
        let acknowledged = try AgentFeedbackTestSupport.submission(for: task, text: "Feedback 1")
        let states: [(String, AgentFeedbackDeliveryState)] = [
            ("Feedback 0", .queued),
            ("Feedback 1", .delivered(AgentFeedbackDeliveryOutcome(
                receipt: AgentFeedbackDeliveryReceipt(submissionID: acknowledged.id),
                sentAttachmentIDs: []
            ))),
            ("Feedback 2", .failed(.transportUnavailable)),
            ("Feedback 3", .cancelled),
            ("Feedback 4", .deliveryUnknown),
            // Delivered, but the transport carried none of the sent
            // attachments: the chip stays green and the caption discloses.
            ("Feedback 5", .delivered(AgentFeedbackDeliveryOutcome(
                receipt: AgentFeedbackDeliveryReceipt(submissionID: acknowledged.id),
                sentAttachmentIDs: [acknowledged.id]
            ))),
        ]
        // Oldest first in the task; the surface lists newest first.
        var records = try states.map { try entry(task, text: $0.0, state: $0.1) }
        records[3].resolution = .agentReportedAddressed
        let model = try presentation(source: task, history: records.reversed())
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 1_200)
        )
        defer { hosted.tearDown() }
        let text = labels(hosted.root)

        for caption in ["Queued; not yet confirmed", "Not delivered",
                        "Cancelled before sending"] {
            #expect(text.components(separatedBy: caption).count == 2, "\(caption)")
        }
        // Two delivered entries: one complete, one with attachments the
        // transport did not carry.
        #expect(text.components(separatedBy: "Delivered").count == 3)
        #expect(text.contains("Delivered · 1 attachment(s) not sent"))
        #expect(text.components(separatedBy: "Delivery unconfirmed").count == 2)
        #expect(text.contains(
            "Pine can’t confirm whether the agent received this. It won’t resend automatically. "
                + "Check the agent’s conversation before sending it again."
        ))
        // A definite failure names its reason and offers exactly one explicit retry.
        #expect(text.contains(
            "The agent session is unavailable. Nothing reached the agent. Retry works only in "
                + "this session; after relaunch the text is not kept, and the task waits as a "
                + "pending revision until the next result settles."
        ))
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackRetry(records[2].id)
        ) != nil, "a definite failure offers an explicit retry")
        for record in [records[0], records[1], records[3], records[4]] {
            #expect(AccessibilityTreeProbe.element(
                under: hosted.root, identifier: AccessibilityID.agentFeedbackRetry(record.id)
            ) == nil, "\(record.state) never offers a retry")
        }
        #expect(text.contains("Pine keeps which result you commented on, not the text you typed."))
    }

    @Test("An agent's 'addressed' claim stays distinct from checks, Ready, and user acceptance")
    func addressedStaysDistinct() throws {
        let task = try readyTask()
        let addressed = try entry(
            task, text: "Addressed", state: .delivered(AgentFeedbackDeliveryOutcome(
                receipt: AgentFeedbackDeliveryReceipt(submissionID: UUID()), sentAttachmentIDs: []
            )), resolution: .agentReportedAddressed
        )
        let unresolved = try entry(task, text: "Open", state: .queued)
        let accepted = try entry(
            task, text: "Accepted", state: .delivered(AgentFeedbackDeliveryOutcome(
                receipt: AgentFeedbackDeliveryReceipt(submissionID: UUID()), sentAttachmentIDs: []
            )), resolution: .acceptedByUser
        )
        let model = try presentation(source: task, history: [accepted, addressed, unresolved])
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }
        let text = labels(hosted.root)

        #expect(text.components(separatedBy: "Agent says addressed; not verified, not accepted").count == 2)
        #expect(text.components(separatedBy: "Unresolved").count == 2)
        #expect(text.components(separatedBy: "Accepted by you").count == 2)
        // A claim is never dressed as a passing check or a Ready result.
        #expect(!text.contains("Ready"))
        #expect(!text.contains("Verified"))
    }

    @Test("A newer result is explained and the way to the newest one is an explicit action")
    func freshnessIsExplained() throws {
        let task = try readyTask()
        let viewed = try #require(task.reviewedSnapshot)
        let newer = try #require(AgentFeedbackTestSupport.withNewerResult(task).reviewedSnapshot)
        #expect(newer != viewed)
        let model = try presentation(source: task, freshness: .superseded(latestRunID: viewed.runID))
        var actions: [String] = []
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model, onUseLatest: { actions.append("latest") }),
            size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }
        let text = labels(hosted.root)

        #expect(text.contains(
            "A newer result arrived while you were writing. This feedback stays about the older "
                + "result you were viewing and is not moved to the newer one."
        ))
        // The draft still names the revision it is about.
        let bound = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackBoundRevision
        ))
        #expect(AccessibilityTreeProbe.label(of: bound)?.contains("About revision aaaaaaaa") == true)
        // Showing the explanation moves nothing; only the explicit action can.
        #expect(actions.isEmpty)
        let useLatest = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackUseLatest
        ))
        #expect(AccessibilityTreeProbe.label(of: useLatest) == "Point at the newest result instead")
        #expect(AccessibilityTreeProbe.performPress(useLatest) == true)
        #expect(actions == ["latest"])
    }

    @Test("Without a route the composer says so and offers nothing to send")
    func noRouteIsHonest() throws {
        var model = try presentation()
        model = AgentFeedbackComposerPresentation(
            availability: .noRoute, recipientName: "", recipientIsReachable: false,
            candidate: model.candidate, freshness: .current, anchorOptions: [],
            selectedAnchorPath: "", anchorResolution: .resolved, text: "", attachments: [],
            phase: .idle, failure: nil, history: []
        )
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 400)
        )
        defer { hosted.tearDown() }

        #expect(labels(hosted.root).contains("Pine can’t send feedback to this agent yet."))
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackSendTextOnly
        ) == nil)
        #expect(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackText
        ) == nil)
    }

    @Test("A missing location is named and explained before anything is sent")
    func missingLocationIsExplained() throws {
        var model = try presentation()
        model = AgentFeedbackComposerPresentation(
            availability: .available, recipientName: "OpenCode", recipientIsReachable: true,
            candidate: model.candidate, freshness: .current,
            anchorOptions: [
                .init(path: "", isMissing: false),
                .init(path: "Sources/Gone.swift", isMissing: true),
            ],
            selectedAnchorPath: "Sources/Gone.swift", anchorResolution: .targetMissing,
            text: model.text, attachments: [], phase: .idle, failure: nil, history: []
        )
        #expect(model.canSend, "a stale location never blocks intentional feedback")
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(model: model), size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }
        let text = labels(hosted.root)

        #expect(text.components(separatedBy: "Sources/Gone.swift (no longer exists)").count == 3)
        #expect(text.contains(
            "This file no longer exists, so the agent can’t open it. The feedback keeps that "
                + "reference and says so in what it sends."
        ))
    }

    @Test("Hosting the composer changes, sends, retries, compares, and retargets nothing")
    func hostingNeverActs() throws {
        let task = try readyTask()
        let failed = try entry(
            task, text: "Earlier", state: .failed(.providerRejected)
        )
        let model = try presentation(
            source: task, attachments: [AgentFeedbackTestSupport.image()], history: [failed]
        )
        var actions = 0
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(
                model: model,
                onTextChange: { _ in actions += 1 },
                onSelectAnchor: { _ in actions += 1 },
                onSend: { actions += 1 },
                onSendTextOnly: { actions += 1 },
                onCancelSend: { actions += 1 },
                onUseLatest: { actions += 1 },
                onRemoveAttachment: { _ in actions += 1 },
                onRetry: { _ in actions += 1 },
                onCompare: { _ in actions += 1 }
            ),
            size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }
        #expect(actions == 0, "opening a surface is never a send")
    }

    @Test("Compare and retry report intent only, for their own feedback entry")
    func compareAndRetryReportIntent() throws {
        let task = try readyTask()
        let failed = try entry(task, text: "Earlier", state: .failed(.providerRejected))
        let model = try presentation(source: task, history: [failed])
        var retried: [UUID] = []
        var compared: [UUID] = []
        let hosted = AccessibilityTreeProbe.host(
            AgentFeedbackComposerView(
                model: model,
                onRetry: { retried.append($0) },
                onCompare: { compared.append($0) }
            ),
            size: NSSize(width: 720, height: 900)
        )
        defer { hosted.tearDown() }

        let retry = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackRetry(failed.id)
        ))
        #expect(AccessibilityTreeProbe.performPress(retry) == true)
        let compare = try #require(AccessibilityTreeProbe.element(
            under: hosted.root, identifier: AccessibilityID.agentFeedbackCompare(failed.id)
        ))
        #expect(AccessibilityTreeProbe.label(of: compare) == "Compare")
        #expect(AccessibilityTreeProbe.performPress(compare) == true)
        #expect(retried == [failed.id])
        #expect(compared == [failed.id])
    }

    @Test("Return activates the text-only default button of a hosted composer")
    func returnActivatesTextOnlyDefaultButton() async throws {
        let model = try presentation(attachments: [AgentFeedbackTestSupport.image()])
        var sends: [String] = []
        let hosting = NSHostingView(rootView: AgentFeedbackComposerView(
            model: model,
            onSend: { sends.append("full") },
            onSendTextOnly: { sends.append("text-only") }
        ).environment(\.locale, Locale(identifier: "en")))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let previousKeyWindow = NSApp.keyWindow
        defer {
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

        // This is the assertion the CI-only UI test makes with a real Return.
        try #require(await waitUntilMainActor { !sends.isEmpty })
        #expect(sends == ["text-only"])
    }

    @Test("Feedback copy has an entry with matching placeholders for every locale")
    func feedbackCopyCoversEveryLocale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Pine/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let locales = Set(["de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"])
        let placeholders = try NSRegularExpression(pattern: "%(?:\\d+\\$)?@")

        for value in Strings.AgentFeedbackCopy.allCases {
            let entry = try #require(strings["agentFeedback.\(value.rawValue)"] as? [String: Any])
            let translations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(translations.keys) == locales, "\(value.rawValue)")
            var marks: Set<[String]> = []
            var english = ""
            for (locale, translation) in translations {
                let unit = try #require(
                    (translation as? [String: Any])?["stringUnit"] as? [String: Any]
                )
                let text = try #require(unit["value"] as? String)
                #expect(!text.isEmpty, "\(value.rawValue) \(locale)")
                let range = NSRange(text.startIndex..., in: text)
                var found: [String] = []
                for match in placeholders.matches(in: text, range: range) {
                    found.append(String(text[try #require(Range(match.range, in: text))]))
                }
                marks.insert(found)
                if locale as? String == "en" { english = text }
            }
            // Every language formats the same arguments, and the English
            // catalog entry is the in-code fallback.
            #expect(marks.count == 1, "\(value.rawValue)")
            #expect(english == Strings.agentFeedback(
                value, locale: Locale(identifier: "en")
            ), "\(value.rawValue)")
        }
        // The catalog resolves per requested language, not the process language.
        #expect(Strings.agentFeedback(
            .sendTextOnly, locale: Locale(identifier: "ru")
        ) == "Отправить только текст")
        #expect(Strings.agentFeedback(
            .composerTitle, locale: Locale(identifier: "ja")
        ) == "フィードバックを送る")
    }
}
