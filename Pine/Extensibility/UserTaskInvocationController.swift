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
        let runStore = projectManager.taskRunStore
        let run = runStore.start(
            UserTaskRun(
                taskID: task.id,
                taskLabel: task.label,
                command: task.command,
                replacesFileContent: task.replacesFileContent
            )
        )
        run.markRunning()
        runTask(
            task,
            currentActiveTab?.url,
            projectManager.workspace.rootURL,
            snapshot.content
        ) { outcome in
            Task { @MainActor in
                run.applyOutcome(
                    stdout: outcome.stdout,
                    stderr: outcome.stderr,
                    exitCode: outcome.exitCode,
                    timedOut: outcome.timedOut,
                    cancelled: false
                )
                presentOutcome(
                    outcome,
                    cancelled: false,
                    task: task,
                    run: run,
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
        cancelled: Bool,
        task: UserTask,
        run: UserTaskRun,
        projectManager: ProjectManager,
        snapshot: InvocationSnapshot
    ) {
        // Always log for diagnostics (parity with the previous behaviour).
        if outcome.succeeded {
            Logger.extensibility.info(
                "Task '\(task.label)' completed successfully"
            )
        } else {
            Logger.extensibility.error(
                "Task '\(task.label)' failed (exit \(outcome.exitCode)): \(outcome.stderr)"
            )
        }

        // A cancelled run needs no further UI — the output surface already
        // reflects the cancelled state.
        if cancelled { return }

        // Fail closed for replacement-content tasks: only apply stdout when
        // the active tab is unchanged. When the buffer moved, keep the newer
        // edits and offer Copy / Open Output so the user can recover the
        // output without clobbering their work.
        if task.replacesFileContent {
            guard let owner = snapshot.context.nsWindow,
                  owner.isVisible,
                  !owner.isMiniaturized else {
                return
            }
            guard outcome.succeeded, !cancelled else {
                projectManager.taskRunStore.isOutputVisible = true
                return
            }
            let tabManager = projectManager.activeTabManager
            if canApplyReplacement(
                capturedTabID: capturedTabID,
                capturedContent: capturedContent,
                currentTabID: tabManager.activeTab?.id,
                currentContent: tabManager.activeTab?.content
            ) {
                tabManager.updateContent(outcome.stdout)
                // Simple success: brief, accessible toast. The output surface
                // is kept available but not force-shown for a clean apply.
                if outcome.succeeded {
                    projectManager.toastManager.show(
                        ToastItem(message: Strings.userTaskToastSucceeded(task.label))
                    )
                }
                return
            }
            // Conflict: fail closed. Surface the output panel with Copy/Open
            // actions so the user can recover stdout without losing edits.
            presentReplacementConflict(
                run: run,
                projectManager: projectManager,
                context: snapshot.context
            )
            return
        }

        // Non-replacement tasks: a clean success with no output is reported
        // via a brief toast; failures or any captured output are routed to
        // the durable output surface for inspection.
        if outcome.succeeded && !run.hasOutput {
            projectManager.toastManager.show(
                ToastItem(message: Strings.userTaskToastSucceeded(task.label))
            )
        } else {
            // Make sure the output surface is visible so the user sees the
            // failure / captured output.
            projectManager.taskRunStore.isOutputVisible = true
        }
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
        run: UserTaskRun,
        projectManager: ProjectManager,
        context: DialogPresentationContext
    ) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Strings.userTaskOutputConflictTitle
            alert.informativeText = Strings.userTaskOutputConflictMessage
            // Offer safe recovery actions: Copy the captured stdout to the
            // pasteboard, and reveal the output surface for inspection.
            alert.addButton(withTitle: Strings.userTaskCopyOutput)
            alert.addButton(withTitle: Strings.userTaskOpenOutput)
            alert.addButton(withTitle: Strings.dialogOK)
            let response = await alert.runSheet(on: context)
            guard let owner = context.nsWindow,
                  owner.isVisible,
                  !owner.isMiniaturized else {
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.stdout, forType: .string)
            case .alertSecondButtonReturn:
                projectManager.taskRunStore.isOutputVisible = true
            default:
                break
            }
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
