import Foundation

/// An explicit user annotation of an existing task record, not a new criterion
/// or an execution grant. Provider suggestions cannot create these records.
nonisolated struct AgentTaskDecisionReference: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case decision, unresolvedQuestion }
    static let maximumCount = 32
    static let maximumReferenceBytes = 256

    let id: UUID
    let kind: Kind
    /// Opaque redacted identifier, never a prompt, transcript, path or secret.
    let reference: String
    /// The attempt the user annotated. Absence after retention is disclosed.
    let runID: UUID
    let revision: UInt64
    let recordedAt: Date

    var isValid: Bool {
        revision > 0 && recordedAt.timeIntervalSince1970.isFinite
            && !reference.isEmpty && reference.utf8.count <= Self.maximumReferenceBytes
            && !reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Factual, local projection of existing durable metadata; never a model summary
/// or a claim that the provider's conversation has been restored.
nonisolated struct AgentTaskBrief: Equatable, Sendable {
    enum ReferenceState: Equatable, Sendable {
        case notResolved
        case available
        case unavailable
        case expired
    }

    struct Annotation: Equatable, Sendable, Identifiable {
        let record: AgentTaskDecisionReference
        let state: ReferenceState
        let attemptRetained: Bool
        var id: UUID { record.id }
    }

    let taskID: UUID
    let objective: String?
    /// Goal version the objective text is at. `0` means no goal was recorded;
    /// evidence made against an older version is disclosed by the verification
    /// state, not by rewriting the historical records.
    let objectiveRevision: UInt64
    let latestAttempt: AgentTaskRun?
    let reviewedResult: AgentTaskResultSnapshot?
    let acceptedResult: AgentTaskResultSnapshot?
    let verification: AgentTaskVerificationState
    let environment: AgentTaskEnvironmentIdentity?
    let feedback: [AgentTaskFeedbackRecord]
    let annotations: [Annotation]

    /// Resolution is supplied by the owning surface. Merely having a stored
    /// identifier never proves that its referenced content is still available.
    init(task: AgentTask, referenceStates: [UUID: ReferenceState] = [:]) {
        taskID = task.id
        objective = task.objective
        objectiveRevision = task.objectiveRevision
        latestAttempt = task.runs.last
        reviewedResult = task.reviewedSnapshot
        acceptedResult = task.acceptedSnapshot
        verification = task.verificationState
        environment = task.environment
        feedback = task.feedback
        annotations = task.decisionReferences.map { record in
            Annotation(
                record: record,
                state: referenceStates[record.id] ?? .notResolved,
                attemptRetained: task.runs.contains { $0.id == record.runID }
            )
        }
    }
}
