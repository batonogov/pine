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
        if task.effectiveRequireConfirmation(),
           !presentConfirmation(for: task) {
            return
        }

        let tabManager = projectManager.activeTabManager
        let activeTab = tabManager.activeTab
        let capturedTabID = activeTab?.id
        let capturedContent = activeTab?.content

        UserTaskRunner.shared.run(
            task: task,
            fileURL: activeTab?.url,
            projectRootURL: projectManager.workspace.rootURL,
            fileContent: capturedContent
        ) { outcome in
            presentOutcome(
                outcome,
                task: task,
                projectManager: projectManager,
                capturedTabID: capturedTabID,
                capturedContent: capturedContent
            )
        }
    }

    private static func presentConfirmation(for task: UserTask) -> Bool {
        let alert = NSAlert()
        alert.messageText = Strings.userTaskConfirmationTitle(task.label)
        alert.informativeText = Strings.userTaskConfirmationMessage(task.command)
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.userTaskRun)
        alert.addButton(withTitle: Strings.dialogCancel)
        return alert.runModal() == .alertFirstButtonReturn
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
        guard let capturedTabID,
              let capturedContent,
              tabManager.activeTab?.id == capturedTabID,
              tabManager.activeTab?.content == capturedContent else {
            presentReplacementConflict()
            return
        }
        tabManager.updateContent(outcome.stdout)
    }

    private static func presentReplacementConflict() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.userTaskOutputConflictTitle
        alert.informativeText = Strings.userTaskOutputConflictMessage
        alert.addButton(withTitle: Strings.dialogOK)
        alert.runModal()
    }
}
