//
//  ADEWorkspaceModel.swift
//  Pine
//
//  State of one project window: the project's tasks, which one is selected,
//  and the task input (#1760).
//

import AppKit
import Observation

/// How the composer sends its text. Chosen only by the explicit mode control,
/// never inferred from the text.
nonisolated enum ADEInputMode: String, CaseIterable, Sendable, Identifiable {
    case request
    case command

    var id: String { rawValue }
}

/// What the composer needs to explain: why Send cannot act, or what a
/// pending Send will do.
nonisolated enum ADEComposerNotice: Equatable, Sendable {
    /// No execution lane is attached yet, so nothing runs in Command mode.
    case commandUnavailable
    /// The selected task has no live agent session. Pine does not resume one on its own.
    case noLiveSession
    /// Late activity has no reliable turn boundary; continuing is unsafe.
    case inputFenced
    /// The launch was not confirmed after the task existed. Send starts that same task.
    case awaitingRetry
    /// Longer than a task can store. Nothing is created or sent.
    case instructionTooLong
}

@MainActor
@Observable
final class ADEWorkspaceModel: AgentTaskSelectionHosting {
    let registry: ProjectRegistry
    /// The root of the one project this window shows.
    let projectURL: URL
    /// New requests are created under this identity: the project root is its own worktree.
    let projectIdentity: AgentTaskProjectIdentity
    /// Supplied by the lane that owns Command execution. `nil` keeps Command mode unavailable.
    let commandRunner: (any CommandRunner)?

    private let selectionStore: ADETaskSelectionStore
    private let announce: (String) -> Void
    private var observerToken: UUID?
    private var hostToken: UUID?
    /// Set by ``activate``; the view's `.task` calls it once. SwiftUI body
    /// re-evaluations construct doomed model instances through
    /// `State(initialValue:)`, so the live wiring must never happen in
    /// `init`: a doomed instance would churn observers and consume a
    /// pending attention selection on its way out (#1760).
    private(set) var isActive = false
    /// A persisted selection waiting for this project's durable task list
    /// to finish loading. An empty list before that is not authoritative,
    /// so the stored selection must be neither applied nor forgotten yet.
    private var pendingRestoredSelection: UUID?
    /// An attention-routing selection waiting for the same load. Held
    /// without touching the store: the store belongs to the user.
    private var pendingRoutingSelection: UUID?

    private(set) var rows: [ADETaskRow]
    /// The task the main area shows; `nil` is the project overview.
    var selectedTaskID: UUID? {
        didSet { selectionDidChange(from: oldValue) }
    }
    var inputMode: ADEInputMode = .request
    /// The composer's text, for whatever it is currently addressing.
    var input = ""
    /// Whether this window is the one the user is looking at. Only then are state changes spoken.
    var isKey = false
    var locale = Locale.current
    /// Set by the "New task" affordances; the overview composer takes focus when it sees it.
    var newTaskFocusRequest: UUID?

    /// The draft that starts a task which does not exist yet.
    private(set) var draft: OpenCodeTaskSubmission
    /// The selected task's live provider session, when one is attached.
    private(set) var liveRuntime: OpenCodeACPTaskRuntime?
    private(set) var isContinuing = false
    private(set) var continuationFailed = false
    private(set) var isRunningCommand = false
    private(set) var commandFailed = false
    private(set) var lastCommandResult: ADECommandResult?

    init(
        registry: ProjectRegistry,
        projectURL: URL,
        commandRunner: (any CommandRunner)? = nil,
        selectionStore: ADETaskSelectionStore = ADETaskSelectionStore(),
        announce: @escaping (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApp.keyWindow ?? NSApp.mainWindow ?? NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    ) {
        self.registry = registry
        self.projectURL = projectURL.standardizedFileURL
        self.commandRunner = commandRunner
        self.selectionStore = selectionStore
        self.announce = announce
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path, canonicalWorktreePath: projectURL.path
        )
        projectIdentity = identity
        draft = OpenCodeTaskSubmission(registry: registry, project: identity)
        rows = ADEWorkspaceProjection.rows(
            from: registry.agentTasks.tasks, projectPath: projectURL.path,
            accuracyPolicy: registry.agentTasks.lifecycleAccuracyPolicy
        )
    }

    /// Mounts the live wiring: task-change observation, the persisted
    /// selection restore, and attention-routing registration. Called once
    /// from the view; safe to call again (idempotent).
    func activate() {
        guard !isActive else { return }
        isActive = true
        observerToken = registry.agentTasks.addTaskChangeObserver { [weak self] _, tasks in
            self?.tasksDidChange(tasks)
        }
        refreshRows(from: registry.agentTasks.tasks)
        restoreSelection()
        hostToken = registry.registerTaskSelectionHost(self)
    }

    isolated deinit {
        if let observerToken {
            registry.agentTasks.removeTaskChangeObserver(observerToken)
        }
        if let hostToken {
            registry.unregisterTaskSelectionHost(hostToken)
        }
    }

    // MARK: - Selection

    var selectedRow: ADETaskRow? {
        rows.first { $0.id == selectedTaskID }
    }

    func selectTask(_ taskID: UUID) {
        refreshRows(from: registry.agentTasks.tasks)
        guard rows.contains(where: { $0.id == taskID }) else {
            // An empty list before the metadata load completes is not
            // authoritative: hold the request instead of refusing a task
            // that is about to arrive (#1760).
            if !taskListIsAuthoritative {
                pendingRoutingSelection = taskID
            }
            return
        }
        // An explicit selection supersedes whatever was waiting for the load.
        pendingRoutingSelection = nil
        pendingRestoredSelection = nil
        selectedTaskID = taskID
    }

    /// The "New task" affordance: back to the overview with an empty composer.
    func startNewTask() {
        // The user superseded any selection that was waiting for the load.
        pendingRestoredSelection = nil
        pendingRoutingSelection = nil
        selectedTaskID = nil
        draft = OpenCodeTaskSubmission(registry: registry, project: projectIdentity)
        input = ""
    }

    /// A persisted selection is applied or forgotten only against a durable
    /// task list that has finished loading (#1760).
    private func restoreSelection() {
        guard let stored = selectionStore.taskID(forProject: projectURL.path) else { return }
        guard taskListIsAuthoritative else {
            pendingRestoredSelection = stored
            settlePendingSelectionsAfterLoad()
            return
        }
        restorePersistedSelection(stored)
    }

    /// Whether the durable task list is final for now. A completed load is
    /// authoritative even when it found nothing (`.missing`); a rejected
    /// read proves nothing about which tasks exist, so it never justifies
    /// forgetting a persisted selection.
    private var taskListIsAuthoritative: Bool {
        switch registry.agentTasks.metadataLoadStatus(for: projectIdentity) {
        case .loaded, .loadedWithMissingWorktrees, .missing: true
        case .rejected, nil: false
        }
    }

    private func restorePersistedSelection(_ stored: UUID) {
        if rows.contains(where: { $0.id == stored }) {
            selectedTaskID = stored
            refreshLiveRuntime()
        } else {
            // The task is gone or belongs to another project: forget it.
            selectionStore.set(nil, forProject: projectURL.path)
        }
    }

    /// Spends the selections that were waiting for the metadata load. Runs
    /// on every task change after activation: the completed load that
    /// carries this project's tasks fires the observer with the load status
    /// already recorded, so the first post-load projection decides both
    /// cases — apply when the task is listed, forget only once the task is
    /// confirmed absent. A rejected load keeps everything pending.
    private func applyPendingSelections() {
        guard taskListIsAuthoritative else { return }
        if let stored = pendingRestoredSelection {
            pendingRestoredSelection = nil
            restorePersistedSelection(stored)
        }
        if let routed = pendingRoutingSelection {
            pendingRoutingSelection = nil
            if rows.contains(where: { $0.id == routed }) {
                selectedTaskID = routed
            }
        }
    }

    /// A load that completes without a task change — an empty store
    /// (`.missing`) or a rejected one — fires no observer, so a pending
    /// restore needs one deferred decision point after the admission read
    /// has had its turn. Bounded; no-op once the load is spent.
    private func settlePendingSelectionsAfterLoad() {
        let project = projectIdentity
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard let self else { return }
                if self.registry.agentTasks.metadataLoadStatus(for: project) != nil {
                    self.applyPendingSelections()
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func selectionDidChange(from previous: UUID?) {
        guard previous != selectedTaskID else { return }
        selectionStore.set(selectedTaskID, forProject: projectURL.path)
        input = ""
        continuationFailed = false
        sessionActionFailed = false
        lastCommandResult = nil
        commandFailed = false
        refreshLiveRuntime()
    }

    // MARK: - Tasks

    var hasTasks: Bool { !rows.isEmpty }

    private func tasksDidChange(_ tasks: [AgentTask]) {
        let before = rows
        refreshRows(from: tasks)
        // A selection follows its task out of the list: dismissed, or no longer this project's.
        if let selectedTaskID, !rows.contains(where: { $0.id == selectedTaskID }) {
            self.selectedTaskID = nil
        }
        applyPendingSelections()
        announceAttentionChanges(from: before)
        refreshLiveRuntime()
    }

    private func refreshRows(from tasks: [AgentTask]) {
        let updated = ADEWorkspaceProjection.rows(
            from: tasks, projectPath: projectURL.path,
            accuracyPolicy: registry.agentTasks.lifecycleAccuracyPolicy
        )
        if updated != rows { rows = updated }
    }

    private func refreshLiveRuntime() {
        liveRuntime = selectedTaskID.flatMap { registry.openCodeRuntime(for: $0) }
    }

    /// Speaks a task that just became Ready or came to need a decision — the
    /// only two states that warrant attention.
    private func announceAttentionChanges(from previous: [ADETaskRow]) {
        guard isKey else { return }
        let before = Dictionary(
            previous.map { ($0.id, $0.indicator) }, uniquingKeysWith: { first, _ in first }
        )
        for row in rows {
            guard row.indicator.warrantsAttention,
                  let old = before[row.id], old != row.indicator else { continue }
            announce("\(row.goal), \(row.indicator.title(neverStarted: row.neverStarted, locale: locale))")
        }
    }

    // MARK: - Task input

    var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBusy: Bool {
        draft.isSending || isContinuing || isRunningCommand
    }

    private var inputIsTooLong: Bool {
        !trimmedInput.isEmpty && !OpenCodeTaskLaunchValidation.isValid(
            trimmedInput, limits: registry.agentTasks.persistenceLimits
        )
    }

    /// A pending retry sends the task's recorded goal, so the text is not editable.
    var inputIsEditable: Bool {
        !(selectedTaskID == nil && draft.isAwaitingRetry)
    }

    /// Why Send cannot act for the mode and task the user chose.
    var notice: ADEComposerNotice? {
        switch inputMode {
        case .command:
            return commandRunner == nil ? .commandUnavailable : nil
        case .request:
            guard selectedTaskID != nil else {
                if inputIsTooLong { return .instructionTooLong }
                return draft.isAwaitingRetry ? .awaitingRetry : nil
            }
            guard let liveRuntime else { return .noLiveSession }
            return liveRuntime.snapshot?.inputFenced == true ? .inputFenced : nil
        }
    }

    /// The last attempt that did not go out.
    var failure: OpenCodeTaskSubmissionFailure? {
        switch inputMode {
        case .command:
            return commandFailed ? .actionFailed : nil
        case .request:
            guard selectedTaskID != nil else { return draft.failure }
            return continuationFailed ? .actionFailed : nil
        }
    }

    var canSend: Bool {
        guard !isBusy, !trimmedInput.isEmpty else { return false }
        switch inputMode {
        case .command:
            return commandRunner != nil
        case .request:
            guard let selectedTaskID else { return !inputIsTooLong }
            return liveRuntime?.isActive == true && liveRuntime?.snapshot?.inputFenced != true
        }
    }

    /// The composer's Send. Nothing else in the workspace submits, and
    /// restoring a selection never calls it.
    func send() async {
        guard canSend else { return }
        switch (inputMode, selectedTaskID) {
        case (.command, _):
            await runCommand()
        case (.request, nil):
            await submitNewTaskDraft()
        case (.request, .some):
            await continueTask()
        }
    }

    /// The async half of Send on the overview: creates the durable task for
    /// this draft. Deliberately named apart from `startNewTask()` — the two
    /// differ only by `async`, and an unqualified call must never silently
    /// rank to the synchronous overview reset.
    private func submitNewTaskDraft() async {
        let submitted = draft
        submitted.input = input
        await submitted.send().value
        guard submitted.failure == nil, let taskID = submitted.taskID else { return }
        input = ""
        refreshRows(from: registry.agentTasks.tasks)
        selectedTaskID = taskID
        refreshLiveRuntime()
        // The next task starts from an empty draft.
        draft = OpenCodeTaskSubmission(registry: registry, project: projectIdentity)
    }

    private func continueTask() async {
        guard let liveRuntime else { return }
        isContinuing = true
        defer { isContinuing = false }
        do {
            _ = try await liveRuntime.submit(input)
            input = ""
            continuationFailed = false
        } catch {
            continuationFailed = true
        }
    }

    private func runCommand() async {
        guard let commandRunner else { return }
        isRunningCommand = true
        defer { isRunningCommand = false }
        do {
            lastCommandResult = try await commandRunner.run(
                input,
                in: ADECommandEnvironment(project: projectIdentity, taskID: selectedTaskID)
            )
            commandFailed = false
            input = ""
        } catch {
            commandFailed = true
        }
    }

    // MARK: - Live session controls

    private(set) var sessionActionFailed = false

    /// Runs one explicit session control (cancel, answer, permission). It is
    /// the only path to those controls from the workspace.
    func performSessionAction(
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        isContinuing = true
        sessionActionFailed = false
        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isContinuing = false }
            do {
                try await operation()
            } catch {
                sessionActionFailed = true
            }
        }
    }

    // MARK: - AgentTaskSelectionHosting

    var hostedProjectURL: URL { projectURL }
}
