//
//  AgentFeedbackReference.swift
//  Pine
//
//  Revision-bound feedback reference model (#1758).
//
//  A bounded reference points at one checked revision of one task: the
//  candidate the user was viewing, the artifact kind, a supported location
//  anchor, explicit user text, and content-addressed attachments. The
//  reference stays bound to that revision across newer candidates and
//  relaunch; nothing here re-targets itself. #1756's continuation contract
//  consumes these references; #1725 presents them.
//

import Foundation

/// The kind of result artifact a feedback reference points at.
///
/// Unknown future kinds fail closed to ``unsupported``: the reference stays
/// readable, but its anchor is unresolvable rather than misread.
nonisolated enum AgentFeedbackArtifactKind: String, Codable, Sendable {
    case visualPreview
    case code
    case document
    case commandOutput
    case plainText
    case unsupported

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unsupported
    }
}

/// A supported location anchor inside the referenced artifact.
///
/// ``capturedRegion`` is a pixel rectangle in the captured image itself,
/// never window coordinates. ``semanticElement`` exists only because a real
/// supported integration may report it; Pine never synthesizes element
/// context and never assumes DOM access for native apps.
nonisolated enum AgentFeedbackLocationAnchor: Codable, Hashable, Sendable {
    static let maximumPixelCoordinate: UInt32 = 1_000_000
    static let maximumLine = 1_000_000
    static let maximumSelectionLength: UInt32 = 10_000_000
    static let maximumPathBytes = 4_096
    static let maximumCommandBytes = 512

    /// Explicitly captured region of a visual artifact (pixels in the
    /// captured image).
    case capturedRegion(x: UInt32, y: UInt32, width: UInt32, height: UInt32)
    /// 1-based inclusive line range in one worktree-relative file.
    case lineRange(path: String, start: UInt32, end: UInt32)
    /// 1-based inclusive line range inside the output of one command.
    case outputLines(command: String, start: UInt32, end: UInt32)
    /// UTF-16 offsets (the text system's coordinate space) in one
    /// worktree-relative document.
    case documentSelection(path: String, start: UInt32, length: UInt32)
    /// Semantic element context supplied by a real supported integration.
    case semanticElement(source: String, identifier: String)
    /// No positional anchor: the user text and attachments carry the
    /// reference. This is the keyboard/VoiceOver path to the same target.
    case plainText
    /// A future anchor this version cannot interpret: readable, unresolvable.
    case unsupported(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case x, y, width, height
        case path
        case start, end
        case length
        case command
        case source, identifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "capturedRegion":
            self = .capturedRegion(
                x: try values.decode(UInt32.self, forKey: .x),
                y: try values.decode(UInt32.self, forKey: .y),
                width: try values.decode(UInt32.self, forKey: .width),
                height: try values.decode(UInt32.self, forKey: .height)
            )
        case "lineRange":
            self = .lineRange(
                path: try values.decode(String.self, forKey: .path),
                start: try values.decode(UInt32.self, forKey: .start),
                end: try values.decode(UInt32.self, forKey: .end)
            )
        case "outputLines":
            self = .outputLines(
                command: try values.decode(String.self, forKey: .command),
                start: try values.decode(UInt32.self, forKey: .start),
                end: try values.decode(UInt32.self, forKey: .end)
            )
        case "documentSelection":
            self = .documentSelection(
                path: try values.decode(String.self, forKey: .path),
                start: try values.decode(UInt32.self, forKey: .start),
                length: try values.decode(UInt32.self, forKey: .length)
            )
        case "semanticElement":
            self = .semanticElement(
                source: try values.decode(String.self, forKey: .source),
                identifier: try values.decode(String.self, forKey: .identifier)
            )
        case "plainText":
            self = .plainText
        // Fail closed: an unknown future kind stays readable, unresolvable.
        default:
            self = .unsupported(try values.decode(String.self, forKey: .kind))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .capturedRegion(x, y, width, height):
            try values.encode("capturedRegion", forKey: .kind)
            try values.encode(x, forKey: .x)
            try values.encode(y, forKey: .y)
            try values.encode(width, forKey: .width)
            try values.encode(height, forKey: .height)
        case let .lineRange(path, start, end):
            try values.encode("lineRange", forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(start, forKey: .start)
            try values.encode(end, forKey: .end)
        case let .outputLines(command, start, end):
            try values.encode("outputLines", forKey: .kind)
            try values.encode(command, forKey: .command)
            try values.encode(start, forKey: .start)
            try values.encode(end, forKey: .end)
        case let .documentSelection(path, start, length):
            try values.encode("documentSelection", forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(start, forKey: .start)
            try values.encode(length, forKey: .length)
        case let .semanticElement(source, identifier):
            try values.encode("semanticElement", forKey: .kind)
            try values.encode(source, forKey: .source)
            try values.encode(identifier, forKey: .identifier)
        case .plainText:
            try values.encode("plainText", forKey: .kind)
        case let .unsupported(kind):
            try values.encode(kind, forKey: .kind)
        }
    }

    /// The anchors one artifact kind may carry.
    func isSupported(for kind: AgentFeedbackArtifactKind) -> Bool {
        switch (kind, self) {
        case (.visualPreview, .capturedRegion),
             (.visualPreview, .semanticElement),
             (.visualPreview, .plainText),
             (.code, .lineRange),
             (.code, .semanticElement),
             (.code, .plainText),
             (.document, .documentSelection),
             (.document, .plainText),
             (.commandOutput, .outputLines),
             (.commandOutput, .plainText),
             (.plainText, .plainText),
             (.unsupported, .plainText):
            return true
        default:
            return false
        }
    }

    var isValid: Bool {
        switch self {
        case let .capturedRegion(x, y, width, height):
            return width > 0
                && height > 0
                && x <= Self.maximumPixelCoordinate
                && y <= Self.maximumPixelCoordinate
                && width <= Self.maximumPixelCoordinate
                && height <= Self.maximumPixelCoordinate
        case let .lineRange(path, start, end):
            return AgentHistoryUndoPreflight.isCanonicalRelativePath(path)
                && path.utf8.count <= Self.maximumPathBytes
                && start >= 1 && end >= start && end <= Self.maximumLine
        case let .outputLines(command, start, end):
            return AgentTaskMetadataStore.validText(command, maximum: Self.maximumCommandBytes, allowsEmpty: false)
                && start >= 1 && end >= start && end <= Self.maximumLine
        case let .documentSelection(path, start, length):
            return AgentHistoryUndoPreflight.isCanonicalRelativePath(path)
                && path.utf8.count <= Self.maximumPathBytes
                && start <= Self.maximumSelectionLength
                && length <= Self.maximumSelectionLength
        case let .semanticElement(source, identifier):
            return AgentTaskMetadataStore.validText(source, maximum: 64, allowsEmpty: false)
                && AgentTaskMetadataStore.validText(identifier, maximum: 256, allowsEmpty: false)
        case .plainText:
            return true
        case .unsupported:
            return true
        }
    }

    var isCapturedRegion: Bool {
        if case .capturedRegion = self { return true }
        return false
    }

    /// Canonical form for fingerprinting.
    var fingerprintForm: String {
        switch self {
        case let .capturedRegion(x, y, width, height):
            return "capturedRegion:\(x):\(y):\(width):\(height)"
        case let .lineRange(path, start, end):
            return "lineRange:\(path):\(start):\(end)"
        case let .outputLines(command, start, end):
            return "outputLines:\(command):\(start):\(end)"
        case let .documentSelection(path, start, length):
            return "documentSelection:\(path):\(start):\(length)"
        case let .semanticElement(source, identifier):
            return "semanticElement:\(source):\(identifier)"
        case .plainText:
            return "plainText"
        case let .unsupported(kind):
            return "unsupported:\(kind)"
        }
    }
}

/// The honest basis of a captured attachment.
///
/// ``livePreviewObservation`` marks a screenshot of a live, mutable
/// preview: an observation of what the screen showed, never proof of a
/// verified build.
nonisolated enum AgentFeedbackCaptureBasis: String, Codable, Sendable {
    /// An immutable retained capture: the bytes are fixed and
    /// content-addressed.
    case immutableCapture
    case livePreviewObservation
}

/// A bounded attachment the user explicitly captured for one feedback.
///
/// Attachments reference retained bytes by SHA-256 and size — never by
/// path, never inline. Creation is explicit user action reusing the
/// explicit attachment/retention policy; Pine never records screens,
/// browser sessions, or transcripts continuously.
nonisolated struct AgentFeedbackAttachment: Codable, Hashable, Sendable {
    static let maximumImageBytes: UInt64 = 20 * 1024 * 1024
    static let maximumTextResourceBytes: UInt64 = 1024 * 1024
    static let maximumBinaryBlobBytes: UInt64 = 10 * 1024 * 1024
    static let maximumLabelBytes = 256

    enum Kind: String, Codable, Sendable {
        case image
        case textResource
        case binaryBlob
    }

    let id: UUID
    let kind: Kind
    let captureBasis: AgentFeedbackCaptureBasis
    let sha256: String
    let byteCount: UInt64
    /// Bounded user-facing label. Not a path, never file content.
    let label: String

    init(
        id: UUID,
        kind: Kind,
        captureBasis: AgentFeedbackCaptureBasis = .immutableCapture,
        sha256: String,
        byteCount: UInt64,
        label: String
    ) {
        self.id = id
        self.kind = kind
        self.captureBasis = captureBasis
        self.sha256 = sha256
        self.byteCount = byteCount
        self.label = label
    }

    var byteLimit: UInt64 {
        switch kind {
        case .image: Self.maximumImageBytes
        case .textResource: Self.maximumTextResourceBytes
        case .binaryBlob: Self.maximumBinaryBlobBytes
        }
    }

    var isValid: Bool {
        AgentTaskMetadataStore.validLowerHex(sha256, length: 64)
            && byteCount > 0
            && byteCount <= byteLimit
            // Non-image resources are always immutable retained files.
            && (kind == .image || captureBasis == .immutableCapture)
            && AgentTaskMetadataStore.validText(label, maximum: Self.maximumLabelBytes, allowsEmpty: false)
    }
}

/// A bounded feedback reference bound to one checked revision (#1758).
///
/// ``candidate`` carries the result/candidate identity (#1753): the
/// settled run plus the code-state and environment it was recorded against.
/// The reference never re-targets: a newer candidate arriving later does
/// not change this value.
nonisolated struct AgentFeedbackReference: Codable, Hashable, Sendable {
    static let currentScheme: UInt8 = 1
    static let maximumUserTextBytes = 16 * 1024
    static let maximumArtifactVersionBytes = 128
    static let maximumAttachments = 4

    let scheme: UInt8
    let taskID: UUID
    let candidate: AgentTaskResultSnapshot
    let artifactKind: AgentFeedbackArtifactKind
    /// Bounded opaque artifact version, e.g. a preview-build fingerprint.
    let artifactVersion: String?
    let anchor: AgentFeedbackLocationAnchor
    /// The explicit user text. Always present and always the
    /// keyboard/VoiceOver path to the same target.
    let userText: String
    let attachments: [AgentFeedbackAttachment]
    let createdAt: Date

    init(
        taskID: UUID,
        candidate: AgentTaskResultSnapshot,
        artifactKind: AgentFeedbackArtifactKind,
        artifactVersion: String? = nil,
        anchor: AgentFeedbackLocationAnchor,
        userText: String,
        attachments: [AgentFeedbackAttachment] = [],
        createdAt: Date = Date()
    ) {
        scheme = Self.currentScheme
        self.taskID = taskID
        self.candidate = candidate
        self.artifactKind = artifactKind
        self.artifactVersion = artifactVersion
        self.anchor = anchor
        self.userText = userText
        self.attachments = attachments
        self.createdAt = createdAt
    }

    var isValid: Bool {
        scheme == Self.currentScheme
            && candidate.recordedAt.timeIntervalSinceReferenceDate.isFinite
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && (artifactVersion.map {
                AgentTaskMetadataStore.validText($0, maximum: Self.maximumArtifactVersionBytes, allowsEmpty: false)
            } ?? true)
            && anchor.isValid
            && anchor.isSupported(for: artifactKind)
            && AgentTaskMetadataStore.validText(userText, maximum: Self.maximumUserTextBytes, allowsEmpty: false)
            && !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.count <= Self.maximumAttachments
            && Set(attachments.map(\.id)).count == attachments.count
            && attachments.allSatisfy(\.isValid)
            // A captured region only makes sense against an image.
            && !(artifactKind == .visualPreview
                && anchor.isCapturedRegion
                && !attachments.contains { $0.kind == .image })
    }

    /// The referenced candidate must be an attempt of this task. A run the
    /// task no longer contains leaves an unresolvable reference — it is
    /// explained, never silently re-targeted.
    func candidateIsKnown(to task: AgentTask) -> Bool {
        task.runs.contains { $0.id == candidate.runID }
    }

    /// Deterministic content fingerprint over the whole reference. Two
    /// submissions with the same fingerprint are the same feedback; the
    /// idempotency that keeps duplicate delivery from creating two
    /// revisions keys on it.
    var fingerprint: String {
        var hasher = AgentVerificationCanonicalHasher(domain: "pine.ade.feedback-reference.v1")
        hasher.append("scheme", String(scheme))
        hasher.append("task", taskID.uuidString)
        hasher.append("candidate-run", candidate.runID.uuidString)
        hasher.append("candidate-outcome", candidate.outcome.rawValue)
        hasher.append("candidate-recorded", String(candidate.recordedAt.timeIntervalSince1970))
        hasher.append("candidate-head", candidate.codeState?.headCommit ?? "")
        hasher.append("candidate-tracked", candidate.codeState?.trackedFingerprint ?? "")
        hasher.append("candidate-untracked", candidate.codeState?.untrackedFingerprint ?? "")
        hasher.append("candidate-ignored", candidate.codeState?.ignoredRelevantFingerprint ?? "")
        hasher.append("env-os", candidate.environment?.osBuild ?? "")
        hasher.append("env-toolchain", candidate.environment?.toolchain ?? "")
        hasher.append("env-config", candidate.environment?.configurationFingerprint ?? "")
        hasher.append("artifact-kind", artifactKind.rawValue)
        hasher.append("artifact-version", artifactVersion ?? "")
        hasher.append("anchor", anchor.fingerprintForm)
        hasher.append("user-text", userText)
        for attachment in attachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.append("attachment-id", attachment.id.uuidString)
            hasher.append("attachment-kind", attachment.kind.rawValue)
            hasher.append("attachment-basis", attachment.captureBasis.rawValue)
            hasher.append("attachment-sha", attachment.sha256)
            hasher.append("attachment-bytes", String(attachment.byteCount))
            hasher.append("attachment-label", attachment.label)
        }
        hasher.append("created-at", String(createdAt.timeIntervalSince1970))
        return hasher.finish()
    }

    /// The explicit text-only form for transports that cannot carry
    /// resources. The candidate binding and text are unchanged; a
    /// ``AgentFeedbackLocationAnchor/capturedRegion`` degrades to
    /// ``AgentFeedbackLocationAnchor/plainText`` because the region only
    /// makes sense against the image. Returns `self` when the reference
    /// already carries no attachments.
    var textOnlyVariant: AgentFeedbackReference {
        let anchor: AgentFeedbackLocationAnchor
        switch self.anchor {
        case .capturedRegion where !attachments.isEmpty:
            anchor = .plainText
        default:
            anchor = self.anchor
        }
        return AgentFeedbackReference(
            taskID: taskID,
            candidate: candidate,
            artifactKind: artifactKind,
            artifactVersion: artifactVersion,
            anchor: anchor,
            userText: userText,
            attachments: [],
            createdAt: createdAt
        )
    }
}

/// How the draft's viewed candidate relates to the task's latest candidate.
///
/// Every non-``current`` value must be explained to the user (a newer
/// candidate arrived, or an intentional older result). None of them
/// re-targets the reference.
nonisolated enum AgentFeedbackRevisionFreshness: Codable, Hashable, Sendable {
    /// The viewed candidate is still the latest settled candidate.
    case current
    /// A newer candidate arrived after the draft was created.
    case superseded(latestRunID: UUID)
    /// The draft was intentionally bound to a non-latest candidate.
    case historical(latestRunID: UUID)
}

/// A work-in-progress feedback bound to the revision the user is viewing.
///
/// The draft keeps its candidate binding no matter how many newer
/// candidates arrive while the user composes; ``freshness`` is the
/// computed explanation. Re-pointing at another revision is a new draft,
/// never a silent edit of ``candidate``.
nonisolated struct AgentFeedbackDraft: Codable, Hashable, Sendable {
    let id: UUID
    var reference: AgentFeedbackReference
    var freshness: AgentFeedbackRevisionFreshness

    init(reference: AgentFeedbackReference, id: UUID = UUID()) {
        self.id = id
        self.reference = reference
        self.freshness = .current
    }

    /// Recomputes the freshness explanation against the latest settled
    /// candidate. Never mutates ``reference``. A same-instant arrival is
    /// classified ``superseded``, not ``historical``: ambiguity resolves
    /// to "a newer candidate arrived", never to asserted user intent.
    mutating func noteCandidateArrived(_ latest: AgentTaskResultSnapshot) {
        if latest == reference.candidate {
            freshness = .current
        } else if latest.recordedAt >= reference.createdAt {
            freshness = .superseded(latestRunID: latest.runID)
        } else {
            freshness = .historical(latestRunID: latest.runID)
        }
    }
}

/// How the anchor resolved when the user submitted.
///
/// A non-``resolved`` value is shown to the user as an obsolete-anchor
/// explanation; it never re-targets the reference, and intentional
/// feedback on an older result stays submittable.
nonisolated enum AgentFeedbackAnchorResolution: String, Codable, Sendable {
    case resolved
    /// The anchor's target no longer exists in the current worktree
    /// (deleted or renamed) or the artifact is missing.
    case targetMissing
    /// The artifact kind or anchor cannot be resolved at all (for example
    /// a future anchor kind this version cannot interpret).
    case unresolvable
}
