//
//  UserTaskInvocationControllerTests.swift
//  PineTests
//

import Foundation
import AppKit
import Testing

@testable import Pine

@Suite("User task invocation safety")
struct UserTaskInvocationControllerTests {
    @Test("Untitled buffers are unavailable to active-file tasks")
    func untitledBufferIsNotAnActiveFile() {
        let activeFileTask = UserTask(
            id: "lint-file",
            label: "Lint File",
            command: "swiftlint",
            scope: .activeFile
        )
        let projectTask = UserTask(
            id: "build-project",
            label: "Build Project",
            command: "swift build",
            scope: .project
        )
        let untitled = EditorTab(
            untitledName: "Untitled",
            content: "draft",
            savedContent: ""
        )

        #expect(
            !UserTaskInvocationController.hasRequiredActiveFile(
                for: activeFileTask,
                activeTab: untitled
            )
        )
        #expect(
            UserTaskInvocationController.hasRequiredActiveFile(
                for: projectTask,
                activeTab: untitled
            )
        )
    }

    @Test("Successful output replacement requires the same unchanged editor buffer")
    func replacementRequiresSameUnchangedBuffer() {
        let tabID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/source.swift")
        let success = outcome(exitCode: 0)

        #expect(UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: capture(id: tabID, url: fileURL)
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: capture(id: UUID(), url: fileURL)
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: capture(
                id: tabID,
                url: fileURL,
                content: "human edit"
            )
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: capture(
                id: tabID,
                url: URL(fileURLWithPath: "/tmp/saved-as.swift")
            )
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: capture(id: tabID, url: fileURL, contentVersion: 2)
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: success,
            cancelled: false,
            captured: capture(id: tabID, url: fileURL),
            current: .init(
                id: tabID,
                url: fileURL.standardizedFileURL,
                content: "before",
                contentVersion: 1,
                isEligibleForReplacement: false
            )
        ))
    }

    @Test("Missing capture data always fails closed", arguments: [
        (nil, URL(fileURLWithPath: "/tmp/a"), "before", 1),
        (UUID(), nil, "before", 1),
        (UUID(), URL(fileURLWithPath: "/tmp/a"), nil, 1),
        (UUID(), URL(fileURLWithPath: "/tmp/a"), "before", nil),
        (nil, nil, nil, nil),
    ] as [(UUID?, URL?, String?, UInt64?)])
    func missingCaptureFailsClosed(
        capturedTabID: UUID?,
        capturedURL: URL?,
        capturedContent: String?,
        capturedContentVersion: UInt64?
    ) {
        let current = capture(
            id: capturedTabID ?? UUID(),
            url: capturedURL ?? URL(fileURLWithPath: "/tmp/a"),
            content: capturedContent ?? "before",
            contentVersion: capturedContentVersion ?? 1
        )
        #expect(!UserTaskInvocationController.canApplyReplacement(
            outcome: outcome(exitCode: 0),
            cancelled: false,
            captured: .init(
                id: capturedTabID,
                url: capturedURL,
                content: capturedContent,
                contentVersion: capturedContentVersion,
                isEligibleForReplacement: true
            ),
            current: current
        ))
    }

    @Test("Editing during suspended confirmation never reaches the runner")
    @MainActor
    func editDuringConfirmationFailsClosed() async {
        let project = ProjectManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-user-task-edit.swift"),
            content: "before",
            savedContent: "before"
        )
        project.primaryTabManager.tabs = [tab]
        project.primaryTabManager.activeTabID = tab.id
        let window = NSWindow()
        window.orderFront(nil)
        let context = DialogPresenter.register(
            window: window,
            projectManager: project
        )
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }
        let task = UserTask(
            id: "format",
            label: "Format",
            command: "swiftformat",
            replacesFileContent: true,
            requireConfirmation: true
        )
        let (confirmationGate, confirmationContinuation) =
            AsyncStream.makeStream(of: Bool.self)
        var confirmationStarted = false
        var runnerInputs: [(URL?, String?)] = []

        let invocation = Task { @MainActor in
            await UserTaskInvocationController.invokePrepared(
                task,
                projectManager: project,
                context: context,
                presentConfirmation: { _, _ in
                    confirmationStarted = true
                    for await response in confirmationGate {
                        return response
                    }
                    return false
                },
                runTask: { _, fileURL, _, content, _ in
                    runnerInputs.append((fileURL, content))
                    return .noop
                }
            )
        }
        for _ in 0..<50 where !confirmationStarted {
            await Task.yield()
        }
        project.primaryTabManager.updateContent("edited during confirmation")
        confirmationContinuation.yield(true)
        confirmationContinuation.finish()

        #expect(await invocation.value == false)
        #expect(runnerInputs.isEmpty)
    }

    @Test("Switching files during suspended confirmation never retargets the task")
    @MainActor
    func switchDuringConfirmationFailsClosed() async {
        let project = ProjectManager()
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-user-task-first.swift"),
            content: "first",
            savedContent: "first"
        )
        let second = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-user-task-second.swift"),
            content: "second",
            savedContent: "second"
        )
        project.primaryTabManager.tabs = [first, second]
        project.primaryTabManager.activeTabID = first.id
        let window = NSWindow()
        window.orderFront(nil)
        let context = DialogPresenter.register(
            window: window,
            projectManager: project
        )
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }
        let task = UserTask(
            id: "lint",
            label: "Lint",
            command: "swiftlint",
            requireConfirmation: true
        )
        let (confirmationGate, confirmationContinuation) =
            AsyncStream.makeStream(of: Bool.self)
        var confirmationStarted = false
        var runnerFileURLs: [URL?] = []

        let invocation = Task { @MainActor in
            await UserTaskInvocationController.invokePrepared(
                task,
                projectManager: project,
                context: context,
                presentConfirmation: { _, _ in
                    confirmationStarted = true
                    for await response in confirmationGate {
                        return response
                    }
                    return false
                },
                runTask: { _, fileURL, _, _, _ in
                    runnerFileURLs.append(fileURL)
                    return .noop
                }
            )
        }
        for _ in 0..<50 where !confirmationStarted {
            await Task.yield()
        }
        project.primaryTabManager.activeTabID = second.id
        confirmationContinuation.yield(true)
        confirmationContinuation.finish()

        #expect(await invocation.value == false)
        #expect(runnerFileURLs.isEmpty)
    }

    @Test("Partial stdout from every unsuccessful path fails closed")
    func unsuccessfulOutcomesNeverReplaceContent() {
        let tabID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/source.swift")
        let unsuccessfulPaths: [(UserTaskOutcome, Bool)] = [
            (outcome(exitCode: 7, stdout: "partial"), false),
            (outcome(exitCode: 15, stdout: "partial", timedOut: true), false),
            (outcome(exitCode: -1, stdout: "partial"), false),
            (outcome(exitCode: 15, stdout: "partial"), true),
            // Cancellation wins even if the process happened to exit zero
            // before termination was observed.
            (outcome(exitCode: 0, stdout: "partial"), true),
        ]

        for (taskOutcome, cancelled) in unsuccessfulPaths {
            #expect(!UserTaskInvocationController.canApplyReplacement(
                outcome: taskOutcome,
                cancelled: cancelled,
                captured: capture(id: tabID, url: fileURL),
                current: capture(id: tabID, url: fileURL)
            ))
        }
    }

    @Test(
        "Replacement preflight requires active-file scope and a complete text tab",
        arguments: [
            (UserTask.Scope.activeFile, true, false, true),
            (.project, true, false, false),
            (.activeFile, false, false, false),
            (.activeFile, true, true, false),
            (.activeFile, true, nil, false),
        ] as [(UserTask.Scope, Bool, Bool?, Bool)]
    )
    func replacementPreflight(
        scope: UserTask.Scope,
        isText: Bool,
        isTruncated: Bool?,
        expected: Bool
    ) {
        #expect(
            UserTaskInvocationController.replacementTargetIsEligible(
                scope: scope,
                isText: isText,
                isTruncated: isTruncated
            ) == expected
        )
    }

    @Test("Cleanup and incomplete stdin failures never replace content")
    func lifecycleFailuresNeverReplaceContent() {
        let tabID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/source.swift")
        let capture = capture(id: tabID, url: fileURL)
        let cleanupFailure = UserTaskOutcome(
            taskID: "format",
            stdout: "partial",
            stderr: "cleanup",
            exitCode: 0,
            timedOut: false,
            cleanupSucceeded: false
        )
        let inputFailure = UserTaskOutcome(
            taskID: "format",
            stdout: "partial",
            stderr: "stdin",
            exitCode: 0,
            timedOut: false,
            standardInputCompleted: false
        )

        for failure in [cleanupFailure, inputFailure] {
            #expect(!UserTaskInvocationController.canApplyReplacement(
                outcome: failure,
                cancelled: false,
                captured: capture,
                current: capture
            ))
        }
    }

    @Test("Replacement conflict Copy and Open preserve the edited buffer")
    @MainActor
    func replacementConflictRecoveryActionsPreserveEdits() {
        let project = ProjectManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-conflict.swift"),
            content: "human edits",
            savedContent: "before"
        )
        project.primaryTabManager.tabs = [tab]
        project.primaryTabManager.activeTabID = tab.id
        let run = UserTaskRun(
            taskID: "format",
            taskLabel: "Format",
            command: "formatter",
            replacesFileContent: true
        )
        run.applyOutcome(
            outcome(exitCode: 0, stdout: "formatted output"),
            cancelled: false
        )
        let window = NSWindow()
        window.orderFront(nil)
        let context = DialogPresenter.register(
            window: window,
            projectManager: project
        )
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }
        var copiedOutput: String?

        // The first button is OK — the default, and what Escape and ⌘-.
        // resolve to. It must do nothing at all: Return used to land on Copy
        // Output and write the pasteboard as a side effect of dismissing a
        // sheet, and Escape was bound to no button whatsoever (#1541).
        project.taskRunStore.isOutputVisible = false
        UserTaskInvocationController.applyReplacementConflictResponse(
            .alertFirstButtonReturn,
            run: run,
            projectManager: project,
            context: context,
            copyOutput: { copiedOutput = $0 }
        )
        #expect(
            copiedOutput == nil,
            "Dismissing the conflict sheet must not touch the pasteboard"
        )
        #expect(!project.taskRunStore.isOutputVisible)
        #expect(project.primaryTabManager.activeTab?.content == "human edits")

        UserTaskInvocationController.applyReplacementConflictResponse(
            .alertSecondButtonReturn,
            run: run,
            projectManager: project,
            context: context,
            copyOutput: { copiedOutput = $0 }
        )
        #expect(copiedOutput == "formatted output")
        #expect(project.primaryTabManager.activeTab?.content == "human edits")

        project.taskRunStore.isOutputVisible = false
        UserTaskInvocationController.applyReplacementConflictResponse(
            .alertThirdButtonReturn,
            run: run,
            projectManager: project,
            context: context
        )
        #expect(project.taskRunStore.isOutputVisible)
        #expect(project.primaryTabManager.activeTab?.content == "human edits")
    }

    private func capture(
        id: UUID,
        url: URL = URL(fileURLWithPath: "/tmp/source.swift"),
        content: String = "before",
        contentVersion: UInt64 = 1
    ) -> UserTaskInvocationController.CapturedTab {
        .init(
            id: id,
            url: url.standardizedFileURL,
            content: content,
            contentVersion: contentVersion,
            isEligibleForReplacement: true
        )
    }

    private func outcome(
        exitCode: Int32,
        stdout: String = "formatted",
        timedOut: Bool = false
    ) -> UserTaskOutcome {
        UserTaskOutcome(
            taskID: "format",
            stdout: stdout,
            stderr: exitCode == 0 ? "" : "failure",
            exitCode: exitCode,
            timedOut: timedOut
        )
    }
}
