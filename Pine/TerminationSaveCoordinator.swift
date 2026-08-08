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
    let persistenceGeneration: UInt64
    let content: String
    let originalURL: URL?
    let destination: URL
    let expectedDestinationState: TerminationDestinationState
    let encodingRawValue: UInt
    let settings: EditorSaveSettingsSnapshot
    let formatters: FileFormatterRegistry
}

/// Filesystem identity captured under Quit's machine-work deadline after the
/// user finished choosing every Save As destination.
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
    let parentDevice: UInt64
    let parentInode: UInt64
    let installedMetadata: TerminationInstalledFileMetadata
}

nonisolated struct TerminationInstalledFileMetadata: Sendable {
    let size: Int
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationSeconds)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }
}

nonisolated enum TerminationSaveStageResult: Sendable {
    case ready([TerminationStagedSave])
    case failed(message: String)
    case timedOut
}

nonisolated enum TerminationSaveInstallResult: Sendable {
    case installed(metadata: TerminationInstalledFileMetadata)
    case failed(message: String)
    case timedOut
}

nonisolated enum TerminationDestinationCaptureResult: Sendable {
    case captured([TerminationDestinationState])
    case failed(message: String)
    case timedOut
}

nonisolated private final class TerminationDeadlineResolver<Result: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?

    init(_ continuation: CheckedContinuation<Result, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result) -> Bool {
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
    typealias InstallHook = @Sendable () -> Void

    private struct StagingFile {
        let url: URL
        let device: UInt64
        let inode: UInt64
        let parentDevice: UInt64
        let parentInode: UInt64
        let metadata: TerminationInstalledFileMetadata
    }

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
            let resolver = TerminationDeadlineResolver(continuation)
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
            removeStagingFileIfMatches(item)
        }
    }

    static func captureDestinationStates(
        at urls: [URL],
        until deadline: DispatchTime
    ) async -> TerminationDestinationCaptureResult {
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds else {
            return .timedOut
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationDeadlineResolver(continuation)
            let operationTask = Task.detached(priority: .userInitiated) {
                let result: TerminationDestinationCaptureResult
                do {
                    result = .captured(
                        try urls.map(destinationState(at:))
                    )
                } catch {
                    result = .failed(message: error.localizedDescription)
                }
                _ = resolver.resolve(result)
            }
            deadlineQueue.asyncAfter(deadline: deadline) {
                if resolver.resolve(.timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }

    static func destinationStatesAreCurrent(
        _ staged: [TerminationStagedSave],
        until deadline: DispatchTime
    ) async -> Bool {
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationDeadlineResolver(continuation)
            let operationTask = Task.detached(priority: .userInitiated) {
                let matches = staged.allSatisfy { item in
                    guard !Task.isCancelled else { return false }
                    return destinationStateMatches(
                        item.request.expectedDestinationState,
                        at: item.request.destination
                    )
                }
                _ = resolver.resolve(matches)
            }
            deadlineQueue.asyncAfter(deadline: deadline) {
                if resolver.resolve(false) {
                    operationTask.cancel()
                }
            }
        }
    }

    /// Runs the installer away from the main actor and bounds the caller's
    /// wait by the shared Quit deadline. If an already-started filesystem
    /// syscall completes after that boundary, `lateCompletion` lets the model
    /// owner reconcile the durable result instead of losing track of it.
    static func install(
        _ staged: TerminationStagedSave,
        until deadline: DispatchTime,
        beforeDestinationQuarantine: InstallHook? = nil,
        lateCompletion: @escaping @Sendable (
            TerminationSaveInstallResult
        ) -> Void = { _ in }
    ) async -> TerminationSaveInstallResult {
        let deadlineNanoseconds = deadline.uptimeNanoseconds
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            return .timedOut
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationDeadlineResolver(continuation)
            let operationTask = Task.detached(priority: .userInitiated) {
                let result: TerminationSaveInstallResult
                do {
                    try installSynchronously(
                        staged,
                        deadlineNanoseconds: deadlineNanoseconds,
                        beforeDestinationQuarantine:
                            beforeDestinationQuarantine
                    )
                    result = .installed(metadata: staged.installedMetadata)
                } catch is CancellationError {
                    result = .timedOut
                } catch {
                    result = .failed(message: error.localizedDescription)
                }
                if !resolver.resolve(result) {
                    lateCompletion(result)
                }
            }
            deadlineQueue.asyncAfter(deadline: deadline) {
                if resolver.resolve(.timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }

    static func stagingIdentityIsCurrent(
        _ staged: TerminationStagedSave
    ) -> Bool {
        withVerifiedParentDirectory(
            of: staged.stagingURL,
            staged: staged
        ) { parentDescriptor, stagingLeaf in
            regularFileMatches(
                parentDescriptor: parentDescriptor,
                leaf: stagingLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            )
        } ?? false
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
                    stagingInode: staging.inode,
                    parentDevice: staging.parentDevice,
                    parentInode: staging.parentInode,
                    installedMetadata: staging.metadata
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
    ) throws -> StagingFile {
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".pine-save-\(UUID().uuidString).tmp",
                isDirectory: false
            )
        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(parentDescriptor) }

        var parentStatus = stat()
        guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw posixError()
        }
        let stagingLeaf = stagingURL.lastPathComponent
        let descriptor = Darwin.openat(
            parentDescriptor,
            stagingLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError()
        }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw posixError()
        }
        var keepFile = false
        defer {
            Darwin.close(descriptor)
            if !keepFile {
                removeEntryIfMatches(
                    parentDescriptor: parentDescriptor,
                    leaf: stagingLeaf,
                    device: UInt64(openedStatus.st_dev),
                    inode: UInt64(openedStatus.st_ino)
                )
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
            let sourceDescriptor = Darwin.openat(
                parentDescriptor,
                destination.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard sourceDescriptor >= 0 else { throw posixError() }
            defer { Darwin.close(sourceDescriptor) }
            var sourceStatus = stat()
            guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
                  state(sourceStatus, matches: destinationState) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let metadataFlags = copyfile_flags_t(
                COPYFILE_ACL
                    | COPYFILE_XATTR
            )
            guard Darwin.fcopyfile(
                sourceDescriptor,
                descriptor,
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
        } else {
            // Staging remains owner-only until all bytes are durable. New
            // files receive Pine's normal 0644 document mode only afterward.
            guard Darwin.fchmod(descriptor, 0o644) == 0 else {
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
        return StagingFile(
            url: stagingURL,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            parentDevice: UInt64(parentStatus.st_dev),
            parentInode: UInt64(parentStatus.st_ino),
            metadata: TerminationInstalledFileMetadata(
                size: Int(clamping: status.st_size),
                modificationSeconds: Int(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int(status.st_mtimespec.tv_nsec)
            )
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
        _ staged: TerminationStagedSave,
        deadlineNanoseconds: UInt64,
        beforeDestinationQuarantine: InstallHook?
    ) throws {
        let parentDescriptor = try openVerifiedParentDirectory(for: staged)
        defer { Darwin.close(parentDescriptor) }
        let stagingLeaf = staged.stagingURL.lastPathComponent
        let destinationLeaf = staged.request.destination.lastPathComponent
        guard regularFileMatches(
            parentDescriptor: parentDescriptor,
            leaf: stagingLeaf,
            device: staged.stagingDevice,
            inode: staged.stagingInode
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let expected = staged.request.expectedDestinationState
        if expected.exists {
            let quarantineLeaf = ".pine-save-recovery-\(UUID().uuidString)"
            beforeDestinationQuarantine?()
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds
                    < deadlineNanoseconds else {
                throw CancellationError()
            }
            guard renameExclusive(
                parentDescriptor: parentDescriptor,
                source: destinationLeaf,
                destination: quarantineLeaf
            ) == 0 else {
                throw posixError()
            }

            guard displacedStateMatchesAfterRename(
                expected,
                parentDescriptor: parentDescriptor,
                leaf: quarantineLeaf
            ) else {
                try restoreOrRetainRecovery(
                    parentDescriptor: parentDescriptor,
                    quarantineLeaf: quarantineLeaf,
                    destinationLeaf: destinationLeaf,
                    destinationURL: staged.request.destination
                )
                throw CocoaError(.fileWriteFileExists)
            }
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds
                    < deadlineNanoseconds else {
                try restoreOrRetainRecovery(
                    parentDescriptor: parentDescriptor,
                    quarantineLeaf: quarantineLeaf,
                    destinationLeaf: destinationLeaf,
                    destinationURL: staged.request.destination
                )
                throw CancellationError()
            }
            guard renameExclusive(
                parentDescriptor: parentDescriptor,
                source: stagingLeaf,
                destination: destinationLeaf
            ) == 0 else {
                let installError = posixError()
                try restoreOrRetainRecovery(
                    parentDescriptor: parentDescriptor,
                    quarantineLeaf: quarantineLeaf,
                    destinationLeaf: destinationLeaf,
                    destinationURL: staged.request.destination
                )
                throw installError
            }

            // If another actor immediately replaces the installed inode,
            // fail closed and retain the authorized original for recovery.
            // The editor remains dirty instead of claiming that the external
            // bytes currently at the destination are our saved content.
            guard regularFileMatches(
                parentDescriptor: parentDescriptor,
                leaf: destinationLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            ) else {
                let recoveryURL = staged.request.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(quarantineLeaf)
                throw retainedRecoveryError(at: recoveryURL)
            }
            removeEntryIfMatches(
                parentDescriptor: parentDescriptor,
                leaf: quarantineLeaf,
                device: expected.device,
                inode: expected.inode
            )
        } else {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds
                    < deadlineNanoseconds else {
                throw CancellationError()
            }
            guard renameExclusive(
                parentDescriptor: parentDescriptor,
                source: stagingLeaf,
                destination: destinationLeaf
            ) == 0 else {
                throw posixError()
            }
            guard regularFileMatches(
                parentDescriptor: parentDescriptor,
                leaf: destinationLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            ) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
    }

    private static func openVerifiedParentDirectory(
        for staged: TerminationStagedSave
    ) throws -> Int32 {
        let stagingParent = staged.stagingURL.deletingLastPathComponent()
        let destinationParent = staged.request.destination
            .deletingLastPathComponent()
        guard stagingParent.standardizedFileURL
                == destinationParent.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let descriptor = Darwin.open(
            destinationParent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError() }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              UInt64(status.st_dev) == staged.parentDevice,
              UInt64(status.st_ino) == staged.parentInode else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return descriptor
    }

    private static func withVerifiedParentDirectory<Result>(
        of url: URL,
        staged: TerminationStagedSave,
        _ body: (Int32, String) -> Result
    ) -> Result? {
        guard url.deletingLastPathComponent().standardizedFileURL
                == staged.stagingURL.deletingLastPathComponent()
                    .standardizedFileURL,
              let descriptor = try? openVerifiedParentDirectory(for: staged)
        else { return nil }
        defer { Darwin.close(descriptor) }
        return body(descriptor, url.lastPathComponent)
    }

    private static func renameExclusive(
        parentDescriptor: Int32,
        source: String,
        destination: String
    ) -> Int32 {
        Darwin.renameatx_np(
            parentDescriptor,
            source,
            parentDescriptor,
            destination,
            UInt32(RENAME_EXCL)
        )
    }

    private static func restoreOrRetainRecovery(
        parentDescriptor: Int32,
        quarantineLeaf: String,
        destinationLeaf: String,
        destinationURL: URL
    ) throws {
        guard renameExclusive(
            parentDescriptor: parentDescriptor,
            source: quarantineLeaf,
            destination: destinationLeaf
        ) == 0 else {
            let recoveryURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(quarantineLeaf)
            throw retainedRecoveryError(at: recoveryURL)
        }
    }

    private static func retainedRecoveryError(at recoveryURL: URL) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "A concurrent file replacement was retained at "
                    + recoveryURL.path,
            ]
        )
    }

    private static func displacedStateMatchesAfterRename(
        _ expected: TerminationDestinationState,
        parentDescriptor: Int32,
        leaf: String
    ) -> Bool {
        var status = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            leaf,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return false
        }
        return UInt64(status.st_dev) == expected.device
            && UInt64(status.st_ino) == expected.inode
            && status.st_size == expected.size
            && UInt32(status.st_mode & 0o7777) == expected.permissions
            && status.st_uid == expected.ownerID
            && status.st_gid == expected.groupID
            && Int(status.st_mtimespec.tv_sec)
                == expected.modificationSeconds
            && Int(status.st_mtimespec.tv_nsec)
                == expected.modificationNanoseconds
    }

    private static func state(
        _ status: stat,
        matches expected: TerminationDestinationState
    ) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && UInt64(status.st_dev) == expected.device
            && UInt64(status.st_ino) == expected.inode
            && status.st_size == expected.size
            && UInt32(status.st_mode & 0o7777) == expected.permissions
            && status.st_uid == expected.ownerID
            && status.st_gid == expected.groupID
            && Int(status.st_mtimespec.tv_sec)
                == expected.modificationSeconds
            && Int(status.st_mtimespec.tv_nsec)
                == expected.modificationNanoseconds
            && Int(status.st_ctimespec.tv_sec) == expected.changeSeconds
            && Int(status.st_ctimespec.tv_nsec)
                == expected.changeNanoseconds
    }

    private static func regularFileMatches(
        parentDescriptor: Int32,
        leaf: String,
        device: UInt64,
        inode: UInt64
    ) -> Bool {
        var status = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            leaf,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return UInt64(status.st_dev) == device
            && UInt64(status.st_ino) == inode
    }

    private static func removeStagingFileIfMatches(
        _ staged: TerminationStagedSave
    ) {
        _ = withVerifiedParentDirectory(
            of: staged.stagingURL,
            staged: staged
        ) { parentDescriptor, stagingLeaf in
            removeEntryIfMatches(
                parentDescriptor: parentDescriptor,
                leaf: stagingLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            )
        }
    }

    /// Move-first cleanup prevents a pathname substitution from being blindly
    /// unlinked. A mismatched entry is restored exclusively; if that path has
    /// concurrently reappeared, the entry remains under the recovery name.
    private static func removeEntryIfMatches(
        parentDescriptor: Int32,
        leaf: String,
        device: UInt64,
        inode: UInt64
    ) {
        let cleanupLeaf = ".pine-save-cleanup-\(UUID().uuidString)"
        guard renameExclusive(
            parentDescriptor: parentDescriptor,
            source: leaf,
            destination: cleanupLeaf
        ) == 0 else { return }
        guard regularFileMatches(
            parentDescriptor: parentDescriptor,
            leaf: cleanupLeaf,
            device: device,
            inode: inode
        ) else {
            _ = renameExclusive(
                parentDescriptor: parentDescriptor,
                source: cleanupLeaf,
                destination: leaf
            )
            return
        }
        _ = Darwin.unlinkat(parentDescriptor, cleanupLeaf, 0)
    }
}
