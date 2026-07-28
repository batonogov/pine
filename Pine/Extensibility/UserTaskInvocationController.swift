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
    static func invoke(
        _ task: UserTask,
        projectManager: ProjectManager
    ) {
        let tabManager = projectManager.activeTabManager
        let activeTab = tabManager.activeTab
        if task.scope == .activeFile, activeTab == nil {
            Task { @MainActor in presentMissingActiveFile() }
            return
        }

        Task { @MainActor in
            if task.effectiveRequireConfirmation(),
               !(await presentConfirmation(for: task)) {
                return
            }

            let capturedTabID = activeTab?.id
            let capturedContent = activeTab?.content

            UserTaskRunner.shared.run(
                task: task,
                fileURL: activeTab?.url,
                projectRootURL: projectManager.workspace.rootURL,
                fileContent: capturedContent
            ) { outcome in
                Task { @MainActor in
                    presentOutcome(
                        outcome,
                        task: task,
                        projectManager: projectManager,
                        capturedTabID: capturedTabID,
                        capturedContent: capturedContent
                    )
                }
            }
        }
    }

    private static func presentConfirmation(for task: UserTask) async -> Bool {
        let context = DialogPresenter.forKeyProject()
        let alert = NSAlert()
        alert.messageText = Strings.userTaskConfirmationTitle(task.label)
        alert.informativeText = Strings.userTaskConfirmationMessage(task.command)
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.userTaskRun)
        alert.addButton(withTitle: Strings.dialogCancel)
        let response = await alert.runSheet(on: context)
        return response == .alertFirstButtonReturn
    }

    private static func presentOutcome(
        _ outcome: UserTaskOutcome,
        task: UserTask,
        projectManager: ProjectManager,
        capturedTabID: UUID?,
        capturedContent: String?
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

        // Fail closed if the user switched tabs or edited the file while the
        // process ran. Applying stdout to a different/newer buffer would lose
        // unrelated work and violate the task's active-file contract.
        let tabManager = projectManager.activeTabManager
        guard canApplyReplacement(
            capturedTabID: capturedTabID,
            capturedContent: capturedContent,
            currentTabID: tabManager.activeTab?.id,
            currentContent: tabManager.activeTab?.content
        ) else {
            presentReplacementConflict()
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

    private static func presentReplacementConflict() {
        let context = DialogPresenter.forKeyProject()
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Strings.userTaskOutputConflictTitle
            alert.informativeText = Strings.userTaskOutputConflictMessage
            alert.addButton(withTitle: Strings.dialogOK)
            _ = await alert.runSheet(on: context)
        }
    }

    private static func presentMissingActiveFile() {
        let context = DialogPresenter.forKeyProject()
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
