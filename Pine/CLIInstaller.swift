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
                title: "Installation Failed",
                message: "Could not find the pine CLI script in the app bundle.",
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
                presentSuccess(
                    title: "Command Line Tool Installed",
                    message: "The 'pine' command is now available.\n\nUsage: pine . or pine file.swift",
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
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                if !message.contains("User canceled") {
                    showError(
                        title: "Installation Failed",
                        message: message,
                        context: context
                    )
                }
            } else {
                presentSuccess(
                    title: "Command Line Tool Installed",
                    message: "The 'pine' command is now available.\n\nUsage: pine . or pine file.swift",
                    projectManager: projectManager,
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
                presentSuccess(
                    title: "Command Line Tool Removed",
                    message: "The 'pine' command has been removed from /usr/local/bin.",
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
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                if !message.contains("User canceled") {
                    showError(
                        title: "Uninstall Failed",
                        message: message,
                        context: context
                    )
                }
            } else {
                presentSuccess(
                    title: "Command Line Tool Removed",
                    message: "The 'pine' command has been removed from /usr/local/bin.",
                    projectManager: projectManager,
                    context: context
                )
            }
        }
    }

    // MARK: - Presentation

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
