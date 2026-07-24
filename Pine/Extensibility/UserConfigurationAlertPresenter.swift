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
    ) -> NSApplication.ModalResponse
}

@MainActor
struct AppKitUserConfigurationAlertPresenter: UserConfigurationAlertPresenting {
    @discardableResult
    func present(
        _ descriptor: UserConfigurationAlertDescriptor
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        switch descriptor.style {
        case .informational:
            alert.alertStyle = .informational
        case .warning:
            alert.alertStyle = .warning
        }
        alert.messageText = descriptor.messageText
        alert.informativeText = descriptor.informativeText
        alert.addButton(withTitle: descriptor.buttonTitle)
        return alert.runModal()
    }
}
