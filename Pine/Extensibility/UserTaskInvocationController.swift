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
        UserTaskProgress
    ) -> UserTaskCancellation

    private struct InvocationSnapshot {
        let tab: CapturedTab
        let context: DialogPresentationContext
    }

    static func invoke(
        _ task: UserTask,
        projectManager: ProjectManager
    ) {
        Task { @MainActor in
            // The project window's NSWindow delegate may not have registered
            // its dialog owner binding on the very first run-loop tick after
            // scene creation. Wait for it so the confirmation and output
            // surfaces always have a valid sheet parent.
            guard let owner = await projectManager.awaitDialogOwnerWindow() else {
                return
            }
            let context = DialogPresenter.context(for: owner)
            _ = await invokePrepared(
                task,
                projectManager: projectManager,
                context: context,
                presentConfirmation: { task, context in
                    await presentConfirmation(for: task, context: context)
                },
                runTask: { task, fileURL, projectRootURL, fileContent, progress in
                    UserTaskRunner.shared.run(
                        task: task,
                        fileURL: fileURL,
                        projectRootURL: projectRootURL,
                        fileContent: fileContent,
                        progress: progress
                    )
                }
            )
        }
    }

    /// Active-file tasks require a real filesystem destination. An untitled
    /// buffer's private identity URI is never a valid `${file}` value.
    static func hasRequiredActiveFile(
        for task: UserTask,
        activeTab: EditorTab?
    ) -> Bool {
        task.scope != .activeFile || activeTab?.fileURL != nil
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

        let activeTab = projectManager.activeTabManager.activeTab
        if !hasRequiredActiveFile(
            for: task,
            activeTab: activeTab
        ) {
            await presentMissingActiveFile(context: context)
            return false
        }
        if task.replacesFileContent,
           !replacementTargetIsEligible(
               scope: task.scope,
               isText: activeTab?.kind == .text,
               isTruncated: activeTab?.isTruncated
           ) {
            await presentIneligibleReplacement(context: context)
            return false
        }

        let capturedTab = capture(activeTab)
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

        if task.scope == .activeFile {
            // The confirmation authorized the exact active-file intent that
            // existed when it appeared. Switching tabs, closing the file, or
            // editing its buffer while suspended must not retarget the task.
            guard capturedTab == capture(
                projectManager.activeTabManager.activeTab
            ) else {
                return false
            }
        }

        let snapshot = InvocationSnapshot(
            tab: capturedTab,
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

        let cancellation = runTask(
            task,
            capturedTab.url,
            projectManager.workspace.rootURL,
            capturedTab.content,
            UserTaskProgress(
                onStart: { @Sendable in
                    Task { @MainActor in
                        run.markRunning()
                    }
                },
                onFinish: { @Sendable outcome, cancelled in
                    Task { @MainActor in
                        guard runStore.finishRun(
                            id: run.id,
                            outcome: outcome,
                            cancelled: cancelled
                        ) else { return }
                        presentOutcome(
                            outcome,
                            task: task,
                            run: run,
                            projectManager: projectManager,
                            snapshot: snapshot
                        )
                    }
                }
            )
        )
        // Registration is synchronous, eliminating the cancel-before-handle
        // gap while preserving the runner's callback API for other clients.
        runStore.registerCancellation(cancellation, forRunID: run.id)
        return true
    }

    private static func presentConfirmation(
        for task: UserTask,
        context: DialogPresentationContext
    ) async -> Bool {
        let response = await AlertTemplate.userTaskRunConfirmation.runSheet(
            on: context,
            messageText: Strings.userTaskConfirmationTitle(task.label),
            informativeText: Strings.userTaskConfirmationMessage(task.command)
        )
        return response == .alertFirstButtonReturn
    }

    /// Snapshot of the active tab captured before a task runs, used to detect
    /// whether the buffer changed while the task was executing.
    nonisolated struct CapturedTab: Equatable, Sendable {
        let id: UUID?
        let url: URL?
        let content: String?
        let contentVersion: UInt64?
        let isEligibleForReplacement: Bool
    }

    private static func capture(_ tab: EditorTab?) -> CapturedTab {
        CapturedTab(
            id: tab?.id,
            url: tab?.fileURL?.standardizedFileURL,
            content: tab?.content,
            contentVersion: tab?.contentVersion,
            isEligibleForReplacement:
                tab?.kind == .text && tab?.isTruncated == false
        )
    }

    private static func presentOutcome(
        _ outcome: UserTaskOutcome,
        task: UserTask,
        run: UserTaskRun,
        projectManager: ProjectManager,
        snapshot: InvocationSnapshot
    ) {
        // Always log for diagnostics (parity with the previous behaviour).
        if outcome.succeeded, run.state != .cancelled {
            Logger.extensibility.info(
                "Task '\(task.label)' completed successfully"
            )
        } else {
            Logger.extensibility.error(
                "Task '\(task.label)' failed (exit \(outcome.exitCode)): \(outcome.stderr)"
            )
        }

        // Fail closed for replacement-content tasks: only apply stdout when
        // the process completed successfully and the active tab is unchanged.
        // Failed, timed-out, spawn-failed, and cancelled runs may contain
        // partial stdout, which must never overwrite the editor buffer.
        if task.replacesFileContent {
            guard let owner = snapshot.context.nsWindow,
                  owner.isVisible,
                  !owner.isMiniaturized else {
                return
            }
            let tabManager = projectManager.activeTabManager
            if canApplyReplacement(
                outcome: outcome,
                cancelled: run.state == .cancelled,
                captured: snapshot.tab,
                current: capture(tabManager.activeTab)
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

            // Process failures are already durable in the run model. Reveal
            // that output without presenting the edit-conflict recovery
            // dialog, because no replacement is eligible to apply.
            guard outcome.succeeded, run.state != .cancelled else {
                projectManager.taskRunStore.isOutputVisible = true
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

        // A cancelled non-replacement run needs no further UI — the output
        // surface already reflects the cancelled state.
        if run.state == .cancelled { return }

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
        outcome: UserTaskOutcome,
        cancelled: Bool,
        captured: CapturedTab,
        current: CapturedTab
    ) -> Bool {
        guard outcome.succeeded, !cancelled else { return false }
        guard captured.id != nil,
              captured.url != nil,
              captured.content != nil,
              captured.contentVersion != nil,
              captured.isEligibleForReplacement,
              current.isEligibleForReplacement else {
            return false
        }
        return current.id == captured.id
            && current.url == captured.url
            && current.contentVersion == captured.contentVersion
            && current.content == captured.content
    }

    nonisolated static func replacementTargetIsEligible(
        scope: UserTask.Scope,
        isText: Bool,
        isTruncated: Bool?
    ) -> Bool {
        scope == .activeFile && isText && isTruncated == false
    }

    private static func presentReplacementConflict(
        run: UserTaskRun,
        projectManager: ProjectManager,
        context: DialogPresentationContext
    ) {
        Task { @MainActor in
            // Copy the captured stdout to the pasteboard, or reveal the
            // output surface — both offered behind the OK that Return and
            // Escape resolve to, so neither happens by reflex.
            let response = await AlertTemplate.userTaskOutputConflict.runSheet(
                on: context,
                messageText: Strings.userTaskOutputConflictTitle,
                informativeText: Strings.userTaskOutputConflictMessage
            )
            applyReplacementConflictResponse(
                response,
                run: run,
                projectManager: projectManager,
                context: context
            )
        }
    }

    /// Applies a recovery choice from the replacement-conflict sheet.
    ///
    /// Button order follows ``AlertTemplate/userTaskOutputConflict``: OK
    /// first (and therefore the rightmost, default, Escape-answering
    /// button), then Copy Output, then Open Output.
    ///
    /// Kept as an internal seam so the safe Copy/Open actions can be hosted
    /// against a real owner window without automating an `NSAlert`.
    static func applyReplacementConflictResponse(
        _ response: NSApplication.ModalResponse,
        run: UserTaskRun,
        projectManager: ProjectManager,
        context: DialogPresentationContext,
        copyOutput: (String) -> Void = {
            UserTaskOutputClipboard.copy($0)
        }
    ) {
        guard let owner = context.nsWindow,
              owner.isVisible,
              !owner.isMiniaturized else {
            return
        }
        switch response {
        case .alertSecondButtonReturn:
            copyOutput(run.stdout)
        case .alertThirdButtonReturn:
            projectManager.taskRunStore.isOutputVisible = true
        default:
            break
        }
    }

    private static func presentMissingActiveFile(
        context: DialogPresentationContext
    ) async {
        _ = await AlertTemplate.userTaskNotice.runSheet(
            on: context,
            messageText: Strings.userTaskMissingFileTitle,
            informativeText: Strings.userTaskMissingFileMessage
        )
    }

    private static func presentIneligibleReplacement(
        context: DialogPresentationContext
    ) async {
        _ = await AlertTemplate.userTaskNotice.runSheet(
            on: context,
            messageText: Strings.userTaskReplacementUnavailableTitle,
            informativeText: Strings.userTaskReplacementUnavailableMessage
        )
    }
}
