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
    @Test("Output replacement requires the same unchanged editor buffer")
    func replacementRequiresSameUnchangedBuffer() {
        let tabID = UUID()

        #expect(UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: tabID,
            currentContent: "before"
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: UUID(),
            currentContent: "before"
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: tabID,
            currentContent: "human edit"
        ))
    }

    @Test("Missing capture data always fails closed", arguments: [
        (nil, "before", UUID(), "before"),
        (UUID(), nil, UUID(), "before"),
        (nil, nil, nil, nil),
    ] as [(UUID?, String?, UUID?, String?)])
    func missingCaptureFailsClosed(
        capturedTabID: UUID?,
        capturedContent: String?,
        currentTabID: UUID?,
        currentContent: String?
    ) {
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: capturedTabID,
            capturedContent: capturedContent,
            currentTabID: currentTabID,
            currentContent: currentContent
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
}
