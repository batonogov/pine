//
//  ContextFileWriter.swift
//  Pine
//

import CryptoKit
import Darwin
import Foundation

/// Registry-issued identity for one manager incarnation of a canonical root.
/// The epoch orders different managers; the nonce rejects accidental epoch
/// reuse, and each manager's command sequence orders its own show/hide events.
nonisolated struct ContextPresentationIdentity: Sendable, Equatable {
    let epoch: UInt64
    let nonce: UUID

    init(epoch: UInt64, nonce: UUID = UUID()) {
        self.epoch = epoch
        self.nonce = nonce
    }
}

nonisolated struct ContextPresentationCommand: Sendable, Equatable {
    let identity: ContextPresentationIdentity
    let sequence: UInt64
}

/// One registry owns one gate shared by every writer it creates. File actions
/// for the same canonical root run under this lock, so an old manager's actor
/// cannot approve a cleanup and race a newer manager's publish to disk.
nonisolated final class ContextPresentationCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestByProject: [String: ContextPresentationCommand] = [:]

    @discardableResult
    func accept(
        projectIdentity: String,
        command: ContextPresentationCommand,
        perform: () -> Void
    ) -> Bool {
        lock.withLock {
            if let latest = latestByProject[projectIdentity],
               !Self.isSameOrNewer(command, than: latest) {
                return false
            }
            latestByProject[projectIdentity] = command
            perform()
            return true
        }
    }

    @discardableResult
    func performIfCurrent(
        projectIdentity: String,
        command: ContextPresentationCommand,
        perform: () -> Void
    ) -> Bool {
        lock.withLock {
            guard latestByProject[projectIdentity] == command else {
                return false
            }
            perform()
            return true
        }
    }

    private static func isSameOrNewer(
        _ candidate: ContextPresentationCommand,
        than latest: ContextPresentationCommand
    ) -> Bool {
        if candidate.identity.epoch != latest.identity.epoch {
            return candidate.identity.epoch > latest.identity.epoch
        }
        guard candidate.identity.nonce == latest.identity.nonce else {
            return false
        }
        return candidate.sequence >= latest.sequence
    }
}

/// Writes an explicitly enabled, read-only editor-context snapshot to
/// `~/Library/Application Support/Pine/contexts/`.
///
/// Each project gets a unique file name derived from a SHA-256 hash of the project
/// root path. This avoids polluting the project directory with dot-files and
/// prevents FSEvents churn from context file writes.
///
/// Sharing is disabled by default. When enabled, the file is written atomically
/// with a 500ms debounce and owner-only permissions. It contains bounded editor
/// metadata, never source text. The file is deleted when sharing is disabled or
/// the project closes.
actor ContextFileWriter {

    /// Legacy file name that was previously written to the project root.
    static let legacyFileName = ".pine-context.json"

    /// The directory inside Application Support where context files are stored.
    static let contextsDirName = "Pine/contexts"

    /// File permissions: owner read/write only (0600).
    private static let filePermissions: mode_t = 0o600
    /// Directory permissions: owner access only (0700).
    private static let directoryPermissions: mode_t = 0o700
    /// Prevent an unbounded tab list from turning the handoff into a data dump.
    static let maximumOpenFiles = 256
    /// Prevent pathological paths from producing oversized snapshots.
    static let maximumRelativePathUTF8Bytes = 4_096
    /// Generous upper bound that still rejects malformed integer payloads.
    static let maximumCoordinate = 1_000_000_000

    // MARK: - Internal state (visible for testing)

    /// The project root directory. Set via `setProjectRoot(_:)`.
    private(set) var projectRoot: URL?
    /// Whether the user explicitly allowed read-only context sharing.
    private(set) var isReadOnlySharingEnabled = false

    /// Debounce interval in seconds. Exposed for testing.
    private(set) var debounceInterval: TimeInterval = 0.5

    /// Tracks whether a write is pending (for testing).
    private(set) var hasPendingWrite = false
    /// Invalidates stale debounce tasks after updates, revocation, or re-scope.
    private var updateGeneration: UInt64 = 0
    private let presentationGate: ContextPresentationCommandGate

    /// Override for the contexts directory. Used by tests.
    private var contextsDirOverride: URL?

    // MARK: - Private

    private var debounceTask: Task<Void, Never>?

    /// The last context that was written to disk, to avoid redundant writes.
    private var lastWrittenContext: Payload?

    /// Shared encoder instance — no need to recreate on each write.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(
        presentationGate: ContextPresentationCommandGate =
            ContextPresentationCommandGate()
    ) {
        self.presentationGate = presentationGate
    }

    // MARK: - Public API

    /// Atomically applies one complete visible-window handoff state. The
    /// caller captures `commandGeneration` on the main actor; stale commands
    /// are discarded before they can re-scope, revoke, or write the file.
    func publishPresentationSnapshot(
        projectRoot: URL,
        isReadOnlySharingEnabled: Bool,
        payload: Payload,
        command: ContextPresentationCommand
    ) {
        let projectIdentity = Self.projectIdentity(for: projectRoot)
        presentationGate.accept(
            projectIdentity: projectIdentity,
            command: command
        ) {
            setProjectRoot(projectRoot)
            setReadOnlySharingEnabled(isReadOnlySharingEnabled)
            guard isReadOnlySharingEnabled else { return }
            scheduleUpdate(
                payload: Payload(
                    projectIdentity: projectIdentity,
                    openFiles: payload.openFiles,
                    currentFile: payload.currentFile,
                    cursorLine: payload.cursorLine,
                    cursorColumn: payload.cursorColumn
                ),
                presentationCommand: command
            )
        }
    }

    /// Revokes a hidden window's snapshot only if no later visible-window
    /// command has already reached the actor.
    func cleanupPresentationSnapshot(
        projectRoot: URL,
        command: ContextPresentationCommand
    ) {
        presentationGate.accept(
            projectIdentity: Self.projectIdentity(for: projectRoot),
            command: command
        ) {
            setProjectRoot(projectRoot)
            cleanup()
        }
    }

    /// Sets the project root directory. Must be called before `update(...)`.
    /// Also removes the legacy `.pine-context.json` from the project root if present.
    func setProjectRoot(_ url: URL?) {
        if projectRoot != url {
            updateGeneration &+= 1
            debounceTask?.cancel()
            debounceTask = nil
            hasPendingWrite = false
            removeContextFileIfPresent()
            lastWrittenContext = nil
        }
        projectRoot = url
        removeLegacyFileIfNeeded()
    }

    /// Enables or disables the read-only handoff for this project.
    ///
    /// Disabling is revocation: any pending write is cancelled and the
    /// previously published snapshot is removed immediately.
    func setReadOnlySharingEnabled(_ isEnabled: Bool) {
        if isReadOnlySharingEnabled == isEnabled {
            if !isEnabled {
                cleanup()
            }
            return
        }
        updateGeneration &+= 1
        isReadOnlySharingEnabled = isEnabled
        if !isEnabled {
            cleanup()
        }
    }

    /// Sets a custom debounce interval. Intended for tests only.
    func setDebounceInterval(_ interval: TimeInterval) {
        debounceInterval = interval
    }

    /// Overrides the contexts directory. Intended for tests only.
    func setContextsDirectory(_ url: URL) {
        contextsDirOverride = url
    }

    /// Schedules a debounced write of the editor context.
    /// Duplicate writes (same file/line/column) are skipped.
    func update(
        openFiles: [String] = [],
        currentFile: String?,
        cursorLine: Int?,
        cursorColumn: Int?
    ) {
        guard isReadOnlySharingEnabled,
              let projectRoot else {
            return
        }
        let payload = Payload(
            projectIdentity: Self.projectIdentity(for: projectRoot),
            openFiles: Self.boundedRelativePaths(openFiles),
            currentFile: Self.boundedCurrentFile(currentFile),
            cursorLine: Self.boundedCoordinate(cursorLine),
            cursorColumn: Self.boundedCoordinate(cursorColumn)
        )

        scheduleUpdate(payload: payload, presentationCommand: nil)
    }

    private func scheduleUpdate(
        payload: Payload,
        presentationCommand: ContextPresentationCommand?
    ) {
        let boundedPayload = Payload(
            projectIdentity: payload.projectIdentity,
            openFiles: Self.boundedRelativePaths(payload.openFiles),
            currentFile: Self.boundedCurrentFile(payload.currentFile),
            cursorLine: Self.boundedCoordinate(payload.cursorLine),
            cursorColumn: Self.boundedCoordinate(payload.cursorColumn)
        )
        debounceTask?.cancel()
        updateGeneration &+= 1
        hasPendingWrite = true

        let interval = debounceInterval
        let generation = updateGeneration
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return // Cancelled
            }
            guard let self else { return }
            await self.writeContext(
                boundedPayload,
                generation: generation,
                presentationCommand: presentationCommand
            )
        }
    }

    /// Deletes the context file from Application Support.
    /// Called when the project window closes.
    func cleanup() {
        updateGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        hasPendingWrite = false
        lastWrittenContext = nil

        removeContextFileIfPresent()
    }

    /// Returns the URL of the context file for the current project root, or nil.
    var contextFileURL: URL? {
        guard let projectRoot else { return nil }
        let dir = contextsDirectory
        let fileName = Self.hashedFileName(for: projectRoot)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Path computation

    /// Computes a deterministic file name from a project root URL using SHA-256.
    static func hashedFileName(for rootURL: URL) -> String {
        let hash = SHA256.hash(data: Data(canonicalPath(for: rootURL).utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    /// Stable project identity included in every payload so a consumer cannot
    /// accidentally reuse a snapshot for a different project.
    static func projectIdentity(for rootURL: URL) -> String {
        SHA256.hash(data: Data(canonicalPath(for: rootURL).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The directory where context files are stored.
    var contextsDirectory: URL {
        if let override = contextsDirOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.contextsDirName)
    }

    // MARK: - Private helpers

    private func writeContext(
        _ payload: Payload,
        generation: UInt64,
        presentationCommand: ContextPresentationCommand?
    ) {
        guard generation == updateGeneration,
              isReadOnlySharingEnabled else {
            return
        }
        defer {
            if generation == updateGeneration {
                hasPendingWrite = false
            }
        }
        guard let fileURL = contextFileURL else { return }

        if let presentationCommand {
            let projectIdentity = payload.projectIdentity
            presentationGate.performIfCurrent(
                projectIdentity: projectIdentity,
                command: presentationCommand
            ) {
                writeContextToDisk(payload, fileURL: fileURL)
            }
            return
        }

        writeContextToDisk(payload, fileURL: fileURL)
    }

    private func writeContextToDisk(_ payload: Payload, fileURL: URL) {

        // Skip redundant writes
        if payload == lastWrittenContext { return }

        guard let data = try? encoder.encode(payload) else { return }

        // Append trailing newline for POSIX-friendly output
        var output = data
        output.append(contentsOf: [0x0A]) // '\n'

        do {
            let dir = fileURL.deletingLastPathComponent()
            let directoryFD = try secureContextsDirectoryFD(at: dir)
            defer { close(directoryFD) }
            try Self.writeAtomically(
                output,
                fileName: fileURL.lastPathComponent,
                directoryFD: directoryFD
            )
        } catch {
            return
        }

        lastWrittenContext = payload
    }

    /// Removes the legacy `.pine-context.json` from the project root if it exists.
    private func removeLegacyFileIfNeeded() {
        guard let projectRoot else { return }
        let legacyURL = projectRoot.appendingPathComponent(Self.legacyFileName)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private func removeContextFileIfPresent() {
        guard let fileURL = contextFileURL else { return }
        guard let directoryFD = try? secureContextsDirectoryFD(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false
        ) else {
            return
        }
        defer { close(directoryFD) }
        _ = unlinkat(directoryFD, fileURL.lastPathComponent, 0)
        _ = fsync(directoryFD)
    }

    /// Opens the contexts directory without following its final component and
    /// verifies owner/type/link-count invariants before returning its FD.
    private func secureContextsDirectoryFD(
        at directoryURL: URL,
        createIfMissing: Bool = true
    ) throws -> Int32 {
        if createIfMissing {
            let directories: [URL]
            if contextsDirOverride == nil {
                // Application Support is the trusted platform anchor. Pine and
                // contexts are the two components owned by this feature.
                directories = [
                    directoryURL.deletingLastPathComponent(),
                    directoryURL,
                ]
            } else {
                // The override is test-only. Its temporary parent may be
                // nested, so create that fixture path before applying the same
                // no-follow validation to the actual contexts directory.
                try FileManager.default.createDirectory(
                    at: directoryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                directories = [directoryURL]
            }
            for directory in directories {
                if mkdir(directory.path, Self.directoryPermissions) != 0,
                   errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let fd = open(
                    directory.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard fd >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                do {
                    try Self.validatePrivateDirectory(fd)
                    guard fchmod(fd, Self.directoryPermissions) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    close(fd)
                    throw error
                }
                close(fd)
            }
        }

        let directoryFD = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try Self.validatePrivateDirectory(directoryFD)
        } catch {
            close(directoryFD)
            throw error
        }
        return directoryFD
    }

    private static func validatePrivateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_nlink >= 1 else {
            throw POSIXError(.EPERM)
        }
    }

    private static func writeAtomically(
        _ data: Data,
        fileName: String,
        directoryFD: Int32
    ) throws {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/") else {
            throw POSIXError(.EINVAL)
        }

        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let fileFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            Self.filePermissions
        )
        guard fileFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var shouldRemoveTemporary = true
        defer {
            close(fileFD)
            if shouldRemoveTemporary {
                _ = unlinkat(directoryFD, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(fileFD, pointer, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }

        guard fchmod(fileFD, Self.filePermissions) == 0,
              fsync(fileFD) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard renameat(
            directoryFD,
            temporaryName,
            directoryFD,
            fileName
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false
        guard fsync(directoryFD) == 0 else {
            _ = unlinkat(directoryFD, fileName, 0)
            _ = fsync(directoryFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let verificationFD = openat(
            directoryFD,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard verificationFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(verificationFD) }

        var info = stat()
        guard fstat(verificationFD, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size == off_t(data.count),
              info.st_mode & 0o777 == Self.filePermissions else {
            _ = unlinkat(directoryFD, fileName, 0)
            _ = fsync(directoryFD)
            throw POSIXError(.EPERM)
        }
    }

    private static func boundedRelativePaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for path in paths.prefix(maximumOpenFiles) {
            guard isSafeRelativePath(path),
                  seen.insert(path).inserted else {
                continue
            }
            result.append(path)
        }
        return result
    }

    private static func boundedCurrentFile(_ path: String?) -> String? {
        guard let path else { return nil }
        if path.isEmpty { return path }
        return isSafeRelativePath(path) ? path : nil
    }

    private static func boundedCoordinate(_ value: Int?) -> Int? {
        guard let value,
              value >= 0,
              value <= maximumCoordinate else {
            return nil
        }
        return value
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= maximumRelativePathUTF8Bytes,
              !path.hasPrefix("/"),
              !path.contains("\0") else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    private static func canonicalPath(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Relative path computation

    /// Computes the relative path of a file URL within a project root.
    /// Files outside the canonical project root are omitted so the project-
    /// scoped handoff never leaks unrelated path metadata.
    static func relativePath(fileURL: URL?, rootURL: URL) -> String? {
        guard let fileURL else { return nil }
        let rootPath = canonicalPath(for: rootURL)
        let filePath = canonicalPath(for: fileURL)
        guard rootPath != "/" else {
            return String(filePath.dropFirst())
        }
        let prefix = rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }
}

// MARK: - Payload model

extension ContextFileWriter {
    /// The JSON structure written to the context file.
    struct Payload: Codable, Equatable, Sendable {
        /// Version of this one-way, read-only JSON schema.
        let schemaVersion: Int
        /// SHA-256 of the canonical project root; never the absolute path.
        let projectIdentity: String
        /// Bounded, duplicate-free paths relative to the project root.
        let openFiles: [String]
        let currentFile: String?
        let cursorLine: Int?
        let cursorColumn: Int?

        init(
            schemaVersion: Int = 1,
            projectIdentity: String = "",
            openFiles: [String] = [],
            currentFile: String?,
            cursorLine: Int?,
            cursorColumn: Int?
        ) {
            self.schemaVersion = schemaVersion
            self.projectIdentity = projectIdentity
            self.openFiles = openFiles
            self.currentFile = currentFile
            self.cursorLine = cursorLine
            self.cursorColumn = cursorColumn
        }
    }
}
