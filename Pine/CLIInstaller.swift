//
//  CLIInstaller.swift
//  Pine
//
//  Installs/uninstalls the `pine` CLI symlink at /usr/local/bin/pine.
//

import AppKit
import Foundation

enum CLIInstaller {
    /// Default install location for the CLI symlink.
    static let defaultInstallPath = "/usr/local/bin/pine"

    /// Path to the shell script bundled inside Pine.app.
    static var bundledScriptPath: String? {
        Bundle.main.path(forResource: "pine", ofType: nil)
    }

    /// Whether the CLI tool is currently installed at the default location.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultInstallPath)
    }

    /// Whether the installed symlink points to the current app bundle.
    static var isInstalledFromCurrentBundle: Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: defaultInstallPath),
              let bundled = bundledScriptPath else { return false }
        return dest == bundled
    }

    // MARK: - AppleScript outcome classification

    /// What a privileged AppleScript invocation actually did.
    ///
    /// Derived from the error dictionary's *number*, never its message:
    /// `NSAppleScript.errorMessage` is localized by the system, so matching it
    /// against English prose reports a cancellation as a failure in all eight
    /// non-English locales Pine ships (#1530).
    enum PrivilegedScriptOutcome: Equatable {
        case succeeded
        case cancelled
        case failed(message: String)

        /// Only a genuine failure earns an alert. Dismissing the authorization
        /// prompt is a normal user action and must stay silent.
        var presentsErrorAlert: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// AppleScript error numbers that mean "the user dismissed the prompt".
    ///
    /// `do shell script … with administrator privileges` reports a cancelled
    /// authorization dialog as `userCanceledErr` (-128). The Apple Event and
    /// Authorization Services spellings of the same user action are accepted
    /// too, so the classification never depends on which layer surfaced it.
    static let cancellationErrorNumbers: Set<Int> = [
        Int(userCanceledErr),          // -128
        Int(errAEWaitCanceled),        // -1711
        Int(errAuthorizationCanceled), // -60006
    ]

    /// Locale-invariant test for "the user cancelled the authorization prompt".
    static func isUserCancellation(errorNumber: Int?) -> Bool {
        guard let errorNumber else { return false }
        return cancellationErrorNumbers.contains(errorNumber)
    }

    /// Classifies the error dictionary produced by
    /// `NSAppleScript.executeAndReturnError`. A `nil` dictionary means the
    /// script ran to completion.
    static func outcome(
        forScriptError error: NSDictionary?
    ) -> PrivilegedScriptOutcome {
        guard let error else { return .succeeded }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        guard !isUserCancellation(errorNumber: number) else { return .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String
        return .failed(message: message ?? Strings.cliErrorUnknown)
    }

    // MARK: - Install / Uninstall

    /// Installs the CLI tool by creating a symlink.
    /// Tries without elevated privileges first; falls back to AppleScript admin prompt if needed.
    @MainActor
    static func install(projectManager: ProjectManager? = nil) {
        let context = if let projectManager {
            DialogPresenter.forProject(projectManager)
        } else {
            DialogPresenter.forKeyWindow()
        }
        guard let scriptPath = bundledScriptPath else {
            showError(
                title: Strings.cliInstallFailedTitle,
                message: Strings.cliInstallMissingScript,
                context: context
            )
            return
        }

        let installDir = (defaultInstallPath as NSString).deletingLastPathComponent

        // Try without sudo first — /usr/local/bin is often writable
        if FileManager.default.isWritableFile(atPath: installDir) {
            do {
                // Remove existing symlink/file if present
                if FileManager.default.fileExists(atPath: defaultInstallPath) {
                    try FileManager.default.removeItem(atPath: defaultInstallPath)
                }
                try FileManager.default.createSymbolicLink(
                    atPath: defaultInstallPath,
                    withDestinationPath: scriptPath
                )
                presentInstallSuccess(
                    projectManager: projectManager,
                    context: context
                )
                return
            } catch {
                // Fall through to AppleScript approach
            }
        }

        // Fallback: AppleScript for privileged symlink creation
        let script = """
            do shell script \
            "mkdir -p '\(installDir)' && ln -sf '\(scriptPath)' '\(defaultInstallPath)'" \
            with administrator privileges
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            switch outcome(forScriptError: error) {
            case .succeeded:
                presentInstallSuccess(
                    projectManager: projectManager,
                    context: context
                )
            case .cancelled:
                // The user declined the authorization prompt — not a failure.
                break
            case .failed(let message):
                showError(
                    title: Strings.cliInstallFailedTitle,
                    message: message,
                    context: context
                )
            }
        }
    }

    /// Uninstalls the CLI tool by removing the symlink.
    /// Tries without elevated privileges first; falls back to AppleScript admin prompt if needed.
    @MainActor
    static func uninstall(projectManager: ProjectManager? = nil) {
        let context = if let projectManager {
            DialogPresenter.forProject(projectManager)
        } else {
            DialogPresenter.forKeyWindow()
        }
        // Try without sudo first
        if FileManager.default.isDeletableFile(atPath: defaultInstallPath) {
            do {
                try FileManager.default.removeItem(atPath: defaultInstallPath)
                presentUninstallSuccess(
                    projectManager: projectManager,
                    context: context
                )
                return
            } catch {
                // Fall through to AppleScript approach
            }
        }

        // Fallback: AppleScript for privileged removal
        let script = """
            do shell script "rm -f '\(defaultInstallPath)'" with administrator privileges
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            switch outcome(forScriptError: error) {
            case .succeeded:
                presentUninstallSuccess(
                    projectManager: projectManager,
                    context: context
                )
            case .cancelled:
                // The user declined the authorization prompt — not a failure.
                break
            case .failed(let message):
                showError(
                    title: Strings.cliUninstallFailedTitle,
                    message: message,
                    context: context
                )
            }
        }
    }

    // MARK: - Presentation

    @MainActor
    private static func presentInstallSuccess(
        projectManager: ProjectManager?,
        context: DialogPresentationContext
    ) {
        presentSuccess(
            title: Strings.cliInstallSuccessTitle,
            message: Strings.cliInstallSuccessMessage,
            projectManager: projectManager,
            context: context
        )
    }

    @MainActor
    private static func presentUninstallSuccess(
        projectManager: ProjectManager?,
        context: DialogPresentationContext
    ) {
        presentSuccess(
            title: Strings.cliUninstallSuccessTitle,
            message: Strings.cliUninstallSuccessMessage,
            projectManager: projectManager,
            context: context
        )
    }

    /// Reports success without taking focus or blocking any project window.
    /// Internal visibility keeps the no-sheet contract directly testable.
    @MainActor
    static func presentSuccess(
        title: String,
        message: String,
        projectManager: ProjectManager?,
        context: DialogPresentationContext,
        feedbackPresenter: any WindowNonmodalFeedbackPresenting =
            WindowNonmodalFeedbackPresenter.shared
    ) {
        let announcement = "\(title). \(message)"
        if let projectManager,
           let owner = context.nsWindow,
           owner.isVisible,
           projectManager.dialogOwnerWindow === owner {
            projectManager.toastManager.show(ToastItem(message: announcement))
        } else {
            feedbackPresenter.present(
                message: announcement,
                context: context
            )
        }
    }

    @MainActor
    private static func showError(
        title: String,
        message: String,
        context: DialogPresentationContext
    ) {
        Task { @MainActor in
            _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                on: context,
                messageText: title,
                informativeText: message
            )
        }
    }
}
