//
//  OpenCodeTaskSubmission.swift
//  Pine
//
//  The Request-submission state behind `OpenCodeTaskView` and the Pine 3
//  workspace composer (#1760). One instance is one draft: a draft creates at
//  most one durable task, and a later Send either continues that task's live
//  session or explicitly retries the launch of that same task.
//

import Foundation
import Observation

/// A request cannot become a durable task because it is longer than the task
/// store admits. Thrown before anything is created or sent.
nonisolated enum OpenCodeTaskLaunchError: Error, Equatable, Sendable {
    case instructionTooLong
}

/// Why a submission did not go out, for the truthful caption.
nonisolated enum OpenCodeTaskSubmissionFailure: Equatable, Sendable {
    /// A dispatch or launch was not confirmed. Pine did not retry it.
    case actionFailed
    /// The text is longer than a durable task can store. Nothing was created or sent.
    case instructionTooLong
}

/// The admission rules a new task's goal and title must satisfy. Shared by the
/// registry, which enforces them, and the submission, which explains them.
nonisolated enum OpenCodeTaskLaunchValidation {
    /// The first non-empty line becomes the task title, exactly as the registry derives it.
    static func title(of instruction: String) -> String {
        instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// `true` when `instruction` is stored as a task goal: non-blank, within the
    /// objective limit, and with a title line within the title limit.
    static func isValid(_ instruction: String, limits: AgentTaskPersistenceLimits) -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= limits.maxObjectiveBytes else { return false }
        return title(of: text).utf8.count <= limits.maxTitleBytes
    }
}

/// One Request draft and everything a Send does with it.
///
/// Only an explicit `send()` leaves this object; creating or restoring it
/// starts nothing. Once the registry has created the task, `taskID` is set and
/// stays set, so a Send after a failed launch continues that task instead of
/// creating a second one.
@MainActor
@Observable
final class OpenCodeTaskSubmission {
    let registry: ProjectRegistry
    let project: AgentTaskProjectIdentity
    var input = ""
    /// The task this draft created, known from the moment the durable task exists.
    private(set) var taskID: UUID?
    private(set) var isSending = false
    private(set) var failure: OpenCodeTaskSubmissionFailure?

    init(registry: ProjectRegistry, project: AgentTaskProjectIdentity) {
        self.registry = registry
        self.project = project
    }

    var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The live session of the task this draft created, when one is attached.
    var runtime: OpenCodeACPTaskRuntime? {
        taskID.flatMap { registry.openCodeRuntime(for: $0) }
    }

    /// Too long to become a task, under the limit the registry itself enforces.
    var isTooLong: Bool {
        !trimmedInput.isEmpty
            && !OpenCodeTaskLaunchValidation.isValid(
                trimmedInput, limits: registry.agentTasks.persistenceLimits
            )
    }

    /// The caption the user sees for the last attempt, if it did not go out.
    var showsFailure: Bool { failure != nil }

    /// `true` once this draft created its task but the launch was not confirmed.
    /// The text is now the task's recorded goal: the next Send starts that task
    /// with it, so the field must not be edited.
    var isAwaitingRetry: Bool {
        guard let taskID, failure != nil else { return false }
        return registry.openCodeRuntime(for: taskID) == nil
    }

    /// Sends the draft. With a live session this is feedback into that session;
    /// otherwise it starts the task — or retries the launch of the task this
    /// draft already created.
    @discardableResult
    func send() -> Task<Void, Never> {
        let text = input
        if let taskID, let runtime = registry.openCodeRuntime(for: taskID) {
            return perform { [weak self] in
                _ = try await runtime.submit(text)
                self?.input = ""
            }
        }
        return perform { [weak self] in
            guard let self else { return }
            if let taskID = self.taskID {
                // The launch failed after the task existed: start that task,
                // never create another.
                try await self.registry.retryOpenCodeTaskLaunch(taskID: taskID)
            } else {
                self.taskID = try await self.registry.startOpenCodeTask(
                    instruction: text, project: self.project,
                    onTaskCreated: { [weak self] created in self?.taskID = created }
                )
            }
            self.input = ""
        }
    }

    /// Runs one session control (cancel, answer, permission) and records its
    /// outcome the same way `send()` records a launch.
    @discardableResult
    func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        isSending = true
        failure = nil
        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSending = false }
            do {
                try await operation()
            } catch is OpenCodeTaskLaunchError {
                failure = .instructionTooLong
            } catch {
                failure = .actionFailed
            }
        }
    }
}
