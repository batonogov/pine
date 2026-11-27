//
//  AgentTaskResultHost.swift
//  Pine
//
//  One task's result, embedded in a parent surface (#1725, #1760).
//

import SwiftUI

/// Result actions whose data or authority lives outside the task record.
///
/// The lanes that own them supply each one: verification (#1753–#1755) owns
/// `reverify`, revision comparison (#1758) owns `viewChanges`. Until a lane
/// does, the action is `nil` and `AgentTaskResultView` says so — no stand-in.
struct AgentTaskResultHostActions {
    /// Repeats required checks and independent review for the current candidate.
    var reverify: (@MainActor (UUID) async -> Void)?
    /// Shows what changed since the last reviewed or accepted result.
    var viewChanges: (@MainActor (UUID) -> Void)?

    init(
        reverify: (@MainActor (UUID) async -> Void)? = nil,
        viewChanges: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.reverify = reverify
        self.viewChanges = viewChanges
    }
}

/// Owns the single result controller behind an embedded result.
@MainActor
@Observable
final class AgentTaskResultHostModel {
    private(set) var controller: AgentTaskResultController?

    /// Opens the task's result. Opening changes viewed/unread only: it never
    /// selects a recipe, accepts a result, authorizes a command, or starts an
    /// agent.
    func open(registry: ProjectRegistry, taskID: UUID) {
        open(
            registry: registry, taskID: taskID,
            replyDispatcher: Self.openCodeReplyDispatcher(registry)
        )
    }

    func open(
        registry: ProjectRegistry,
        taskID: UUID,
        replyDispatcher: @escaping AgentTaskResultReplyDispatcher
    ) {
        guard controller == nil,
              let created = AgentTaskResultController(
                registry: registry.agentTasks, taskID: taskID,
                editorPreflight: { registry.verificationEditorPreflight() },
                replyDispatcher: replyDispatcher
              ) else { return }
        controller = created
        _ = registry.agentTasks.setReviewed(true, taskID: taskID)
    }

    /// Ends UI ownership of the result; no live result command outlives it.
    func close() {
        controller?.close()
        controller = nil
    }

    /// The production reply route: the task's own OpenCode session, the same
    /// dispatch the Inbox uses. No live session, no delivery.
    static func openCodeReplyDispatcher(
        _ registry: ProjectRegistry
    ) -> AgentTaskResultReplyDispatcher {
        { text, decision in
            guard let runtime = registry.openCodeRuntime(for: decision.taskID) else {
                return false
            }
            return await runtime.submitResultDecisionReply(text, decision: decision)
        }
    }
}

/// Embeds one task's result in a parent surface and owns its controller for
/// as long as it is shown.
struct AgentTaskResultHost: View {
    let registry: ProjectRegistry
    let taskID: UUID
    var actions = AgentTaskResultHostActions()
    /// `nil` uses the production OpenCode route.
    var replyDispatcher: AgentTaskResultReplyDispatcher?
    @State private var model = AgentTaskResultHostModel()

    var body: some View {
        Group {
            if let controller = model.controller {
                resultView(controller)
            } else {
                ContentUnavailableView(
                    Strings.workspaceTaskUnavailable,
                    systemImage: "questionmark.folder",
                    description: Text(Strings.workspaceTaskUnavailableDetail)
                )
                .accessibilityIdentifier(AccessibilityID.workspaceTaskUnavailable)
            }
        }
        .onAppear {
            model.open(
                registry: registry, taskID: taskID,
                replyDispatcher: replyDispatcher
                    ?? AgentTaskResultHostModel.openCodeReplyDispatcher(registry)
            )
        }
        .onDisappear { model.close() }
    }

    private func resultView(_ controller: AgentTaskResultController) -> some View {
        AgentTaskResultView(
            model: controller.presentation,
            onLaunch: { controller.launchResult() },
            onStop: { controller.stopResult() },
            onViewChanges: actions.viewChanges.map { action in { action(taskID) } },
            onReverify: actions.reverify.map { action in { Task { await action(taskID) } } },
            onReply: { controller.reply($0) },
            onSelectRecipe: controller.proposal == nil ? nil : { controller.selectRecipe() },
            onPrepare: { controller.prepareResult() },
            onCancelPreparation: { controller.cancelPreparation() }
        )
    }
}
