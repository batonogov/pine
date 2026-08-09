//
//  TerminationSaveCoordinator.swift
//  Pine
//
//  Bounded, off-main staging for application-termination saves.
//

import CryptoKit
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
    let contentDigest: Data
    let extendedMetadataDigest: Data

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
        changeNanoseconds: 0,
        contentDigest: Data(),
        extendedMetadataDigest: Data()
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
    let stagingContentDigest: Data
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
    case failed(message: String, retainedArtifacts: [URL])
    case timedOut
}

nonisolated enum TerminationSaveInstallResult: Sendable {
    case installed(metadata: TerminationInstalledFileMetadata)
    case failed(message: String, retainedArtifacts: [URL])
    case timedOut
}

nonisolated enum TerminationSaveCleanupResult: Sendable, Equatable {
    case cleaned
    case failed(message: String, retainedArtifacts: [URL])
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

    private enum ArtifactRemovalResult {
        case removed
        case failed(message: String, retainedURL: URL?)
    }

    private struct DestinationDescriptorSnapshot {
        let state: TerminationDestinationState
        let status: stat
    }

    private struct StagingFile {
        let url: URL
        let device: UInt64
        let inode: UInt64
        let parentDevice: UInt64
        let parentInode: UInt64
        let contentDigest: Data
        let metadata: TerminationInstalledFileMetadata
    }

    private static let deadlineQueue = DispatchQueue(
        label: "com.pine.termination-save-deadline",
        qos: .userInteractive
    )
    /// macOS 27 recreates this provenance marker immediately after a
    /// successful `fremovexattr`. It is kernel-managed launch provenance, not
    /// destination metadata, and carries no staged document bytes.
    private static let privateStagingSystemXattrs = Set([
        "com.apple.provenance",
    ])

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

    @discardableResult
    static func cleanup(
        _ staged: [TerminationStagedSave]
    ) -> TerminationSaveCleanupResult {
        var failures: [String] = []
        var retainedArtifacts: [URL] = []
        for item in staged {
            switch removeStagingFileIfMatches(item) {
            case .removed:
                break
            case .failed(let message, let retainedURL):
                failures.append(message)
                if let retainedURL {
                    retainedArtifacts.append(retainedURL)
                }
            }
        }
        guard failures.isEmpty else {
            return .failed(
                message: failures.joined(separator: "\n"),
                retainedArtifacts: retainedArtifacts
            )
        }
        return .cleaned
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
                    let deadlineNanoseconds = deadline.uptimeNanoseconds
                    result = .captured(
                        try urls.map {
                            try destinationState(
                                at: $0,
                                deadlineNanoseconds: deadlineNanoseconds
                            )
                        }
                    )
                } catch is CancellationError {
                    result = .timedOut
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
                        at: item.request.destination,
                        deadlineNanoseconds: deadline.uptimeNanoseconds
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
        afterDestinationPublication: InstallHook? = nil,
        beforeRecoveryCleanup: InstallHook? = nil,
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
                            beforeDestinationQuarantine,
                        afterDestinationPublication:
                            afterDestinationPublication,
                        beforeRecoveryCleanup: beforeRecoveryCleanup
                    )
                    result = .installed(metadata: staged.installedMetadata)
                } catch is CancellationError {
                    result = .timedOut
                } catch {
                    result = .failed(
                        message: error.localizedDescription,
                        retainedArtifacts: retainedArtifacts(from: error)
                    )
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
                    return stageCancellationResult(staged)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    return stageCancellationResult(staged)
                }
                guard destinationStateMatches(
                    request.expectedDestinationState,
                    at: request.destination,
                    deadlineNanoseconds: deadlineNanoseconds
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
                    return stageCancellationResult(staged)
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
                    beside: request.destination
                )
                staged.append(TerminationStagedSave(
                    request: request,
                    stagingURL: staging.url,
                    preparedContent: prepared,
                    stagingDevice: staging.device,
                    stagingInode: staging.inode,
                    parentDevice: staging.parentDevice,
                    parentInode: staging.parentInode,
                    stagingContentDigest: staging.contentDigest,
                    installedMetadata: staging.metadata
                ))
            }
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds
                    < deadlineNanoseconds else {
                return stageCancellationResult(staged)
            }
            return .ready(staged)
        } catch {
            if case .failed(let message, let retainedArtifacts) = cleanup(staged) {
                return .failed(
                    message: message,
                    retainedArtifacts: retainedArtifacts
                )
            }
            return .failed(
                message: error.localizedDescription,
                retainedArtifacts: []
            )
        }
    }

    private static func stageCancellationResult(
        _ staged: [TerminationStagedSave]
    ) -> TerminationSaveStageResult {
        if case .failed(let message, let retainedArtifacts) = cleanup(staged) {
            return .failed(
                message: message,
                retainedArtifacts: retainedArtifacts
            )
        }
        return .timedOut
    }

    private static func writeStagingFile(
        _ data: Data,
        beside destination: URL
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
        defer { Darwin.close(descriptor) }

        do {
            try makeDescriptorPrivate(descriptor)
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
            guard Darwin.fsync(descriptor) == 0 else {
                throw posixError()
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG else {
                throw posixError()
            }
            return StagingFile(
                url: stagingURL,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                parentDevice: UInt64(parentStatus.st_dev),
                parentInode: UInt64(parentStatus.st_ino),
                contentDigest: Data(SHA256.hash(data: data)),
                metadata: TerminationInstalledFileMetadata(
                    size: Int(clamping: status.st_size),
                    modificationSeconds: Int(status.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int(status.st_mtimespec.tv_nsec)
                )
            )
        } catch {
            let stagingError = error
            switch removeEntryIfMatches(
                    parentDescriptor: parentDescriptor,
                    parentURL: parentURL,
                    leaf: stagingLeaf,
                    device: UInt64(openedStatus.st_dev),
                    inode: UInt64(openedStatus.st_ino)
            ) {
            case .removed:
                throw stagingError
            case .failed(let message, let retainedURL):
                if let retainedURL {
                    throw retainedRecoveryError(
                        at: retainedURL,
                        reason: message
                    )
                }
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileWriteUnknown.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func destinationState(
        at url: URL,
        deadlineNanoseconds: UInt64
    ) throws -> TerminationDestinationState {
        try checkDeadline(deadlineNanoseconds)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            if errno == ENOENT { return .missing }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }
        let snapshot = try destinationSnapshot(
            descriptor,
            deadlineNanoseconds: deadlineNanoseconds
        )
        var live = stat()
        guard Darwin.lstat(url.path, &live) == 0,
              sameObject(snapshot.status, live) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return snapshot.state
    }

    private static func destinationStateMatches(
        _ expected: TerminationDestinationState,
        at url: URL,
        deadlineNanoseconds: UInt64
    ) -> Bool {
        do {
            return try destinationState(
                at: url,
                deadlineNanoseconds: deadlineNanoseconds
            ) == expected
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
        beforeDestinationQuarantine: InstallHook?,
        afterDestinationPublication: InstallHook?,
        beforeRecoveryCleanup: InstallHook?
    ) throws {
        let parentDescriptor = try openVerifiedParentDirectory(for: staged)
        defer { Darwin.close(parentDescriptor) }
        let parentURL = staged.request.destination.deletingLastPathComponent()
        let stagingLeaf = staged.stagingURL.lastPathComponent
        let destinationLeaf = staged.request.destination.lastPathComponent
        let stagingDescriptor = Darwin.openat(
            parentDescriptor,
            stagingLeaf,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard stagingDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(stagingDescriptor) }
        guard try stagingDescriptorIsAuthorized(
            stagingDescriptor,
            staged: staged,
            deadlineNanoseconds: deadlineNanoseconds
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let expected = staged.request.expectedDestinationState
        if expected.exists {
            let quarantineLeaf = ".pine-save-recovery-\(UUID().uuidString)"
            let quarantineURL = parentURL.appendingPathComponent(quarantineLeaf)
            beforeDestinationQuarantine?()
            try checkDeadline(deadlineNanoseconds)
            let destinationDescriptor = Darwin.openat(
                parentDescriptor,
                destinationLeaf,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard destinationDescriptor >= 0 else { throw posixError() }
            defer { Darwin.close(destinationDescriptor) }
            let immediateSnapshot = try destinationSnapshot(
                destinationDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
            guard immediateSnapshot.state == expected,
                  pathMatches(
                      parentDescriptor: parentDescriptor,
                      leaf: destinationLeaf,
                      status: immediateSnapshot.status
                  ) else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard renameExclusive(
                parentDescriptor: parentDescriptor,
                source: destinationLeaf,
                destination: quarantineLeaf
            ) == 0 else {
                throw posixError()
            }
            var stagingWasPublished = false
            do {
                try synchronizeDirectory(parentDescriptor)
                let displacedSnapshot = try destinationSnapshot(
                    destinationDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                guard authorizedContentAndMetadataMatch(
                    displacedSnapshot.state,
                    expected: expected
                ),
                      pathMatches(
                          parentDescriptor: parentDescriptor,
                          leaf: quarantineLeaf,
                          status: displacedSnapshot.status
                      ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try checkDeadline(deadlineNanoseconds)
                guard renameExclusive(
                    parentDescriptor: parentDescriptor,
                    source: stagingLeaf,
                    destination: destinationLeaf
                ) == 0 else {
                    throw posixError()
                }
                stagingWasPublished = true
                afterDestinationPublication?()
                try applyExistingDestinationMetadata(
                    from: destinationDescriptor,
                    status: displacedSnapshot.status,
                    to: stagingDescriptor
                )
                guard try installedMetadataMatches(
                    stagingDescriptor,
                    expected: expected,
                    deadlineNanoseconds: deadlineNanoseconds
                ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } catch {
                let installError = error
                if stagingWasPublished {
                    try rollbackPublishedStaging(
                        staged,
                        stagingDescriptor: stagingDescriptor,
                        parentDescriptor: parentDescriptor,
                        quarantineLeaf: quarantineLeaf
                    )
                } else {
                    var stagingSecurityError: Error?
                    do {
                        try resecureStaging(
                            stagingDescriptor,
                            at: staged.stagingURL
                        )
                    } catch {
                        stagingSecurityError = error
                    }
                    try restoreOrRetainRecovery(
                        parentDescriptor: parentDescriptor,
                        quarantineLeaf: quarantineLeaf,
                        destinationLeaf: destinationLeaf,
                        destinationURL: staged.request.destination
                    )
                    if let stagingSecurityError {
                        throw stagingSecurityError
                    }
                }
                throw installError
            }
            do {
                try synchronizeDirectory(parentDescriptor)
            } catch {
                throw retainedRecoveryError(
                    at: quarantineURL,
                    reason: "The saved destination was installed, but its "
                        + "directory entry could not be made durable"
                )
            }
            guard regularFileMatches(
                parentDescriptor: parentDescriptor,
                leaf: destinationLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            ) else {
                throw retainedRecoveryError(at: quarantineURL)
            }
            beforeRecoveryCleanup?()
            switch removeEntryIfMatches(
                parentDescriptor: parentDescriptor,
                parentURL: parentURL,
                leaf: quarantineLeaf,
                device: expected.device,
                inode: expected.inode
            ) {
            case .removed:
                break
            case .failed(let message, let retainedURL):
                if let retainedURL {
                    throw retainedRecoveryError(
                        at: retainedURL,
                        reason: message
                    )
                }
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        } else {
            try checkDeadline(deadlineNanoseconds)
            var destinationStatus = stat()
            guard Darwin.fstatat(
                parentDescriptor,
                destinationLeaf,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
                  errno == ENOENT else {
                try resecureStaging(stagingDescriptor, at: staged.stagingURL)
                throw CocoaError(.fileWriteFileExists)
            }
            guard renameExclusive(
                parentDescriptor: parentDescriptor,
                source: stagingLeaf,
                destination: destinationLeaf
            ) == 0 else {
                let installError = posixError()
                try resecureStaging(stagingDescriptor, at: staged.stagingURL)
                throw installError
            }
            do {
                afterDestinationPublication?()
                try applyMissingDestinationMetadata(
                    parentDescriptor: parentDescriptor,
                    parentURL: parentURL,
                    destinationDescriptor: stagingDescriptor
                )
                guard regularFileMatches(
                    parentDescriptor: parentDescriptor,
                    leaf: destinationLeaf,
                    device: staged.stagingDevice,
                    inode: staged.stagingInode
                ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try synchronizeDirectory(parentDescriptor)
            } catch {
                let installError = error
                try rollbackPublishedNewDestination(
                    staged,
                    stagingDescriptor: stagingDescriptor,
                    parentDescriptor: parentDescriptor,
                    stagingLeaf: stagingLeaf,
                    destinationLeaf: destinationLeaf
                )
                throw installError
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
        try synchronizeDirectory(parentDescriptor)
    }

    private static func rollbackPublishedStaging(
        _ staged: TerminationStagedSave,
        stagingDescriptor: Int32,
        parentDescriptor: Int32,
        quarantineLeaf: String
    ) throws {
        let stagingLeaf = staged.stagingURL.lastPathComponent
        let destinationLeaf = staged.request.destination.lastPathComponent
        let recoveryURL = staged.request.destination
            .deletingLastPathComponent()
            .appendingPathComponent(quarantineLeaf)
        guard regularFileMatches(
            parentDescriptor: parentDescriptor,
            leaf: destinationLeaf,
            device: staged.stagingDevice,
            inode: staged.stagingInode
        ),
              renameExclusive(
                  parentDescriptor: parentDescriptor,
                  source: destinationLeaf,
                  destination: stagingLeaf
              ) == 0 else {
            throw retainedRecoveryError(at: recoveryURL)
        }

        var stagingSecurityError: Error?
        do {
            try resecureStaging(stagingDescriptor, at: staged.stagingURL)
        } catch {
            stagingSecurityError = error
        }
        try restoreOrRetainRecovery(
            parentDescriptor: parentDescriptor,
            quarantineLeaf: quarantineLeaf,
            destinationLeaf: destinationLeaf,
            destinationURL: staged.request.destination
        )
        if let stagingSecurityError {
            throw stagingSecurityError
        }
    }

    private static func rollbackPublishedNewDestination(
        _ staged: TerminationStagedSave,
        stagingDescriptor: Int32,
        parentDescriptor: Int32,
        stagingLeaf: String,
        destinationLeaf: String
    ) throws {
        guard regularFileMatches(
            parentDescriptor: parentDescriptor,
            leaf: destinationLeaf,
            device: staged.stagingDevice,
            inode: staged.stagingInode
        ),
              renameExclusive(
                  parentDescriptor: parentDescriptor,
                  source: destinationLeaf,
                  destination: stagingLeaf
              ) == 0 else {
            throw retainedRecoveryError(at: staged.request.destination)
        }
        try resecureStaging(stagingDescriptor, at: staged.stagingURL)
        try synchronizeDirectory(parentDescriptor)
    }

    private static func retainedRecoveryError(
        at recoveryURL: URL,
        reason: String = "A concurrent file replacement was retained"
    ) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(reason) at \(recoveryURL.path)",
                "PineTerminationRetainedArtifactURLs": [recoveryURL],
            ]
        )
    }

    private static func retainedArtifacts(from error: Error) -> [URL] {
        let nsError = error as NSError
        return nsError.userInfo[
            "PineTerminationRetainedArtifactURLs"
        ] as? [URL] ?? []
    }

    private static func checkDeadline(_ deadlineNanoseconds: UInt64) throws {
        guard !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            throw CancellationError()
        }
    }

    private static func destinationSnapshot(
        _ descriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> DestinationDescriptorSnapshot {
        try checkDeadline(deadlineNanoseconds)
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let contentDigest = try contentDigest(
            descriptor,
            deadlineNanoseconds: deadlineNanoseconds
        )
        let metadataDigest = try extendedMetadataDigest(
            descriptor,
            deadlineNanoseconds: deadlineNanoseconds
        )
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              stableStatus(before, after) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return DestinationDescriptorSnapshot(
            state: TerminationDestinationState(
                device: UInt64(after.st_dev),
                inode: UInt64(after.st_ino),
                size: after.st_size,
                permissions: UInt32(after.st_mode & 0o7777),
                ownerID: after.st_uid,
                groupID: after.st_gid,
                modificationSeconds: Int(after.st_mtimespec.tv_sec),
                modificationNanoseconds: Int(after.st_mtimespec.tv_nsec),
                changeSeconds: Int(after.st_ctimespec.tv_sec),
                changeNanoseconds: Int(after.st_ctimespec.tv_nsec),
                contentDigest: contentDigest,
                extendedMetadataDigest: metadataDigest
            ),
            status: after
        )
    }

    private static func contentDigest(
        _ descriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> Data {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkDeadline(deadlineNanoseconds)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.pread(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count,
                    offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
        return Data(hasher.finalize())
    }

    private static func extendedMetadataDigest(
        _ descriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> Data {
        var hasher = SHA256()
        let names = try extendedAttributeNames(descriptor).sorted()
        for name in names {
            try checkDeadline(deadlineNanoseconds)
            updateDigest(&hasher, with: Data(name.utf8))
            updateDigest(
                &hasher,
                with: try extendedAttributeValue(descriptor, name: name)
            )
        }
        updateDigest(&hasher, with: try extendedACLData(descriptor))
        return Data(hasher.finalize())
    }

    private static func updateDigest(
        _ hasher: inout SHA256,
        with data: Data
    ) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private static func extendedAttributeNames(
        _ descriptor: Int32
    ) throws -> [String] {
        let required = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard required >= 0 else { throw posixError() }
        guard required > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: required)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            Darwin.flistxattr(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count >= 0 else { throw posixError() }
        let raw = bytes.prefix(count).map(UInt8.init(bitPattern:))
        var names: [String] = []
        var start = raw.startIndex
        for index in raw.indices where raw[index] == 0 {
            guard index > start,
                  let name = String(
                      bytes: raw[start..<index],
                      encoding: .utf8
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            names.append(name)
            start = raw.index(after: index)
        }
        guard start == raw.endIndex else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return names
    }

    private static func extendedAttributeValue(
        _ descriptor: Int32,
        name: String
    ) throws -> Data {
        let required = name.withCString {
            Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
        }
        guard required >= 0 else { throw posixError() }
        var data = Data(count: required)
        let count = data.withUnsafeMutableBytes { buffer in
            name.withCString {
                Darwin.fgetxattr(
                    descriptor,
                    $0,
                    buffer.baseAddress,
                    buffer.count,
                    0,
                    0
                )
            }
        }
        guard count == required else { throw posixError() }
        return data
    }

    private static func extendedACLData(_ descriptor: Int32) throws -> Data {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) else {
            guard errno == 0 || errno == ENOENT else { throw posixError() }
            return Data()
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = Darwin.acl_to_text(acl, &length) else {
            throw posixError()
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(text)) }
        return Data(bytes: text, count: length)
    }

    private static func stableStatus(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private static func pathMatches(
        parentDescriptor: Int32,
        leaf: String,
        status: stat
    ) -> Bool {
        var live = stat()
        return Darwin.fstatat(
            parentDescriptor,
            leaf,
            &live,
            AT_SYMLINK_NOFOLLOW
        ) == 0 && sameObject(status, live)
    }

    private static func authorizedContentAndMetadataMatch(
        _ actual: TerminationDestinationState,
        expected: TerminationDestinationState
    ) -> Bool {
        actual.device == expected.device
            && actual.inode == expected.inode
            && actual.size == expected.size
            && actual.permissions == expected.permissions
            && actual.ownerID == expected.ownerID
            && actual.groupID == expected.groupID
            && actual.modificationSeconds == expected.modificationSeconds
            && actual.modificationNanoseconds
                == expected.modificationNanoseconds
            && actual.contentDigest == expected.contentDigest
            && actual.extendedMetadataDigest
                == expected.extendedMetadataDigest
    }

    private static func stagingDescriptorIsAuthorized(
        _ descriptor: Int32,
        staged: TerminationStagedSave,
        deadlineNanoseconds: UInt64
    ) throws -> Bool {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              UInt64(status.st_dev) == staged.stagingDevice,
              UInt64(status.st_ino) == staged.stagingInode,
              status.st_uid == Darwin.getuid(),
              status.st_nlink == 1,
              (status.st_mode & 0o7777) == 0o600,
              try privateStagingXattrsAreSafe(descriptor),
              try descriptorHasNoExtendedACL(descriptor) else {
            return false
        }
        return try contentDigest(
            descriptor,
            deadlineNanoseconds: deadlineNanoseconds
        ) == staged.stagingContentDigest
    }

    private static func descriptorHasNoExtendedACL(
        _ descriptor: Int32
    ) throws -> Bool {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) else {
            guard errno == 0 || errno == ENOENT else { throw posixError() }
            return true
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = Darwin.acl_get_entry(
            acl,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        )
        guard result >= 0 else { throw posixError() }
        return result == 0
    }

    private static func makeDescriptorPrivate(_ descriptor: Int32) throws {
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError()
        }
        for name in try extendedAttributeNames(descriptor)
        where !privateStagingSystemXattrs.contains(name) {
            let result = name.withCString {
                Darwin.fremovexattr(descriptor, $0, 0)
            }
            guard result == 0 || errno == ENOATTR else { throw posixError() }
        }
        if !(try descriptorHasNoExtendedACL(descriptor)) {
            try deleteExtendedACL(from: descriptor)
        }
        guard try privateStagingXattrsAreSafe(descriptor),
              try descriptorHasNoExtendedACL(descriptor) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func privateStagingXattrsAreSafe(
        _ descriptor: Int32
    ) throws -> Bool {
        try extendedAttributeNames(descriptor).allSatisfy {
            privateStagingSystemXattrs.contains($0)
        }
    }

    /// `acl_delete_fd_np` is a public libSystem symbol on every supported
    /// macOS release, but the Swift Darwin overlay does not import it. Resolve
    /// that exact descriptor-based API dynamically so ACL removal stays free
    /// of pathname races.
    private static func deleteExtendedACL(from descriptor: Int32) throws {
        guard let handle = Darwin.dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else {
            throw posixError()
        }
        defer { Darwin.dlclose(handle) }
        guard let symbol = Darwin.dlsym(handle, "acl_delete_fd_np") else {
            throw CocoaError(.fileWriteUnknown)
        }
        typealias DeleteACL = @convention(c) (
            Int32,
            acl_type_t
        ) -> Int32
        let deleteACL = unsafeBitCast(symbol, to: DeleteACL.self)
        guard deleteACL(descriptor, ACL_TYPE_EXTENDED) == 0
                || errno == ENOENT else {
            throw posixError()
        }
    }

    private static func resecureStaging(
        _ descriptor: Int32,
        at stagingURL: URL
    ) throws {
        do {
            try makeDescriptorPrivate(descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            throw retainedRecoveryError(
                at: stagingURL,
                reason: "Staged save bytes could not be resecured"
            )
        }
    }

    private static func applyExistingDestinationMetadata(
        from sourceDescriptor: Int32,
        status: stat,
        to destinationDescriptor: Int32
    ) throws {
        guard Darwin.fchown(
            destinationDescriptor,
            status.st_uid,
            status.st_gid
        ) == 0 else {
            throw posixError()
        }
        let metadataFlags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)
        guard Darwin.fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            metadataFlags
        ) == 0,
              Darwin.fchmod(
                  destinationDescriptor,
                  mode_t(status.st_mode & 0o7777)
              ) == 0,
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw posixError()
        }
    }

    private static func installedMetadataMatches(
        _ descriptor: Int32,
        expected: TerminationDestinationState,
        deadlineNanoseconds: UInt64
    ) throws -> Bool {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError()
        }
        return try UInt32(status.st_mode & 0o7777) == expected.permissions
            && status.st_uid == expected.ownerID
            && status.st_gid == expected.groupID
            && extendedMetadataDigest(
                descriptor,
                deadlineNanoseconds: deadlineNanoseconds
            ) == expected.extendedMetadataDigest
    }

    private static func applyMissingDestinationMetadata(
        parentDescriptor: Int32,
        parentURL: URL,
        destinationDescriptor: Int32
    ) throws {
        let leaf = ".pine-save-mode-\(UUID().uuidString).tmp"
        let probeDescriptor = Darwin.openat(
            parentDescriptor,
            leaf,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o666)
        )
        guard probeDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(probeDescriptor) }
        var status = stat()
        guard Darwin.fstat(probeDescriptor, &status) == 0 else {
            throw posixError()
        }
        let expectedACL = try extendedACLData(probeDescriptor)
        var metadataError: Error?
        do {
            guard Darwin.fcopyfile(
                probeDescriptor,
                destinationDescriptor,
                nil,
                copyfile_flags_t(COPYFILE_ACL)
            ) == 0,
                  Darwin.fchmod(
                      destinationDescriptor,
                      mode_t(status.st_mode & 0o7777)
                  ) == 0,
                  Darwin.fsync(destinationDescriptor) == 0 else {
                throw posixError()
            }
            var installedStatus = stat()
            guard Darwin.fstat(destinationDescriptor, &installedStatus) == 0,
                  installedStatus.st_uid == status.st_uid,
                  installedStatus.st_gid == status.st_gid,
                  (installedStatus.st_mode & 0o7777)
                    == (status.st_mode & 0o7777),
                  try extendedACLData(destinationDescriptor) == expectedACL
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            metadataError = error
        }

        let removal = removeEntryIfMatches(
            parentDescriptor: parentDescriptor,
            parentURL: parentURL,
            leaf: leaf,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        switch removal {
        case .removed:
            break
        case .failed(let message, let retainedURL):
            if let retainedURL {
                throw retainedRecoveryError(at: retainedURL, reason: message)
            }
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        if let metadataError {
            throw metadataError
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
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
    ) -> ArtifactRemovalResult {
        let result = withVerifiedParentDirectory(
            of: staged.stagingURL,
            staged: staged
        ) { parentDescriptor, stagingLeaf in
            removeEntryIfMatches(
                parentDescriptor: parentDescriptor,
                parentURL: staged.stagingURL.deletingLastPathComponent(),
                leaf: stagingLeaf,
                device: staged.stagingDevice,
                inode: staged.stagingInode
            )
        }
        return result ?? .failed(
            message: "Could not verify the staged-save directory",
            retainedURL: staged.stagingURL
        )
    }

    /// Move-first cleanup prevents a pathname substitution from being blindly
    /// unlinked. A mismatched entry is restored exclusively; if that path has
    /// concurrently reappeared, the entry remains under the recovery name.
    private static func removeEntryIfMatches(
        parentDescriptor: Int32,
        parentURL: URL,
        leaf: String,
        device: UInt64,
        inode: UInt64
    ) -> ArtifactRemovalResult {
        let cleanupLeaf = ".pine-save-cleanup-\(UUID().uuidString)"
        let originalURL = parentURL.appendingPathComponent(leaf)
        let cleanupURL = parentURL.appendingPathComponent(cleanupLeaf)
        guard renameExclusive(
            parentDescriptor: parentDescriptor,
            source: leaf,
            destination: cleanupLeaf
        ) == 0 else {
            if errno == ENOENT { return .removed }
            return .failed(
                message: "Could not quarantine an artifact before cleanup",
                retainedURL: originalURL
            )
        }
        do {
            try synchronizeDirectory(parentDescriptor)
        } catch {
            return .failed(
                message: "Could not make artifact quarantine durable",
                retainedURL: cleanupURL
            )
        }
        guard regularFileMatches(
            parentDescriptor: parentDescriptor,
            leaf: cleanupLeaf,
            device: device,
            inode: inode
        ) else {
            let restored = renameExclusive(
                parentDescriptor: parentDescriptor,
                source: cleanupLeaf,
                destination: leaf
            ) == 0
            if restored {
                try? synchronizeDirectory(parentDescriptor)
            }
            return .failed(
                message: "An artifact changed identity during cleanup",
                retainedURL: restored ? originalURL : cleanupURL
            )
        }
        guard Darwin.unlinkat(parentDescriptor, cleanupLeaf, 0) == 0 else {
            return .failed(
                message: "Could not unlink a quarantined artifact",
                retainedURL: cleanupURL
            )
        }
        do {
            try synchronizeDirectory(parentDescriptor)
            return .removed
        } catch {
            return .failed(
                message: "Artifact removal could not be made durable",
                retainedURL: nil
            )
        }
    }
}
