//
//  UserConfigurationAlertPresenter.swift
//  Pine
//
//  Testable presentation seam for user-configuration alerts. Production uses
//  NSAlert; tests record the immutable descriptor without entering a modal
//  event loop.
//

import AppKit

nonisolated struct UserConfigurationAlertDescriptor: Sendable, Equatable {
    nonisolated enum Style: Sendable, Equatable {
        case informational
        case warning
    }

    let style: Style
    let messageText: String
    let informativeText: String
    let buttonTitle: String
}

@MainActor
protocol UserConfigurationAlertPresenting {
    @discardableResult
    func present(
        _ descriptor: UserConfigurationAlertDescriptor
    ) async -> NSApplication.ModalResponse
}

@MainActor
struct AppKitUserConfigurationAlertPresenter: UserConfigurationAlertPresenting {
    let context: DialogPresentationContext
    let feedbackPresenter: any WindowNonmodalFeedbackPresenting

    init(
        context: DialogPresentationContext = .unscoped,
        feedbackPresenter: any WindowNonmodalFeedbackPresenting =
            WindowNonmodalFeedbackPresenter.shared
    ) {
        self.context = context
        self.feedbackPresenter = feedbackPresenter
    }

    @discardableResult
    func present(
        _ descriptor: UserConfigurationAlertDescriptor
    ) async -> NSApplication.ModalResponse {
        if descriptor.style == .informational {
            let announcement = "\(descriptor.messageText). \(descriptor.informativeText)"
            if let owner = context.nsWindow,
               owner.isVisible,
               let projectManager = DialogPresenter.projectManager(for: owner) {
                projectManager.toastManager.show(ToastItem(message: announcement))
            } else {
                feedbackPresenter.present(
                    message: announcement,
                    context: context
                )
            }
            return .alertFirstButtonReturn
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = descriptor.messageText
        alert.informativeText = descriptor.informativeText
        alert.addButton(withTitle: descriptor.buttonTitle)
        return await alert.runSheet(on: context)
    }
}
