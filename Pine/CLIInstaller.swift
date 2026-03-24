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
    static func install() {
        guard let scriptPath = bundledScriptPath else {
            showAlert(
                title: "Installation Failed",
                message: "Could not find the pine CLI script in the app bundle."
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
                showAlert(
                    title: "Command Line Tool Installed",
                    message: "The 'pine' command is now available.\n\nUsage: pine . or pine file.swift"
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
                    showAlert(
                        title: "Installation Failed",
                        message: message
                    )
                }
            } else {
                showAlert(
                    title: "Command Line Tool Installed",
                    message: "The 'pine' command is now available.\n\nUsage: pine . or pine file.swift"
                )
            }
        }
    }

    /// Uninstalls the CLI tool by removing the symlink.
    /// Tries without elevated privileges first; falls back to AppleScript admin prompt if needed.
    static func uninstall() {
        // Try without sudo first
        if FileManager.default.isDeletableFile(atPath: defaultInstallPath) {
            do {
                try FileManager.default.removeItem(atPath: defaultInstallPath)
                showAlert(
                    title: "Command Line Tool Removed",
                    message: "The 'pine' command has been removed from /usr/local/bin."
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
                    showAlert(
                        title: "Uninstall Failed",
                        message: message
                    )
                }
            } else {
                showAlert(
                    title: "Command Line Tool Removed",
                    message: "The 'pine' command has been removed from /usr/local/bin."
                )
            }
        }
    }

    // MARK: - Private

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
