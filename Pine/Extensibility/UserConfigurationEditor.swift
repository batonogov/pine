//
//  UserConfigurationEditor.swift
//  Pine
//
//  Issue #1117: surfaces Pine's user-editable JSON configuration
//  (`keybindings.json`, `tasks.json`) through menu actions. Creates a
//  commented starter file when none exists yet — without ever overwriting
//  a file the user already wrote — and reveals it in the system's default
//  editor.
//
//  The starter content is valid JSON: guidance lives in a `_comment` field
//  that JSONDecoder silently ignores, so reloading a freshly-created starter
//  produces no diagnostics instead of a "malformed document" error.
//

import AppKit
import Darwin
import Foundation
import os

nonisolated protocol UserConfigurationFileCreating: Sendable {
    /// Creates `url` exclusively, or returns `false` when a regular file is
    /// already present. Implementations must never replace an existing item.
    func createIfMissing(data: Data, at url: URL) throws -> Bool
}

/// POSIX-backed starter creation that is safe against check/use races.
///
/// The parent directory is opened without following its final symlink, then
/// the file is created relative to that descriptor with `O_EXCL|O_NOFOLLOW`.
/// An item created by another process therefore wins without being replaced.
nonisolated struct ExclusiveUserConfigurationFileCreator:
    UserConfigurationFileCreating {
    func createIfMissing(data: Data, at url: URL) throws -> Bool {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw Self.posixError(errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        let fileName = url.lastPathComponent
        for _ in 0..<3 {
            let descriptor = Darwin.openat(
                directoryDescriptor,
                fileName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if descriptor >= 0 {
                return try Self.writeNewFile(
                    descriptor: descriptor,
                    data: data,
                    directoryDescriptor: directoryDescriptor,
                    fileName: fileName
                )
            }

            let openError = errno
            guard openError == EEXIST else {
                throw Self.posixError(openError)
            }

            var itemInfo = stat()
            if Darwin.fstatat(
                directoryDescriptor,
                fileName,
                &itemInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                guard itemInfo.st_mode & S_IFMT == S_IFREG else {
                    throw Self.posixError(
                        itemInfo.st_mode & S_IFMT == S_IFLNK ? ELOOP : EINVAL
                    )
                }
                return false
            }

            let statError = errno
            // The contender disappeared before inspection. Retry the
            // exclusive create rather than falling back to a racy write.
            guard statError == ENOENT else {
                throw Self.posixError(statError)
            }
        }

        throw Self.posixError(EAGAIN)
    }

    private static func writeNewFile(
        descriptor: Int32,
        data: Data,
        directoryDescriptor: Int32,
        fileName: String
    ) throws -> Bool {
        var shouldRemoveIncompleteFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveIncompleteFile {
                _ = Darwin.unlinkat(directoryDescriptor, fileName, 0)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError(errno)
                }
                guard written > 0 else {
                    throw posixError(EIO)
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(errno)
        }
        shouldRemoveIncompleteFile = false
        return true
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

@MainActor
protocol UserConfigurationOpening {
    func open(_ url: URL) -> Bool
}

@MainActor
struct WorkspaceUserConfigurationOpener: UserConfigurationOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

nonisolated enum UserConfigurationOpenOutcome: Sendable, Equatable {
    case opened(createdStarter: Bool)
    case creationFailed
    case openFailed
}

/// Opens (and lazily bootstraps) Pine's user configuration files.
@MainActor
enum UserConfigurationEditor {
    /// Creates the starter file for `file` at its canonical path if it does
    /// not already exist, then never touches it again.
    ///
    /// - Returns: `true` if a new starter file was created, `false` if the
    ///   file already existed (caller may want to distinguish "opened my
    ///   existing config" from "opened a brand-new template").
    @discardableResult
    nonisolated static func ensureStarterFileExists(
        _ file: UserConfigurationFile,
        at url: URL,
        creator: any UserConfigurationFileCreating =
            ExclusiveUserConfigurationFileCreator()
    ) async throws -> Bool {
        let starterData = Data(starterContent(for: file).utf8)
        return try await runOnBackground(qos: .utility) {
            try creator.createIfMissing(data: starterData, at: url)
        }
    }

    /// Reveals the configuration file in the user's default editor.
    /// Creates the starter first so the action always opens something
    /// editable instead of a "file not found" dead end.
    @discardableResult
    static func open(
        _ file: UserConfigurationFile,
        at injectedURL: URL? = nil,
        creator: any UserConfigurationFileCreating =
            ExclusiveUserConfigurationFileCreator(),
        opener: any UserConfigurationOpening =
            WorkspaceUserConfigurationOpener(),
        alertPresenter: any UserConfigurationAlertPresenting =
            AppKitUserConfigurationAlertPresenter()
    ) async -> UserConfigurationOpenOutcome {
        let fileURL = injectedURL ?? url(for: file)
        let createdStarter: Bool
        do {
            createdStarter = try await ensureStarterFileExists(
                file,
                at: fileURL,
                creator: creator
            )
        } catch {
            Logger.extensibility.error(
                "Could not create starter \(file.rawValue) configuration: \(String(describing: error))"
            )
            await alertPresenter.present(creationFailureAlert(file, error: error))
            return .creationFailed
        }

        guard opener.open(fileURL) else {
            Logger.extensibility.error(
                "Could not open \(file.rawValue) configuration at \(fileURL.path)"
            )
            await alertPresenter.present(openFailureAlert(file))
            return .openFailed
        }
        return .opened(createdStarter: createdStarter)
    }

    /// Shortcut for the keybindings config file.
    static func openKeybindings(
        alertPresenter: any UserConfigurationAlertPresenting =
            AppKitUserConfigurationAlertPresenter()
    ) async {
        await open(.keybindings, alertPresenter: alertPresenter)
    }

    /// Shortcut for the tasks config file.
    static func openTasks(
        alertPresenter: any UserConfigurationAlertPresenting =
            AppKitUserConfigurationAlertPresenter()
    ) async {
        await open(.tasks, alertPresenter: alertPresenter)
    }

    // MARK: - Paths & templates

    /// The canonical URL for a configuration file.
    nonisolated static func url(for file: UserConfigurationFile) -> URL {
        switch file {
        case .keybindings:
            UserConfigurationPaths.userKeybindingsFile
        case .tasks:
            UserConfigurationPaths.userTasksFile
        }
    }

    /// Documented, valid-JSON starter content for a configuration file.
    ///
    /// Pure function so it is directly unit-testable without touching disk.
    /// The `_comment` guidance is JSON-encoded so embedded quotes survive
    /// safely; the emitted document always parses.
    nonisolated static func starterContent(
        for file: UserConfigurationFile
    ) -> String {
        switch file {
        case .keybindings:
            starterDocument(
                comment: keybindingsComment,
                arrayKey: "keybindings"
            )
        case .tasks:
            starterDocument(
                comment: tasksComment,
                arrayKey: "tasks"
            )
        }
    }

    nonisolated private static var keybindingsComment: String {
        let guidance = String(
            localized: "userConfig.starter.keybindingsComment",
            defaultValue: """
            Pine keybindings. Add entries to the "keybindings" array below. \
            Each entry maps a command id to a key chord. Supported command \
            ids are listed after this guidance. Chords use lowercase modifiers \
            joined by '+': cmd (or command), shift, alt (or option/opt), ctrl \
            (or control), plus one key (for example 'f', 'return', or 'up'). \
            A dispatch modifier (cmd or ctrl) is required. Reserved system \
            chords and plain text input are rejected.
            """
        )
        let commandIDs = UserCommand.allCases
            .map(\.rawValue)
            .joined(separator: ", ")
        return "\(guidance) \(commandIDs)."
    }

    nonisolated private static var tasksComment: String {
        String(
            localized: "userConfig.starter.tasksComment",
            defaultValue: """
            Pine tasks. Add entries to the "tasks" array below. Each task runs \
            a shell command. Fields: id (unique), label (menu text), command \
            (shell string), scope (activeFile or project; default activeFile), \
            replaces_file_content (default false; when true in activeFile \
            scope, Pine sends the current file content to stdin and applies \
            stdout only if the same editor buffer is still unchanged), \
            require_confirmation (default auto; destructive commands such as \
            rm, chmod, dd, and diskutil prompt for confirmation).
            """
        )
    }

    /// Emits a starter document with a JSON-encoded `_comment` and an empty
    /// `arrayKey` array. Always valid JSON.
    nonisolated private static func starterDocument(
        comment: String,
        arrayKey: String
    ) -> String {
        let encoded = Self.encodeJSONString(comment)
        return """
        {
          "_comment": "\(encoded)",
          "\(arrayKey)": [
          ]
        }
        """
    }

    /// Returns the escaped inner content of a JSON string literal (no
    /// surrounding quotes), so it can be interpolated into a `"...\(encoded)"`
    /// template. Uses JSONEncoder for RFC 8259-compliant escaping.
    nonisolated private static func encodeJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let quoted = String(data: data, encoding: .utf8) else {
            // Fallback: escape only quotes and backslashes.
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // `quoted` is `"…"` — strip the surrounding quotes, keep escapes.
        return String(quoted.dropFirst().dropLast())
    }

    // MARK: - Failure presentation

    static func creationFailureAlert(
        _ file: UserConfigurationFile,
        error: Error
    ) -> UserConfigurationAlertDescriptor {
        UserConfigurationAlertDescriptor(
            style: .warning,
            messageText: String(
                localized: "userConfig.starterCreateFailed.title",
                defaultValue: "Couldn’t create configuration file"
            ),
            informativeText: String(
                localized: "userConfig.starterCreateFailed.message",
                defaultValue: "Pine could not create the \(file.rawValue) configuration file: \(error.localizedDescription)"
            ),
            buttonTitle: NSLocalizedString(
                "userConfig.ok",
                value: "OK",
                comment: "Dismiss button"
            )
        )
    }

    static func openFailureAlert(
        _ file: UserConfigurationFile
    ) -> UserConfigurationAlertDescriptor {
        UserConfigurationAlertDescriptor(
            style: .warning,
            messageText: String(
                localized: "userConfig.openFailed.title",
                defaultValue: "Couldn’t open configuration file"
            ),
            informativeText: String(
                localized: "userConfig.openFailed.message",
                defaultValue: "Pine could not open the \(file.rawValue) configuration file in its default editor."
            ),
            buttonTitle: NSLocalizedString(
                "userConfig.ok",
                value: "OK",
                comment: "Dismiss button"
            )
        )
    }
}
