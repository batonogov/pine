//
//  TerminationSaveCoordinator.swift
//  Pine
//
//  Bounded, off-main staging for application-termination saves.
//

import Darwin
import Foundation

nonisolated struct TerminationSaveRequest: Sendable {
    let tabID: UUID
    let contentVersion: UInt64
    let content: String
    let originalURL: URL?
    let destination: URL
    let expectedDestinationState: TerminationDestinationState
    let encodingRawValue: UInt
    let settings: EditorSaveSettingsSnapshot
    let formatters: FileFormatterRegistry
}

/// Filesystem identity authorized when the user finished choosing a Save As
/// destination (or when an already-backed dirty tab entered Save All).
/// Comparing timestamps as well as inode identity catches in-place external
/// writes while staging is in progress.
nonisolated struct TerminationDestinationState: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let permissions: UInt32
    let ownerID: UInt32
    let groupID: UInt32
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    static let missing = TerminationDestinationState(
        device: 0,
        inode: 0,
        size: -1,
        permissions: 0,
        ownerID: 0,
        groupID: 0,
        modificationSeconds: 0,
        modificationNanoseconds: 0,
        changeSeconds: 0,
        changeNanoseconds: 0
    )

    var exists: Bool { size >= 0 }
}

nonisolated struct TerminationStagedSave: Sendable {
    let request: TerminationSaveRequest
    let stagingURL: URL
    let preparedContent: String
    let stagingDevice: UInt64
    let stagingInode: UInt64
}

nonisolated enum TerminationSaveStageResult: Sendable {
    case ready([TerminationStagedSave])
    case failed(message: String)
    case timedOut
}

nonisolated enum TerminationSaveInstallResult: Sendable {
    case installed
    case failed(message: String)
}

nonisolated private final class TerminationSaveStageResolver:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<TerminationSaveStageResult, Never>?

    init(
        _ continuation: CheckedContinuation<
            TerminationSaveStageResult,
            Never
        >
    ) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: TerminationSaveStageResult) -> Bool {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: result)
        return true
    }
}

nonisolated enum TerminationSaveCoordinator {
    private static let deadlineQueue = DispatchQueue(
        label: "com.pine.termination-save-deadline",
        qos: .userInteractive
    )

    static func stage(
        _ requests: [TerminationSaveRequest],
        until deadline: DispatchTime
    ) async -> TerminationSaveStageResult {
        let deadlineNanoseconds = deadline.uptimeNanoseconds
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            return .timedOut
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationSaveStageResolver(continuation)
            let operationTask = Task.detached(priority: .userInitiated) {
                let result = stageSynchronously(
                    requests,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                if !resolver.resolve(result), case .ready(let staged) = result {
                    cleanup(staged)
                }
            }
            deadlineQueue.asyncAfter(deadline: deadline) {
                if resolver.resolve(.timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }

    static func cleanup(_ staged: [TerminationStagedSave]) {
        for item in staged {
            unlinkRegularFile(
                at: item.stagingURL,
                device: item.stagingDevice,
                inode: item.stagingInode
            )
        }
    }

    static func captureDestinationState(
        at url: URL
    ) async throws -> TerminationDestinationState {
        try await Task.detached(priority: .userInitiated) {
            try destinationState(at: url)
        }.value
    }

    static func destinationStatesAreCurrent(
        _ staged: [TerminationStagedSave]
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            staged.allSatisfy { item in
                destinationStateMatches(
                    item.request.expectedDestinationState,
                    at: item.request.destination
                )
            }
        }.value
    }

    /// Installs exactly the staged inode. Existing destinations are swapped
    /// atomically so the displaced inode can be compared with the state the
    /// user authorized; missing destinations use RENAME_EXCL. This closes the
    /// pathname race between a preflight lstat and rename.
    static func install(
        _ staged: TerminationStagedSave
    ) async -> TerminationSaveInstallResult {
        await Task.detached(priority: .userInitiated) {
            do {
                try installSynchronously(staged)
                return .installed
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }.value
    }

    static func stagingIdentityIsCurrent(
        _ staged: TerminationStagedSave
    ) -> Bool {
        var status = stat()
        guard Darwin.lstat(staged.stagingURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return UInt64(status.st_dev) == staged.stagingDevice
            && UInt64(status.st_ino) == staged.stagingInode
    }

    private static func stageSynchronously(
        _ requests: [TerminationSaveRequest],
        deadlineNanoseconds: UInt64
    ) -> TerminationSaveStageResult {
        var staged: [TerminationStagedSave] = []
        do {
            for request in requests {
                guard !Task.isCancelled else {
                    cleanup(staged)
                    return .timedOut
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    cleanup(staged)
                    return .timedOut
                }
                guard destinationStateMatches(
                    request.expectedDestinationState,
                    at: request.destination
                ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                let remainingSeconds = TimeInterval(
                    deadlineNanoseconds - now
                ) / 1_000_000_000
                let prepared = TabFormatter.contentPreparedForSave(
                    request.content,
                    url: request.destination,
                    settings: request.settings,
                    formatters: request.formatters,
                    formatterMaximumDuration: remainingSeconds
                )
                guard !Task.isCancelled,
                      DispatchTime.now().uptimeNanoseconds
                        < deadlineNanoseconds else {
                    cleanup(staged)
                    return .timedOut
                }
                let encoding = String.Encoding(
                    rawValue: request.encodingRawValue
                )
                guard let data = prepared.data(
                    using: encoding,
                    allowLossyConversion: false
                ) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                let staging = try writeStagingFile(
                    data,
                    beside: request.destination,
                    preservingPermissions: request.expectedDestinationState
                )
                staged.append(TerminationStagedSave(
                    request: request,
                    stagingURL: staging.url,
                    preparedContent: prepared,
                    stagingDevice: staging.device,
                    stagingInode: staging.inode
                ))
            }
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds
                    < deadlineNanoseconds else {
                cleanup(staged)
                return .timedOut
            }
            return .ready(staged)
        } catch {
            cleanup(staged)
            return .failed(message: error.localizedDescription)
        }
    }

    private static func writeStagingFile(
        _ data: Data,
        beside destination: URL,
        preservingPermissions destinationState: TerminationDestinationState
    ) throws -> (url: URL, device: UInt64, inode: UInt64) {
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".pine-save-\(UUID().uuidString).tmp",
                isDirectory: false
            )
        let descriptor = Darwin.open(
            stagingURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH
        )
        guard descriptor >= 0 else {
            throw posixError()
        }
        var keepFile = false
        defer {
            Darwin.close(descriptor)
            if !keepFile {
                Darwin.unlink(stagingURL.path)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw posixError()
                }
                written += result
            }
        }
        if destinationState.exists {
            let metadataFlags = copyfile_flags_t(
                COPYFILE_ACL
                    | COPYFILE_XATTR
                    | COPYFILE_NOFOLLOW
            )
            guard Darwin.copyfile(
                destination.path,
                stagingURL.path,
                nil,
                metadataFlags
            ) == 0 else {
                throw posixError()
            }
            guard Darwin.fchmod(
                descriptor,
                mode_t(destinationState.permissions)
            ) == 0 else {
                throw posixError()
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw posixError()
        }
        keepFile = true
        return (
            stagingURL,
            UInt64(status.st_dev),
            UInt64(status.st_ino)
        )
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func destinationState(
        at url: URL
    ) throws -> TerminationDestinationState {
        var status = stat()
        if Darwin.lstat(url.path, &status) != 0 {
            if errno == ENOENT { return .missing }
            throw posixError()
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return TerminationDestinationState(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: status.st_size,
            permissions: UInt32(status.st_mode & 0o7777),
            ownerID: status.st_uid,
            groupID: status.st_gid,
            modificationSeconds: Int(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int(status.st_mtimespec.tv_nsec),
            changeSeconds: Int(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int(status.st_ctimespec.tv_nsec)
        )
    }

    private static func destinationStateMatches(
        _ expected: TerminationDestinationState,
        at url: URL
    ) -> Bool {
        do {
            return try destinationState(at: url) == expected
        } catch let error as NSError
        where error.domain == NSPOSIXErrorDomain
                && error.code == Int(ENOENT) {
            return !expected.exists
        } catch {
            return false
        }
    }

    private static func installSynchronously(
        _ staged: TerminationStagedSave
    ) throws {
        guard stagingIdentityIsCurrent(staged) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let expected = staged.request.expectedDestinationState
        if expected.exists {
            guard destinationStateMatches(
                expected,
                at: staged.request.destination
            ) else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard rename(
                staged.stagingURL,
                staged.request.destination,
                flags: UInt32(RENAME_SWAP)
            ) == 0 else {
                throw posixError()
            }

            let displacedMatches = displacedStateMatchesAfterSwap(
                expected,
                at: staged.stagingURL
            )
            let installedMatches = regularFileMatches(
                at: staged.request.destination,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            )
            guard displacedMatches, installedMatches else {
                // Roll back only while both pathnames still hold the two
                // inodes produced by our swap. An external replacement after
                // the swap must never be displaced by a blind second swap.
                let displacedIdentityIsExpected = regularFileMatches(
                    at: staged.stagingURL,
                    device: expected.device,
                    inode: expected.inode
                )
                let installedIdentityIsOurs = regularFileMatches(
                    at: staged.request.destination,
                    device: staged.stagingDevice,
                    inode: staged.stagingInode
                )
                if displacedIdentityIsExpected, installedIdentityIsOurs {
                    _ = rename(
                        staged.stagingURL,
                        staged.request.destination,
                        flags: UInt32(RENAME_SWAP)
                    )
                }
                throw CocoaError(.fileWriteUnknown)
            }
            unlinkRegularFile(
                at: staged.stagingURL,
                device: expected.device,
                inode: expected.inode
            )
        } else {
            guard rename(
                staged.stagingURL,
                staged.request.destination,
                flags: UInt32(RENAME_EXCL)
            ) == 0 else {
                throw posixError()
            }
            guard regularFileMatches(
                at: staged.request.destination,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func rename(
        _ source: URL,
        _ destination: URL,
        flags: UInt32
    ) -> Int32 {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
    }

    private static func regularFileMatches(
        at url: URL,
        device: UInt64,
        inode: UInt64
    ) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return UInt64(status.st_dev) == device
            && UInt64(status.st_ino) == inode
    }

    /// A rename updates the inode change time even though the file itself was
    /// not edited. Compare every authorized property that survives the swap;
    /// the strict pre-swap check above still includes ctime.
    private static func displacedStateMatchesAfterSwap(
        _ expected: TerminationDestinationState,
        at url: URL
    ) -> Bool {
        guard let current = try? destinationState(at: url) else {
            return false
        }
        return current.device == expected.device
            && current.inode == expected.inode
            && current.size == expected.size
            && current.permissions == expected.permissions
            && current.ownerID == expected.ownerID
            && current.groupID == expected.groupID
            && current.modificationSeconds == expected.modificationSeconds
            && current.modificationNanoseconds
                == expected.modificationNanoseconds
    }

    private static func unlinkRegularFile(
        at url: URL,
        device: UInt64,
        inode: UInt64
    ) {
        guard regularFileMatches(
            at: url,
            device: device,
            inode: inode
        ) else { return }
        _ = Darwin.unlink(url.path)
    }
}
