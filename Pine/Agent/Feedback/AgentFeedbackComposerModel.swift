//
//  AgentFeedbackComposerModel.swift
//  Pine
//
//  Revision-bound feedback composition (#1758). The draft is bound to the
//  result revision the user is viewing and never re-targets itself; the
//  capability gate, freshness, transmission preview and one dispatch per
//  submission live here. Nothing in this file accepts a result, authorizes
//  Git, or starts an agent.
//

import Foundation
import Observation

nonisolated extension AgentTask {
    /// The revision a viewer of this task's latest result is looking at: the
    /// durable reviewed snapshot when it describes the latest run, otherwise
    /// the latest run's settled identity. Stable between observations, so a
    /// newer value really is a newer result.
    var feedbackCandidate: AgentTaskResultSnapshot? {
        guard let latest = runs.last, let outcome = latest.outcome else { return nil }
        if let reviewed = reviewedSnapshot, reviewed.runID == latest.id { return reviewed }
        let bound = AgentTaskLifecycleReducer.facts(forRun: latest.id, in: self)
            .filter { $0.codeState != nil && $0.environment != nil }
            .max { $0.observedAt < $1.observedAt }
        return AgentTaskResultSnapshot(
            runID: latest.id,
            outcome: outcome,
            codeState: bound?.codeState,
            environment: bound?.environment ?? environment,
            recordedAt: latest.settledAt ?? latest.startedAt
        )
    }
}

/// The task facts feedback reads. A host re-syncs its model when this
/// changes, so no observer token outlives the surface.
nonisolated struct AgentFeedbackTaskSignal: Equatable {
    let latestRunID: UUID?
    let outcome: AgentTaskOutcome?
    let reviewed: AgentTaskResultSnapshot?
    let submissions: [AgentFeedbackSubmissionRecord]

    init(_ task: AgentTask?) {
        latestRunID = task?.runs.last?.id
        outcome = task?.runs.last?.outcome
        reviewed = task?.reviewedSnapshot
        submissions = task?.feedbackSubmissions ?? []
    }
}

/// How the owning agent takes feedback: a named recipient, whether its
/// session can take input now, and the one dispatch path.
@MainActor
struct AgentFeedbackRoute {
    let agentName: String
    let isReachable: @MainActor () -> Bool
    let dispatch: AgentFeedbackDispatch
}

/// Whether a file the user can point at still exists in the worktree.
nonisolated enum AgentFeedbackAnchorTargetState: Equatable, Sendable {
    case present(lineCount: UInt32)
    /// The file is gone; `lastKnownLineCount` is what it had while it existed.
    case missing(lastKnownLineCount: UInt32?)

    var lineCount: UInt32? {
        switch self {
        case .present(let lineCount), .missing(let lineCount?): lineCount
        case .missing(nil): nil
        }
    }
}

/// Resolves a changed file in the task worktree, off the main thread.
nonisolated enum AgentFeedbackAnchorTarget {
    static let maximumBytes = 8 * 1024 * 1024

    /// Lines in the whole file; `nil` when it is missing, unreadable, or too
    /// large to locate.
    static func lineCount(of url: URL) async -> UInt32? {
        await runOnBackground {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var newlines: UInt32 = 0
            var total = 0
            var last: UInt8 = 0x0A
            do {
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    total += data.count
                    guard total <= maximumBytes else { return nil }
                    newlines += UInt32(data.filter { $0 == 0x0A }.count)
                    if let byte = data.last { last = byte }
                }
            } catch {
                return nil
            }
            return max(1, newlines + (last == 0x0A ? 0 : 1))
        }
    }
}

/// One feedback submission as history shows it, on the composer and on the
/// comparison. The durable record is all that survives relaunch.
nonisolated struct AgentFeedbackHistoryEntry: Equatable, Sendable, Identifiable {
    let record: AgentFeedbackSubmissionRecord
    /// The user's words while the submission is still live in this session.
    let text: String?

    var id: UUID { record.id }
    var candidate: AgentTaskResultSnapshot { record.candidate }
    var state: AgentFeedbackDeliveryState { record.state }
    var resolution: AgentFeedbackResolution { record.resolution }
    var submittedAt: Date { record.submittedAt }
    var anchorResolution: AgentFeedbackAnchorResolution { record.anchorResolutionAtSubmission }
    var omittedAttachmentCount: Int { record.disclosedOmissions.count }
}

/// Display-safe composer state (#1758). The draft stays bound to the revision
/// the user was viewing; this value explains that binding and never
/// re-targets it.
nonisolated struct AgentFeedbackComposerPresentation: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        /// The task has no settled result to comment on yet.
        case noResult
        /// The owning agent has no channel that can take feedback.
        case noRoute
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// The durable record is being written. Nothing was sent yet.
        case recording
        /// The single dispatch is in flight.
        case dispatching
    }

    /// Why the last send did not go out.
    enum Failure: Equatable, Sendable {
        case duplicate, notReady, limitReached, notDurable, unavailable
    }

    struct AnchorOption: Equatable, Sendable, Identifiable {
        /// The worktree-relative path; empty for "described in the text".
        let path: String
        /// The file no longer exists in the worktree.
        let isMissing: Bool

        var id: String { path }
    }

    struct AttachmentNotice: Equatable, Sendable, Identifiable {
        let attachment: AgentFeedbackAttachment
        /// Why the gate rejects it; `nil` when the transport accepts it.
        let rejection: AgentFeedbackAttachmentRejection.Reason?

        var id: UUID { attachment.id }
    }

    let availability: Availability
    let recipientName: String
    /// The recipient has a live session that can take input now.
    let recipientIsReachable: Bool
    /// The revision the draft is bound to. Never changes while the draft lives.
    let candidate: AgentTaskResultSnapshot?
    let freshness: AgentFeedbackRevisionFreshness
    let anchorOptions: [AnchorOption]
    /// The selected location's path; empty for "described in the text".
    let selectedAnchorPath: String
    let anchorResolution: AgentFeedbackAnchorResolution
    let text: String
    let attachments: [AttachmentNotice]
    let phase: Phase
    let failure: Failure?
    /// Newest first.
    let history: [AgentFeedbackHistoryEntry]

    var isSending: Bool { phase != .idle }
    var hasWords: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Every attachment is accepted by the transport.
    var attachmentsAreSupported: Bool { attachments.allSatisfy { $0.rejection == nil } }

    var canSend: Bool {
        availability == .available && recipientIsReachable && !isSending
            && hasWords && attachmentsAreSupported && anchorIsResolved
    }

    /// The explicit text-only path, offered exactly when the gate rejects
    /// an attachment. A location that is gone does not block it: the
    /// reference keeps the stale anchor and says so.
    var canSendTextOnly: Bool {
        availability == .available && recipientIsReachable && !isSending
            && hasWords && anchorIsResolved
    }

    /// The selected file is still being located in the worktree.
    private var anchorIsResolved: Bool {
        selectedAnchorPath.isEmpty
            || anchorOptions.contains { $0.path == selectedAnchorPath }
    }
}

/// Owns one feedback draft for one task. The registry is the durable
/// authority: this model never keeps a delivery state the registry does not
/// hold, only the words that are deliberately never persisted.
@MainActor
@Observable
final class AgentFeedbackComposerModel {
    private let registry: AgentTaskRegistry
    private let taskID: UUID
    private let route: AgentFeedbackRoute?
    private let inputSupport: AgentFeedbackInputSupport
    private let changes: [AgentRevisionChangeItem]

    private(set) var task: AgentTask?
    private(set) var draft: AgentFeedbackDraft?
    /// Empty for "described in the text".
    private(set) var selectedPath = ""
    private(set) var attachments: [AgentFeedbackAttachment] = []
    /// Only files already located in the worktree appear as locations.
    private(set) var anchorTargets: [String: AgentFeedbackAnchorTargetState] = [:]
    private(set) var phase: AgentFeedbackComposerPresentation.Phase = .idle
    private(set) var failure: AgentFeedbackComposerPresentation.Failure?
    var text = ""

    @ObservationIgnored private var anchorLookup = UUID()
    @ObservationIgnored private var anchorLookupKey: [String] = []
    @ObservationIgnored private var recording: AgentFeedbackSubmission?

    init(
        registry: AgentTaskRegistry,
        taskID: UUID,
        route: AgentFeedbackRoute?,
        inputSupport: AgentFeedbackInputSupport = .none,
        changes: [AgentRevisionChangeItem] = []
    ) {
        self.registry = registry
        self.taskID = taskID
        self.route = route
        self.inputSupport = inputSupport
        self.changes = changes
        sync()
    }

    var signal: AgentFeedbackTaskSignal { AgentFeedbackTaskSignal(registry.task(for: taskID)) }

    var presentation: AgentFeedbackComposerPresentation {
        let candidate = draft?.reference.candidate ?? task?.feedbackCandidate
        let rejections = currentReference.map {
            AgentFeedbackSubmissionGate.validate($0, against: inputSupport).rejections
        } ?? []
        let reasons = Dictionary(
            rejections.map { ($0.attachmentID, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        let live = registry.liveFeedbackSubmissions(for: taskID)
        return AgentFeedbackComposerPresentation(
            availability: candidate == nil ? .noResult : (route == nil ? .noRoute : .available),
            recipientName: route?.agentName ?? "",
            recipientIsReachable: route?.isReachable() ?? false,
            candidate: candidate,
            freshness: draft?.freshness ?? .current,
            anchorOptions: anchorOptions,
            selectedAnchorPath: selectedPath,
            anchorResolution: anchorResolution,
            text: text,
            attachments: attachments.map {
                AgentFeedbackComposerPresentation.AttachmentNotice(
                    attachment: $0, rejection: reasons[$0.id]
                )
            },
            phase: phase,
            failure: failure,
            history: (task?.feedbackSubmissions ?? []).reversed().map { record in
                AgentFeedbackHistoryEntry(
                    record: record,
                    text: live.first { $0.id == record.id }?.reference.userText
                )
            }
        )
    }

    /// Re-reads the task. Binds a new draft to the viewed revision, or explains
    /// that a newer result arrived for a draft that already exists.
    func sync(force: Bool = false) {
        let current = registry.task(for: taskID)
        guard force || AgentFeedbackTaskSignal(current) != AgentFeedbackTaskSignal(task) else {
            return
        }
        task = current
        guard let candidate = current?.feedbackCandidate else { return }
        if var existing = draft {
            existing.noteCandidateArrived(candidate)
            draft = existing
        } else {
            draft = AgentFeedbackDraft(reference: reference(
                candidate: candidate, createdAt: Date(), anchor: .plainText
            ))
        }
        // A new result may have added, changed, or removed the files to point at.
        let key = [String(candidate.recordedAt.timeIntervalSince1970)] + changePaths
        if key != anchorLookupKey {
            anchorLookupKey = key
            loadAnchorTargets()
        }
    }

    func selectAnchor(path: String) {
        guard phase == .idle,
              path.isEmpty || anchorTargets[path] != nil else { return }
        selectedPath = path
    }

    /// Explicit: a NEW draft about the newest result. The candidate binding is
    /// never edited in place; the typed words and attachments are kept.
    func retargetToLatest() {
        guard phase == .idle, let candidate = task?.feedbackCandidate else { return }
        selectedPath = ""
        draft = AgentFeedbackDraft(reference: reference(candidate: candidate, createdAt: Date()))
    }

    /// Adds an explicitly captured attachment. The gate never drops one: an
    /// attachment the transport cannot carry stays listed until removed here.
    func attach(_ attachment: AgentFeedbackAttachment) {
        guard phase == .idle, attachments.count < AgentFeedbackReference.maximumAttachments,
              !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
    }

    func detach(attachmentID: UUID) {
        guard phase == .idle else { return }
        attachments.removeAll { $0.id == attachmentID }
    }

    /// The one send of this draft. The durable record comes first; the
    /// dispatch follows only while that record is still queued.
    func send(textOnly: Bool) async {
        let model = presentation
        guard model.phase == .idle, let route, let draft, let reference = currentReference,
              textOnly ? model.canSendTextOnly : model.canSend else { return }
        failure = nil
        let rejections = AgentFeedbackSubmissionGate.validate(
            reference, against: inputSupport
        ).rejections
        // The draft's live words, location, and attachments — not the
        // binding-time snapshot — are what gets submitted. The candidate
        // binding itself is untouched.
        var submissionDraft = draft
        submissionDraft.reference = reference
        let result = textOnly
            ? AgentFeedbackStateMachine.submitTextOnly(
                draft: submissionDraft, rejections: rejections,
                anchorResolution: model.anchorResolution, existing: []
            )
            : AgentFeedbackStateMachine.submit(
                draft: submissionDraft, support: inputSupport,
                anchorResolution: model.anchorResolution, existing: []
            )
        guard case .success(let submission) = result else {
            if case .failure(let fence) = result { failure = Self.failure(fence) }
            return
        }
        recording = submission
        phase = .recording
        defer {
            recording = nil
            phase = .idle
        }
        switch await registry.recordFeedbackSubmission(submission) {
        case .failure(let admission):
            failure = Self.failure(admission)
        case .success:
            // Cancelled while the record was written: nothing was sent and
            // the draft is untouched.
            guard registry.feedbackSubmissions(for: taskID).contains(where: {
                $0.id == submission.id && $0.state == .queued
            }) else { return }
            phase = .dispatching
            _ = await registry.dispatchFeedbackSubmission(submission, dispatch: route.dispatch)
            startFreshDraft(sent: submission)
        }
    }

    /// An explicit retry after a definite failure. The same idempotency key
    /// is re-armed; nothing is recorded twice.
    func retry(_ entry: AgentFeedbackHistoryEntry) async {
        guard phase == .idle, let route,
              let submission = registry.liveFeedbackSubmissions(for: taskID)
                  .first(where: { $0.id == entry.id }) else { return }
        failure = nil
        phase = .dispatching
        if await registry.retryFeedbackSubmission(submission, dispatch: route.dispatch) == nil {
            failure = .unavailable
        }
        phase = .idle
    }

    /// Stops a send while its record is still being written. A dispatch that
    /// is already in flight cannot be confirmed stopped and is left alone.
    func cancelSend() {
        guard phase == .recording, let id = recording?.id else { return }
        registry.cancelFeedbackSubmission(taskID: taskID, submissionID: id)
    }

    // MARK: - Draft

    private var changePaths: [String] {
        var paths: [String] = []
        for change in changes where change.isValid && !paths.contains(change.relativePath) {
            paths.append(change.relativePath)
        }
        return paths
    }

    /// "Described in the text" plus every located change row of the result.
    private var anchorOptions: [AgentFeedbackComposerPresentation.AnchorOption] {
        [AgentFeedbackComposerPresentation.AnchorOption(path: "", isMissing: false)]
            + anchorTargets.keys.sorted().map { path in
                var isMissing = false
                if case .missing = anchorTargets[path] { isMissing = true }
                return AgentFeedbackComposerPresentation.AnchorOption(
                    path: path, isMissing: isMissing
                )
            }
    }

    private var anchor: AgentFeedbackLocationAnchor {
        guard !selectedPath.isEmpty else { return .plainText }
        return .lineRange(
            path: selectedPath, start: 1, end: anchorTargets[selectedPath]?.lineCount ?? 1
        )
    }

    private var anchorResolution: AgentFeedbackAnchorResolution {
        guard !selectedPath.isEmpty else { return .resolved }
        switch anchorTargets[selectedPath] {
        case .present:
            return .resolved
        case .missing:
            // Intentional feedback keeps the stale reference; it is explained,
            // never re-pointed.
            return .targetMissing
        case nil:
            return .unresolvable
        }
    }

    /// The draft's reference exactly as it would be submitted.
    private var currentReference: AgentFeedbackReference? {
        guard let bound = draft?.reference else { return nil }
        return reference(
            candidate: bound.candidate, createdAt: bound.createdAt, anchor: anchor
        )
    }

    private func reference(
        candidate: AgentTaskResultSnapshot,
        createdAt: Date,
        anchor: AgentFeedbackLocationAnchor? = nil
    ) -> AgentFeedbackReference {
        AgentFeedbackReference(
            taskID: taskID,
            candidate: candidate,
            artifactKind: .code,
            anchor: anchor ?? self.anchor,
            userText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments,
            createdAt: createdAt
        )
    }

    private func loadAnchorTargets() {
        let generation = UUID()
        anchorLookup = generation
        var paths = changePaths
        // The location the user chose stays resolvable even when a newer
        // result no longer lists that file.
        if !selectedPath.isEmpty, !paths.contains(selectedPath) { paths.append(selectedPath) }
        anchorTargets = anchorTargets.filter { paths.contains($0.key) }
        guard let root = task.map({
            URL(fileURLWithPath: $0.project.canonicalWorktreePath, isDirectory: true)
        }) else { return }
        Task { @MainActor [weak self] in
            for path in paths {
                let count = await AgentFeedbackAnchorTarget.lineCount(
                    of: root.appendingPathComponent(path)
                )
                guard let self, self.anchorLookup == generation else { return }
                let lastKnown = self.anchorTargets[path]?.lineCount
                self.anchorTargets[path] = count.map {
                    .present(lineCount: $0)
                } ?? .missing(lastKnownLineCount: lastKnown)
            }
        }
    }

    /// The sent words now live in the submission. Attachments the transport
    /// did not carry stay here until the user removes them.
    private func startFreshDraft(sent: AgentFeedbackSubmission) {
        text = ""
        let omitted = Set(sent.disclosedOmissions.map(\.attachmentID))
        attachments.removeAll { !omitted.contains($0.id) }
        selectedPath = ""
        draft = nil
        sync(force: true)
    }

    private static func failure(_ fence: AgentFeedbackSubmissionFence)
        -> AgentFeedbackComposerPresentation.Failure {
        switch fence {
        case .duplicateSubmission: .duplicate
        case .invalidReference, .attachmentUnsupported: .unavailable
        }
    }

    private static func failure(_ admission: AgentFeedbackDeliveryAdmission)
        -> AgentFeedbackComposerPresentation.Failure {
        switch admission {
        case .duplicate: .duplicate
        case .limitReached, .continuationRejected(.limitReached): .limitReached
        case .continuationRejected: .notReady
        case .notDurable: .notDurable
        case .unavailable, .invalidRecord: .unavailable
        }
    }
}
