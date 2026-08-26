//
//  CLIInstallerCancellationTests.swift
//  PineTests
//
//  #1530 — the privileged-install path used to decide "the user cancelled" by
//  substring-matching `NSAppleScript.errorMessage` against "User canceled".
//  That message is localized by the system, so on eight of Pine's nine locales
//  a normal cancellation was reported as "Installation Failed". Classification
//  now runs off the AppleScript error *number*, which is locale-invariant.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("CLI installer cancellation classification")
struct CLIInstallerCancellationTests {
    /// Localized renderings of `userCanceledErr` as macOS actually reports it.
    /// `osascript -e 'error number -128'` on a Russian system prints
    /// "Отменено пользователем." — none of these contain "User canceled".
    private static let localizedCancellationMessages = [
        "User canceled.",
        "Отменено пользователем.",
        "Der Benutzer hat abgebrochen.",
        "El usuario ha cancelado.",
        "L’utilisateur a annulé.",
        "ユーザによって取り消されました。",
        "사용자가 취소했습니다.",
        "O usuário cancelou.",
        "用户已取消。",
    ]

    private func scriptError(
        number: Int?,
        message: String?
    ) -> NSDictionary {
        let error = NSMutableDictionary()
        if let number {
            error[NSAppleScript.errorNumber] = NSNumber(value: number)
        }
        if let message {
            error[NSAppleScript.errorMessage] = message
        }
        return error
    }

    // MARK: - Pure classification by error number

    @Test("userCanceledErr is a cancellation")
    func userCanceledErrIsCancellation() {
        #expect(CLIInstaller.isUserCancellation(errorNumber: -128))
        #expect(
            CLIInstaller.isUserCancellation(
                errorNumber: Int(userCanceledErr)
            )
        )
    }

    @Test("Related Apple Event cancellation codes count as cancellation")
    func relatedCancellationCodes() {
        #expect(
            CLIInstaller.isUserCancellation(
                errorNumber: Int(errAEWaitCanceled)
            )
        )
        #expect(CLIInstaller.isUserCancellation(errorNumber: -1711))
        #expect(
            CLIInstaller.isUserCancellation(
                errorNumber: Int(errAuthorizationCanceled)
            )
        )
        #expect(CLIInstaller.isUserCancellation(errorNumber: -60006))
    }

    @Test("Genuine failure codes are not cancellations")
    func failureCodesAreNotCancellations() {
        let failureCodes = [
            0,
            1,
            128,
            255,
            -1,
            -60005,
            Int(errAEEventNotHandled),
            Int(errOSAScriptError),
            -1743,
            -10004,
        ]
        for code in failureCodes {
            #expect(
                !CLIInstaller.isUserCancellation(errorNumber: code),
                "\(code) must not be treated as a user cancellation"
            )
        }
    }

    @Test("A missing error number is not a cancellation")
    func missingErrorNumberIsNotCancellation() {
        #expect(!CLIInstaller.isUserCancellation(errorNumber: nil))
    }

    // MARK: - Outcome mapping

    @Test("No error dictionary means the script succeeded")
    func nilErrorIsSuccess() {
        #expect(CLIInstaller.outcome(forScriptError: nil) == .succeeded)
    }

    /// The regression guard: every localized spelling of the cancellation
    /// message must classify as `.cancelled`. A text-matching implementation
    /// passes only the English row.
    @Test("Localized cancellation text still classifies as cancelled")
    func localizedCancellationsAreCancelled() {
        for message in Self.localizedCancellationMessages {
            let error = scriptError(number: -128, message: message)
            #expect(
                CLIInstaller.outcome(forScriptError: error) == .cancelled,
                "\(message) must classify as a cancellation"
            )
        }
    }

    @Test("Cancellation presents no alert")
    func cancellationPresentsNoAlert() {
        for message in Self.localizedCancellationMessages {
            let error = scriptError(number: -128, message: message)
            #expect(
                CLIInstaller.outcome(
                    forScriptError: error
                ).presentsErrorAlert == false,
                "\(message) must not raise an alert"
            )
        }
        #expect(
            CLIInstaller.outcome(forScriptError: nil).presentsErrorAlert
                == false
        )
    }

    @Test("An English failure message is reported verbatim")
    func genuineFailureCarriesItsMessage() {
        let error = scriptError(number: -10004, message: "A privilege violation occurred.")
        #expect(
            CLIInstaller.outcome(forScriptError: error)
                == .failed(message: "A privilege violation occurred.")
        )
        #expect(CLIInstaller.outcome(forScriptError: error).presentsErrorAlert)
    }

    /// A failure whose localized text happens to mention cancellation must
    /// still be a failure — the number, not the prose, decides.
    @Test("Failure codes stay failures even when the text says canceled")
    func misleadingTextDoesNotCancel() {
        let error = scriptError(number: -10004, message: "User canceled.")
        #expect(
            CLIInstaller.outcome(forScriptError: error)
                == .failed(message: "User canceled.")
        )
    }

    @Test("A failure without a message falls back to the localized default")
    func missingMessageUsesLocalizedFallback() {
        let error = scriptError(number: 255, message: nil)
        #expect(
            CLIInstaller.outcome(forScriptError: error)
                == .failed(message: Strings.cliErrorUnknown)
        )
    }

    @Test("An error dictionary without a number is a failure, not a cancel")
    func numberlessErrorIsFailure() {
        let error = scriptError(number: nil, message: "Something broke.")
        #expect(
            CLIInstaller.outcome(forScriptError: error)
                == .failed(message: "Something broke.")
        )
    }
}
