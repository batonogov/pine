//
//  UserTaskInvocationController.swift
//  Pine
//
//  One safety-preserving task invocation path shared by the Tasks menu and
//  command palette (issue #1117). Shell text always comes directly from the
//  validated task definition; editor selections, terminal output, and
//  OSC-derived paths are never interpolated into it.
//

import AppKit
import Foundation
import os

@MainActor
enum UserTaskInvocationController {
    typealias ConfirmationPresenter = @MainActor (
        UserTask,
        DialogPresentationContext
    ) async -> Bool
    typealias TaskRunner = @MainActor (
        UserTask,
        URL?,
        URL?,
        String?,
        @escaping @Sendable (UserTaskOutcome) -> Void
    ) -> Void

    private struct InvocationSnapshot {
        let tabID: UUID?
        let content: String?
        let context: DialogPresentationContext
    }

    static func invoke(
        _ task: UserTask,
        projectManager: ProjectManager
    ) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            _ = await invokePrepared(
                task,
                projectManager: projectManager,
                context: context,
                presentConfirmation: { task, context in
                    await presentConfirmation(for: task, context: context)
                },
                runTask: { task, fileURL, projectRootURL, fileContent, completion in
                    UserTaskRunner.shared.run(
                        task: task,
                        fileURL: fileURL,
                        projectRootURL: projectRootURL,
                        fileContent: fileContent,
                        completion: completion
                    )
                }
            )
        }
    }

    /// Resolves and validates the active-file intent on the MainActor
    /// immediately before the runner starts. Kept internal so suspension
    /// races can be tested without spawning a real shell.
    @discardableResult
    static func invokePrepared(
        _ task: UserTask,
        projectManager: ProjectManager,
        context: DialogPresentationContext,
        presentConfirmation: ConfirmationPresenter,
        runTask: TaskRunner
    ) async -> Bool {
        guard let owner = context.nsWindow,
              owner.isVisible,
              !owner.isMiniaturized else {
            return false
        }

        let initialActiveTab = projectManager.activeTabManager.activeTab
        if task.scope == .activeFile, initialActiveTab == nil {
            presentMissingActiveFile(context: context)
            return false
        }

        if task.effectiveRequireConfirmation(),
           !(await presentConfirmation(task, context)) {
            return false
        }
        guard let currentOwner = context.nsWindow,
              currentOwner === owner,
              currentOwner.isVisible,
              !currentOwner.isMiniaturized else {
            return false
        }

        let currentActiveTab = projectManager.activeTabManager.activeTab
        if task.scope == .activeFile {
            // The confirmation authorized the exact active-file intent that
            // existed when it appeared. Switching tabs, closing the file, or
            // editing its buffer while suspended must not retarget the task.
            guard let initialActiveTab,
                  let currentActiveTab,
                  currentActiveTab.id == initialActiveTab.id,
                  currentActiveTab.url == initialActiveTab.url,
                  currentActiveTab.content == initialActiveTab.content else {
                return false
            }
        }

        let snapshot = InvocationSnapshot(
            tabID: currentActiveTab?.id,
            content: currentActiveTab?.content,
            context: context
        )
        runTask(
            task,
            currentActiveTab?.url,
            projectManager.workspace.rootURL,
            snapshot.content
        ) { outcome in
            Task { @MainActor in
                presentOutcome(
                    outcome,
                    task: task,
                    projectManager: projectManager,
                    snapshot: snapshot
                )
            }
        }
        return true
    }

    private static func presentConfirmation(
        for task: UserTask,
        context: DialogPresentationContext
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = Strings.userTaskConfirmationTitle(task.label)
        alert.informativeText = Strings.userTaskConfirmationMessage(task.command)
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.userTaskRun)
        let cancelButton = alert.addButton(withTitle: Strings.dialogCancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let response = await alert.runSheet(on: context)
        return response == .alertFirstButtonReturn
    }

    private static func presentOutcome(
        _ outcome: UserTaskOutcome,
        task: UserTask,
        projectManager: ProjectManager,
        snapshot: InvocationSnapshot
    ) {
        guard outcome.succeeded else {
            Logger.extensibility.error(
                "Task '\(task.label)' failed (exit \(outcome.exitCode)): \(outcome.stderr)"
            )
            return
        }

        Logger.extensibility.info(
            "Task '\(task.label)' completed successfully"
        )
        guard task.replacesFileContent else { return }
        guard let owner = snapshot.context.nsWindow,
              owner.isVisible,
              !owner.isMiniaturized else {
            return
        }

        // Fail closed if the user switched tabs or edited the file while the
        // process ran. Applying stdout to a different/newer buffer would lose
        // unrelated work and violate the task's active-file contract.
        let tabManager = projectManager.activeTabManager
        guard canApplyReplacement(
            capturedTabID: snapshot.tabID,
            capturedContent: snapshot.content,
            currentTabID: tabManager.activeTab?.id,
            currentContent: tabManager.activeTab?.content
        ) else {
            presentReplacementConflict(context: snapshot.context)
            return
        }
        tabManager.updateContent(outcome.stdout)
    }

    nonisolated static func canApplyReplacement(
        capturedTabID: UUID?,
        capturedContent: String?,
        currentTabID: UUID?,
        currentContent: String?
    ) -> Bool {
        guard let capturedTabID, let capturedContent else { return false }
        return currentTabID == capturedTabID
            && currentContent == capturedContent
    }

    private static func presentReplacementConflict(
        context: DialogPresentationContext
    ) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Strings.userTaskOutputConflictTitle
            alert.informativeText = Strings.userTaskOutputConflictMessage
            alert.addButton(withTitle: Strings.dialogOK)
            _ = await alert.runSheet(on: context)
        }
    }

    private static func presentMissingActiveFile(
        context: DialogPresentationContext
    ) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Strings.userTaskMissingFileTitle
            alert.informativeText = Strings.userTaskMissingFileMessage
            alert.addButton(withTitle: Strings.dialogOK)
            _ = await alert.runSheet(on: context)
        }
    }
}
