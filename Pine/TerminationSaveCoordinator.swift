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
    let encodingRawValue: UInt
    let settings: EditorSaveSettingsSnapshot
    let formatters: FileFormatterRegistry
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
            try? FileManager.default.removeItem(at: item.stagingURL)
        }
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
                    beside: request.destination
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
        beside destination: URL
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
            S_IRUSR | S_IWUSR
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
}
