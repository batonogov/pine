//
//  UserConfigurationAlertPresenterTests.swift
//  PineTests
//
//  Hosted seam tests for reload-alert content and presentation lifecycle.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("User configuration alert presentation")
@MainActor
struct UserConfigurationAlertPresenterTests {
    @Test("Production informational result uses a project toast without a sheet")
    func productionInformationalResultUsesToast() async {
        let projectManager = ProjectManager()
        projectManager.toastManager.announce = { _ in }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let context = DialogPresenter.register(
            window: window,
            projectManager: projectManager
        )
        window.orderFront(nil)
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }

        let response = await AppKitUserConfigurationAlertPresenter(
            context: context
        ).present(UserConfigurationAlertDescriptor(
            style: .informational,
            messageText: "Configuration Reloaded",
            informativeText: "1 task loaded.",
            buttonTitle: "OK"
        ))

        #expect(response == .alertFirstButtonReturn)
        #expect(projectManager.toastManager.currentToast?.message ==
                "Configuration Reloaded. 1 task loaded.")
        #expect(window.sheets.isEmpty)
    }

    @Test("No-project informational result uses visible nonmodal feedback")
    func noProjectInformationalResultUsesWindowFeedback() async {
        let window = NSWindow()
        window.orderFront(nil)
        let context = DialogPresentationContext(window: window)
        let feedback = RecordingWindowFeedbackPresenter()
        defer {
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }

        let response = await AppKitUserConfigurationAlertPresenter(
            context: context,
            feedbackPresenter: feedback
        ).present(UserConfigurationAlertDescriptor(
            style: .informational,
            messageText: "Configuration Reloaded",
            informativeText: "1 task loaded.",
            buttonTitle: "OK"
        ))

        #expect(response == .alertFirstButtonReturn)
        #expect(feedback.messages == [
            "Configuration Reloaded. 1 task loaded.",
        ])
        #expect(feedback.owners.count == 1)
        #expect(feedback.owners[0] === window)
        #expect(window.sheets.isEmpty)
    }

    @Test("AppKit window feedback is visible and remains nonmodal")
    func appKitWindowFeedbackIsVisibleAndNonmodal() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        let context = DialogPresentationContext(window: window)
        let feedback = WindowNonmodalFeedbackPresenter(
            displayDuration: .seconds(60)
        )
        defer {
            feedback.dismiss(for: window)
            DialogPresenter.ownerDidClose(window)
            window.orderOut(nil)
        }

        #expect(feedback.present(message: "Visible success", context: context))
        #expect(feedback.hasVisibleFeedback(for: window))
        #expect(window.childWindows?.contains(where: \.isVisible) == true)
        #expect(window.sheets.isEmpty)
    }

    @Test("Successful reload presents counts and completes dismissal")
    func successfulReloadPresentation() async {
        let presenter = RecordingReloadAlertPresenter()
        let manager = ExtensibilityManager(
            tasksFileURL: URL(fileURLWithPath: "/unused/tasks.json"),
            keybindingsFileURL: URL(fileURLWithPath: "/unused/keybindings.json"),
            taskLoader: { _ in
                .loaded([
                    UserTask(id: "lint", label: "Lint", command: "swiftlint"),
                ])
            },
            keybindingLoader: { _ in .missing }
        )

        await PineAppMenuCommands.reloadAndPresentConfigurationDiagnostics(
            manager: manager,
            alertPresenter: presenter
        )

        #expect(presenter.descriptors.count == 1)
        let descriptor = presenter.descriptors[0]
        #expect(descriptor.style == .informational)
        #expect(descriptor.informativeText.contains("1"))
        #expect(descriptor.informativeText.contains("0"))
        #expect(presenter.dismissalCount == 1)
        #expect(!presenter.isPresenting)
    }

    @Test("Rejected reload presents visible file, entry, and reason")
    func rejectedReloadPresentation() async {
        let presenter = RecordingReloadAlertPresenter()
        let keybindingsURL = URL(fileURLWithPath: "/unused/keybindings.json")
        let diagnostic = UserConfigurationDiagnostic(
            file: .keybindings,
            fileURL: keybindingsURL,
            entryNumber: 2,
            reason: .unknownCommand(id: "missingCommand")
        )
        let manager = ExtensibilityManager(
            tasksFileURL: URL(fileURLWithPath: "/unused/tasks.json"),
            keybindingsFileURL: keybindingsURL,
            taskLoader: { _ in .missing },
            keybindingLoader: { _ in .rejected([diagnostic]) }
        )

        await PineAppMenuCommands.reloadAndPresentConfigurationDiagnostics(
            manager: manager,
            alertPresenter: presenter
        )

        #expect(presenter.descriptors.count == 1)
        let descriptor = presenter.descriptors[0]
        #expect(descriptor.style == .warning)
        #expect(descriptor.informativeText.contains("keybindings.json"))
        #expect(descriptor.informativeText.contains("2"))
        #expect(descriptor.informativeText.contains("missingCommand"))
        #expect(presenter.dismissalCount == 1)
        #expect(!presenter.isPresenting)
    }
}

@MainActor
private final class RecordingReloadAlertPresenter:
    UserConfigurationAlertPresenting {
    private(set) var descriptors: [UserConfigurationAlertDescriptor] = []
    private(set) var dismissalCount = 0
    private(set) var isPresenting = false

    func present(
        _ descriptor: UserConfigurationAlertDescriptor
    ) async -> NSApplication.ModalResponse {
        isPresenting = true
        descriptors.append(descriptor)
        dismissalCount += 1
        isPresenting = false
        return .alertFirstButtonReturn
    }
}

@MainActor
private final class RecordingWindowFeedbackPresenter:
    WindowNonmodalFeedbackPresenting {
    private(set) var messages: [String] = []
    private(set) var owners: [NSWindow?] = []

    func present(
        message: String,
        context: DialogPresentationContext
    ) -> Bool {
        messages.append(message)
        owners.append(context.nsWindow)
        return context.nsWindow != nil
    }
}
