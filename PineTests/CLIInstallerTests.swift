//
//  CLIInstallerTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@MainActor
struct CLIInstallerTests {
    @Test func defaultInstallPathIsUsrLocalBin() {
        #expect(CLIInstaller.defaultInstallPath == "/usr/local/bin/pine")
    }

    @Test func isInstalledReturnsBoolBasedOnFileExistence() {
        // This just verifies the property doesn't crash — actual value depends on system state
        _ = CLIInstaller.isInstalled
    }

    @Test func isInstalledFromCurrentBundleReturnsBool() {
        _ = CLIInstaller.isInstalledFromCurrentBundle
    }

    @Test func successUsesNonBlockingProjectToast() {
        let projectManager = ProjectManager()
        projectManager.toastManager.announce = { _ in }
        let window = NSWindow()
        let context = DialogPresenter.register(
            window: window,
            projectManager: projectManager
        )
        window.orderFront(nil)
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }

        CLIInstaller.presentSuccess(
            title: "Installed",
            message: "Ready",
            projectManager: projectManager,
            context: context
        )

        #expect(projectManager.toastManager.currentToast?.message == "Installed. Ready")
        #expect(window.sheets.isEmpty)
    }

    @Test func noProjectSuccessUsesVisibleWindowFeedback() {
        let window = NSWindow()
        window.orderFront(nil)
        let context = DialogPresentationContext(window: window)
        let feedback = RecordingCLIFeedbackPresenter()
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }

        CLIInstaller.presentSuccess(
            title: "Installed",
            message: "Ready",
            projectManager: nil,
            context: context,
            feedbackPresenter: feedback
        )

        #expect(feedback.messages == ["Installed. Ready"])
        #expect(feedback.owner === window)
        #expect(window.sheets.isEmpty)
    }
}

@MainActor
private final class RecordingCLIFeedbackPresenter:
    WindowNonmodalFeedbackPresenting {
    private(set) var messages: [String] = []
    private(set) weak var owner: NSWindow?

    func present(
        message: String,
        context: DialogPresentationContext
    ) -> Bool {
        messages.append(message)
        owner = context.nsWindow
        return owner != nil
    }
}
