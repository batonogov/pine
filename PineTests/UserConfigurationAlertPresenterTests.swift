//
//  UserConfigurationAlertPresenterTests.swift
//  PineTests
//
//  Hosted seam tests for reload-alert content and modal lifecycle.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("User configuration alert presentation")
@MainActor
struct UserConfigurationAlertPresenterTests {
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
    ) -> NSApplication.ModalResponse {
        isPresenting = true
        descriptors.append(descriptor)
        dismissalCount += 1
        isPresenting = false
        return .alertFirstButtonReturn
    }
}
