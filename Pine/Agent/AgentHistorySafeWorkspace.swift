//
//  AgentHistorySafeWorkspace.swift
//  Pine
//
//  Descriptor-relative filesystem access for checked Agent History undo.
//  Every workspace component is opened with O_NOFOLLOW beneath one root
//  descriptor. Mutations use same-directory quarantine files and
//  rename-without-replacement so a concurrent path swap is refused instead of
//  overwriting unrelated work.
//

import Darwin
import Foundation

nonisolated struct AgentHistorySafeFileSnapshot: Sendable, Equatable {
    let relativePath: String
    let data: Data?
    let permissions: UInt16?
    let device: UInt64?
    let inode: UInt64?

    var exists: Bool { data != nil }
}

nonisolated struct AgentHistorySafeMutation: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case replaced
        case removed
        case created
    }

    let transactionID: UUID
    let kind: Kind
    let relativePath: String
    let quarantineName: String?
    let quarantinedDevice: UInt64?
    let quarantinedInode: UInt64?
    let quarantinedContentSHA256: String?
    let quarantinedByteCount: UInt64?
    let quarantinedPermissions: UInt16?
    let installedDevice: UInt64?
    let installedInode: UInt64?
    let installedContentSHA256: String?
    let installedByteCount: UInt64?
    let installedPermissions: UInt16?
}

nonisolated struct AgentHistorySafeInstallation: Sendable, Equatable {
    let transactionID: UUID
    let kind: AgentHistorySafeMutation.Kind
    let quarantine: AgentHistorySafeMutation?
}

nonisolated enum AgentHistorySafeCommitResult: Sendable, Equatable {
    case complete
    case retained(String)
    case failed(String?)
}

nonisolated struct AgentHistorySafeRollbackResult: Sendable, Equatable {
    let succeeded: Bool
    let retainedPaths: [String]

    static let failed = AgentHistorySafeRollbackResult(
        succeeded: false,
        retainedPaths: []
    )
}

/// An opened workspace root plus descriptor-relative read/mutation helpers.
/// Instances are intentionally short-lived and confined to one background
/// checked-undo transaction.
nonisolated final class AgentHistorySafeWorkspace {
    private struct RecoveryArtifact: Equatable {
        let relativePath: String
        let leaf: String
    }

    private let rootDescriptor: Int32
    let canonicalRoot: URL
    private let recoveryArtifactsLock = NSLock()
    private var recoveryArtifacts: [RecoveryArtifact] = []

    init(
        root: URL,
        expectedDevice: UInt64? = nil,
        expectedInode: UInt64? = nil
    ) throws {
        canonicalRoot = URL(
            fileURLWithPath: AgentHistoryContentHash.canonicalRootPath(root),
            isDirectory: true
        )
        let openedRoot = open(
            canonicalRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard openedRoot >= 0 else {
            throw AgentHistorySafeWorkspaceError.posixFailure(errno)
        }

        var info = stat()
        guard fstat(openedRoot, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            close(openedRoot)
            throw AgentHistorySafeWorkspaceError.invalidRoot
        }
        if let expectedDevice,
           let expectedInode,
           UInt64(info.st_dev) != expectedDevice || UInt64(info.st_ino) != expectedInode {
            close(openedRoot)
            throw AgentHistorySafeWorkspaceError.rootIdentityChanged
        }
        rootDescriptor = openedRoot
    }

    deinit {
        close(rootDescriptor)
    }

    /// Confirms the opened root inode is still reachable at the canonical
    /// project path. Reopening and comparing identity catches a root that was
    /// renamed away while a same-looking replacement was installed there.
    func isStillBoundToCanonicalPath() -> Bool {
        descriptorMatchesPath(
            rootDescriptor,
            path: canonicalRoot.standardizedFileURL.path
        )
    }

    /// Captures a file only up to its recorded size. A `nil` byte count means
    /// the caller expects the path to be absent; if an entry exists, return
    /// metadata-only presence so delete/create checks fail without reading an
    /// attacker-controlled replacement.
    func snapshot(
        relativePath: String,
        expectedByteCount: UInt64?
    ) throws -> AgentHistorySafeFileSnapshot {
        try withParent(relativePath: relativePath) { parentDescriptor, leaf in
            var pathInfo = stat()
            if fstatat(
                parentDescriptor,
                leaf,
                &pathInfo,
                AT_SYMLINK_NOFOLLOW
            ) != 0 {
                if errno == ENOENT {
                    return AgentHistorySafeFileSnapshot(
                        relativePath: relativePath,
                        data: nil,
                        permissions: nil,
                        device: nil,
                        inode: nil
                    )
                }
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }
            guard let expectedByteCount else {
                return AgentHistorySafeFileSnapshot(
                    relativePath: relativePath,
                    data: Data(),
                    permissions: (pathInfo.st_mode & S_IFMT) == S_IFREG
                        ? UInt16(pathInfo.st_mode & 0o7777)
                        : nil,
                    device: UInt64(pathInfo.st_dev),
                    inode: UInt64(pathInfo.st_ino)
                )
            }
            guard (pathInfo.st_mode & S_IFMT) == S_IFREG,
                  pathInfo.st_nlink == 1 else {
                throw AgentHistorySafeWorkspaceError.notExclusiveRegularFile(relativePath)
            }

            let descriptor = openat(
                parentDescriptor,
                leaf,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }
            defer { close(descriptor) }

            var openedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  (openedInfo.st_mode & S_IFMT) == S_IFREG,
                  openedInfo.st_nlink == 1,
                  openedInfo.st_dev == pathInfo.st_dev,
                  openedInfo.st_ino == pathInfo.st_ino else {
                throw AgentHistorySafeWorkspaceError.pathChanged(relativePath)
            }

            let data = try AgentHistoryBoundedFileReader.readExact(
                descriptor: descriptor,
                expectedByteCount: expectedByteCount
            )
            return AgentHistorySafeFileSnapshot(
                relativePath: relativePath,
                data: data,
                permissions: UInt16(openedInfo.st_mode & 0o7777),
                device: UInt64(openedInfo.st_dev),
                inode: UInt64(openedInfo.st_ino)
            )
        }
    }

    func matchesCurrentState(
        change: AgentHistoryRecordedFileChange
    ) throws -> Bool {
        let current = try snapshot(
            relativePath: change.relativePath,
            expectedByteCount: expectedCurrentByteCount(for: change)
        )
        switch change.operation {
        case .modify, .create:
            guard let after = change.after,
                  let data = current.data,
                  current.permissions == after.permissions,
                  UInt64(data.count) == after.byteCount else {
                return false
            }
            return AgentHistoryContentHash.sha256Hex(data) == after.contentSHA256
        case .delete:
            return !current.exists
        case .rename, .symlink, .unsupported:
            return false
        }
    }

    /// Moves the expected current file to a same-directory quarantine name.
    /// The move itself is atomic. The moved object is then revalidated, closing
    /// the check/use race before any inverse bytes are installed.
    func quarantineExpectedFile(
        change: AgentHistoryRecordedFileChange,
        transactionID: UUID,
        afterRename: (@Sendable () -> Void)? = nil
    ) throws -> AgentHistorySafeMutation {
        try withParent(relativePath: change.relativePath) { parentDescriptor, leaf in
            let quarantine = ".pine-undo-\(transactionID.uuidString)-\(UUID().uuidString)"
            guard renameat(parentDescriptor, leaf, parentDescriptor, quarantine) == 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }

            do {
                guard fsync(parentDescriptor) == 0 else {
                    throw AgentHistorySafeWorkspaceError.posixFailure(errno)
                }
                afterRename?()
                let moved = try snapshotInParent(
                    parentDescriptor: parentDescriptor,
                    leaf: quarantine,
                    relativePath: change.relativePath,
                    expectedByteCount: change.after?.byteCount
                )
                guard snapshot(moved, matches: change.after) else {
                    try restoreQuarantine(
                        parentDescriptor: parentDescriptor,
                        quarantine: quarantine,
                        leaf: leaf
                    )
                    throw AgentHistorySafeWorkspaceError.pathChanged(change.relativePath)
                }
                return AgentHistorySafeMutation(
                    transactionID: transactionID,
                    kind: change.operation == .create ? .removed : .replaced,
                    relativePath: change.relativePath,
                    quarantineName: quarantine,
                    quarantinedDevice: moved.device,
                    quarantinedInode: moved.inode,
                    quarantinedContentSHA256: moved.data.map(
                        AgentHistoryContentHash.sha256Hex
                    ),
                    quarantinedByteCount: moved.data.map { UInt64($0.count) },
                    quarantinedPermissions: moved.permissions,
                    installedDevice: nil,
                    installedInode: nil,
                    installedContentSHA256: nil,
                    installedByteCount: nil,
                    installedPermissions: nil
                )
            } catch {
                // If validation itself failed, restore without replacing a path
                // concurrently created by another actor.
                if pathExists(parentDescriptor: parentDescriptor, leaf: quarantine) {
                    _ = restoreOrRecord(
                        parentDescriptor: parentDescriptor,
                        quarantine: quarantine,
                        leaf: leaf,
                        relativePath: change.relativePath
                    )
                }
                throw error
            }
        }
    }

    /// Installs bytes only when the destination is still absent. The data is
    /// fully written and fsynced under an unguessable temporary name first.
    func installExclusive(
        relativePath: String,
        data: Data,
        permissions: UInt16,
        installation: AgentHistorySafeInstallation
    ) throws -> AgentHistorySafeMutation {
        try withParent(relativePath: relativePath) { parentDescriptor, leaf in
            let temporary = ".pine-undo-new-\(installation.transactionID.uuidString)-\(UUID().uuidString)"
            let descriptor = openat(
                parentDescriptor,
                temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(permissions)
            )
            guard descriptor >= 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }
            var installed = false
            defer {
                close(descriptor)
                if !installed {
                    unlinkat(parentDescriptor, temporary, 0)
                }
            }

            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, mode_t(permissions)) == 0,
                  fsync(descriptor) == 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }
            var installedInfo = stat()
            guard fstat(descriptor, &installedInfo) == 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }
            guard renameatx_np(
                parentDescriptor,
                temporary,
                parentDescriptor,
                leaf,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw AgentHistorySafeWorkspaceError.destinationAppeared(relativePath)
            }
            installed = true
            guard fsync(parentDescriptor) == 0 else {
                throw AgentHistorySafeWorkspaceError.posixFailure(errno)
            }

            return AgentHistorySafeMutation(
                transactionID: installation.transactionID,
                kind: installation.kind,
                relativePath: relativePath,
                quarantineName: installation.quarantine?.quarantineName,
                quarantinedDevice: installation.quarantine?.quarantinedDevice,
                quarantinedInode: installation.quarantine?.quarantinedInode,
                quarantinedContentSHA256:
                    installation.quarantine?.quarantinedContentSHA256,
                quarantinedByteCount:
                    installation.quarantine?.quarantinedByteCount,
                quarantinedPermissions:
                    installation.quarantine?.quarantinedPermissions,
                installedDevice: UInt64(installedInfo.st_dev),
                installedInode: UInt64(installedInfo.st_ino),
                installedContentSHA256: AgentHistoryContentHash.sha256Hex(data),
                installedByteCount: UInt64(data.count),
                installedPermissions: permissions
            )
        }
    }

    /// Revalidates a just-installed inverse before the transaction advances.
    /// Keeping the mutation in the caller's rollback list before this check
    /// ensures even a last-moment path swap has a recoverable failure path.
    func matchesInstalledState(_ mutation: AgentHistorySafeMutation) -> Bool {
        (try? withParent(relativePath: mutation.relativePath) { parentDescriptor, leaf in
            installedPathMatches(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                mutation: mutation
            )
        }) ?? false
    }

    /// Rolls back one completed mutation without overwriting a concurrently
    /// created replacement. Returns false when manual recovery from the durable
    /// backup/quarantine is required.
    func rollback(
        _ mutation: AgentHistorySafeMutation,
        recoveryBackup: AgentHistoryRecoveryBackup,
        afterInstalledValidation: (@Sendable () -> Void)? = nil
    ) -> AgentHistorySafeRollbackResult {
        (try? withParent(relativePath: mutation.relativePath) { parentDescriptor, leaf in
            switch mutation.kind {
            case .created:
                guard let rollbackQuarantine = try quarantineInstalledFileIfUnchanged(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    mutation: mutation
                ) else { return .failed }
                afterInstalledValidation?()
                return rollbackRetentionResult(
                    retainRollbackQuarantine(
                        parentDescriptor: parentDescriptor,
                        quarantine: rollbackQuarantine,
                        mutation: mutation,
                        recoveryBackup: recoveryBackup
                    )
                )
            case .replaced:
                guard let rollbackQuarantine = try quarantineInstalledFileIfUnchanged(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    mutation: mutation
                ) else {
                    return .failed
                }
                afterInstalledValidation?()
                guard let originalStage = try stageExpectedQuarantine(
                    parentDescriptor: parentDescriptor,
                    mutation: mutation
                ) else {
                    _ = restoreOrRecord(
                        parentDescriptor: parentDescriptor,
                        quarantine: rollbackQuarantine,
                        leaf: leaf,
                        relativePath: mutation.relativePath
                    )
                    return AgentHistorySafeRollbackResult(
                        succeeded: false,
                        retainedPaths: existingRecoveryPaths(
                            parentDescriptor: parentDescriptor,
                            relativePath: mutation.relativePath,
                            names: [rollbackQuarantine]
                        )
                    )
                }
                do {
                    try restoreQuarantine(
                        parentDescriptor: parentDescriptor,
                        quarantine: originalStage,
                        leaf: leaf
                    )
                    return rollbackRetentionResult(
                        retainRollbackQuarantine(
                            parentDescriptor: parentDescriptor,
                            quarantine: rollbackQuarantine,
                            mutation: mutation,
                            recoveryBackup: recoveryBackup
                        )
                    )
                } catch {
                    if let quarantineName = mutation.quarantineName {
                        _ = restoreOrRecord(
                            parentDescriptor: parentDescriptor,
                            quarantine: originalStage,
                            leaf: quarantineName,
                            relativePath: mutation.relativePath
                        )
                    }
                    _ = restoreOrRecord(
                        parentDescriptor: parentDescriptor,
                        quarantine: rollbackQuarantine,
                        leaf: leaf,
                        relativePath: mutation.relativePath
                    )
                    return AgentHistorySafeRollbackResult(
                        succeeded: false,
                        retainedPaths: existingRecoveryPaths(
                            parentDescriptor: parentDescriptor,
                            relativePath: mutation.relativePath,
                            names: [originalStage, rollbackQuarantine]
                        )
                    )
                }
            case .removed:
                guard let originalStage = try stageExpectedQuarantine(
                    parentDescriptor: parentDescriptor,
                    mutation: mutation
                ) else { return .failed }
                do {
                    try restoreQuarantine(
                        parentDescriptor: parentDescriptor,
                        quarantine: originalStage,
                        leaf: leaf
                    )
                } catch {
                    if let quarantineName = mutation.quarantineName {
                        _ = restoreOrRecord(
                            parentDescriptor: parentDescriptor,
                            quarantine: originalStage,
                            leaf: quarantineName,
                            relativePath: mutation.relativePath
                        )
                    }
                    return AgentHistorySafeRollbackResult(
                        succeeded: false,
                        retainedPaths: existingRecoveryPaths(
                            parentDescriptor: parentDescriptor,
                            relativePath: mutation.relativePath,
                            names: [originalStage]
                        )
                    )
                }
                return AgentHistorySafeRollbackResult(
                    succeeded: true,
                    retainedPaths: []
                )
            }
        }) ?? .failed
    }

    /// Finalizes one inverse mutation. Original inodes are moved to a retained
    /// recovery name at the workspace root instead of being unlinked: a writer
    /// that still holds the old descriptor can therefore never lose a late
    /// concurrent write. Retained files are surfaced through the private
    /// recovery manifest and can be cleaned up explicitly after review.
    func commit(
        _ mutation: AgentHistorySafeMutation,
        recoveryBackup: AgentHistoryRecoveryBackup,
        afterQuarantineValidation: (@Sendable () -> Void)? = nil
    ) -> AgentHistorySafeCommitResult {
        let result = try? withParent(
            relativePath: mutation.relativePath
        ) { parentDescriptor, _ in
            guard let quarantineName = mutation.quarantineName else {
                return AgentHistorySafeCommitResult.complete
            }
            guard let staged = try stageExpectedQuarantine(
                parentDescriptor: parentDescriptor,
                mutation: mutation,
                retainChangedContent: true
            ) else {
                return .failed(
                    retainedQuarantinePath(
                        relativePath: mutation.relativePath,
                        quarantineName: quarantineName
                    )
                )
            }

            afterQuarantineValidation?()
            switch recoveryBackup.retainWorkspaceFile(
                sourceDirectory: parentDescriptor,
                sourceName: staged,
                expectation: AgentHistoryRetainedFileExpectation(
                    device: mutation.quarantinedDevice,
                    inode: mutation.quarantinedInode,
                    contentSHA256: mutation.quarantinedContentSHA256,
                    byteCount: mutation.quarantinedByteCount,
                    permissions: mutation.quarantinedPermissions
                )
            ) {
            case .retained(let path):
                return .retained(path)
            case .failed(let path?):
                return .failed(path)
            case .failed(nil):
                let restored = restoreOrRecord(
                    parentDescriptor: parentDescriptor,
                    quarantine: staged,
                    leaf: quarantineName,
                    relativePath: mutation.relativePath
                )
                return .failed(
                    retainedQuarantinePath(
                        relativePath: mutation.relativePath,
                        quarantineName: restored ? quarantineName : staged
                    )
                )
            }
        }
        return result ?? .failed(retainedQuarantinePath(for: mutation))
    }

    /// Returns the workspace-relative location of a quarantine that remains
    /// after cleanup was refused. The path is surfaced in the owner-private
    /// recovery metadata so a concurrent old-descriptor write is never hidden
    /// behind a generic backup directory.
    func retainedQuarantinePath(
        for mutation: AgentHistorySafeMutation
    ) -> String? {
        guard let quarantineName = mutation.quarantineName else { return nil }
        return (try? withParent(
            relativePath: mutation.relativePath
        ) { parentDescriptor, _ in
            var info = stat()
            guard fstatat(
                parentDescriptor,
                quarantineName,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return nil
            }
            let components = mutation.relativePath.split(separator: "/")
            return retainedQuarantinePath(
                relativePath: components.joined(separator: "/"),
                quarantineName: quarantineName
            )
        }) ?? nil
    }

    /// Every quarantine that could not be restored is registered before its
    /// originating helper throws. This closes the recovery gap where no
    /// `AgentHistorySafeMutation` reached the engine, yet late bytes written
    /// through an old descriptor remain under a hidden transient name.
    func unresolvedRecoveryPaths() -> [String] {
        let artifacts = recoveryArtifactsLock.withLock { recoveryArtifacts }
        var seen = Set<String>()
        return artifacts.compactMap { artifact in
            let path = (try? withParent(
                relativePath: artifact.relativePath
            ) { parentDescriptor, _ -> String? in
                guard pathExists(
                    parentDescriptor: parentDescriptor,
                    leaf: artifact.leaf
                ) else {
                    return nil
                }
                return retainedQuarantinePath(
                    relativePath: artifact.relativePath,
                    quarantineName: artifact.leaf
                )
            }) ?? nil
            guard let path, seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private func retainedQuarantinePath(
        relativePath: String,
        quarantineName: String
    ) -> String {
        let components = relativePath.split(separator: "/")
        let parent = components.dropLast().joined(separator: "/")
        return parent.isEmpty
            ? quarantineName
            : "\(parent)/\(quarantineName)"
    }

    private func rollbackRetentionResult(
        _ result: AgentHistorySafeCommitResult
    ) -> AgentHistorySafeRollbackResult {
        switch result {
        case .complete:
            return AgentHistorySafeRollbackResult(
                succeeded: true,
                retainedPaths: []
            )
        case .retained(let path):
            return AgentHistorySafeRollbackResult(
                succeeded: true,
                retainedPaths: [path]
            )
        case .failed(let path):
            return AgentHistorySafeRollbackResult(
                succeeded: false,
                retainedPaths: path.map { [$0] } ?? []
            )
        }
    }

    /// Retains an inverse inode removed during rollback. It must not be
    /// unlinked after validation: another process may still hold a writable
    /// descriptor and append human work in that final check/use window.
    private func retainRollbackQuarantine(
        parentDescriptor: Int32,
        quarantine: String,
        mutation: AgentHistorySafeMutation,
        recoveryBackup: AgentHistoryRecoveryBackup
    ) -> AgentHistorySafeCommitResult {
        let fallback = retainedQuarantinePath(
            relativePath: mutation.relativePath,
            quarantineName: quarantine
        )
        switch recoveryBackup.retainWorkspaceFile(
            sourceDirectory: parentDescriptor,
            sourceName: quarantine,
            expectation: AgentHistoryRetainedFileExpectation(
                device: mutation.installedDevice,
                inode: mutation.installedInode,
                contentSHA256: mutation.installedContentSHA256,
                byteCount: mutation.installedByteCount,
                permissions: mutation.installedPermissions
            )
        ) {
        case .retained(let path):
            return .retained(path)
        case .failed(let path?):
            return .failed(path)
        case .failed(nil):
            return .failed(fallback)
        }
    }

    private func existingRecoveryPaths(
        parentDescriptor: Int32,
        relativePath: String,
        names: [String]
    ) -> [String] {
        names.compactMap { name in
            guard pathExists(
                parentDescriptor: parentDescriptor,
                leaf: name
            ) else {
                return nil
            }
            return retainedQuarantinePath(
                relativePath: relativePath,
                quarantineName: name
            )
        }
    }

    @discardableResult
    private func restoreOrRecord(
        parentDescriptor: Int32,
        quarantine: String,
        leaf: String,
        relativePath: String
    ) -> Bool {
        do {
            try restoreQuarantine(
                parentDescriptor: parentDescriptor,
                quarantine: quarantine,
                leaf: leaf
            )
            return true
        } catch {
            if pathExists(
                parentDescriptor: parentDescriptor,
                leaf: quarantine
            ) {
                recoveryArtifactsLock.withLock {
                    let artifact = RecoveryArtifact(
                        relativePath: relativePath,
                        leaf: quarantine
                    )
                    if !recoveryArtifacts.contains(artifact) {
                        recoveryArtifacts.append(artifact)
                    }
                }
            }
            return false
        }
    }

    // MARK: - Descriptor helpers

    private func withParent<Result>(
        relativePath: String,
        _ body: (Int32, String) throws -> Result
    ) throws -> Result {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentHistorySafeWorkspaceError.invalidRelativePath(relativePath)
        }

        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw AgentHistorySafeWorkspaceError.posixFailure(errno)
        }
        defer { close(current) }

        guard isStillBoundToCanonicalPath() else {
            throw AgentHistorySafeWorkspaceError.rootIdentityChanged
        }
        for component in components.dropLast() {
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else {
                throw AgentHistorySafeWorkspaceError.unsafeAncestor(relativePath)
            }
            close(current)
            current = next
        }
        let expectedParent = components.dropLast().reduce(canonicalRoot) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL.path
        guard descriptorMatchesPath(current, path: expectedParent) else {
            throw AgentHistorySafeWorkspaceError.unsafeAncestor(relativePath)
        }
        return try body(current, components[components.count - 1])
    }

    private func descriptorMatchesPath(
        _ descriptor: Int32,
        path: String
    ) -> Bool {
        let reopened = open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard reopened >= 0 else { return false }
        defer { close(reopened) }
        var openedInfo = stat()
        var pathInfo = stat()
        return fstat(descriptor, &openedInfo) == 0
            && fstat(reopened, &pathInfo) == 0
            && openedInfo.st_dev == pathInfo.st_dev
            && openedInfo.st_ino == pathInfo.st_ino
    }

    private func snapshotInParent(
        parentDescriptor: Int32,
        leaf: String,
        relativePath: String,
        expectedByteCount: UInt64?
    ) throws -> AgentHistorySafeFileSnapshot {
        let descriptor = openat(
            parentDescriptor,
            leaf,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentHistorySafeWorkspaceError.posixFailure(errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            throw AgentHistorySafeWorkspaceError.notExclusiveRegularFile(relativePath)
        }
        guard let expectedByteCount else {
            throw AgentHistorySafeWorkspaceError.pathChanged(relativePath)
        }
        let data = try AgentHistoryBoundedFileReader.readExact(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        )
        return AgentHistorySafeFileSnapshot(
            relativePath: relativePath,
            data: data,
            permissions: UInt16(info.st_mode & 0o7777),
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private func snapshot(
        _ snapshot: AgentHistorySafeFileSnapshot,
        matches expected: AgentHistoryRecordedFileState?
    ) -> Bool {
        guard let expected,
              let data = snapshot.data,
              snapshot.permissions == expected.permissions,
              UInt64(data.count) == expected.byteCount else {
            return false
        }
        return AgentHistoryContentHash.sha256Hex(data) == expected.contentSHA256
    }

    private func restoreQuarantine(
        parentDescriptor: Int32,
        quarantine: String,
        leaf: String
    ) throws {
        guard renameatx_np(
            parentDescriptor,
            quarantine,
            parentDescriptor,
            leaf,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw AgentHistorySafeWorkspaceError.destinationAppeared(leaf)
        }
        guard fsync(parentDescriptor) == 0 else {
            throw AgentHistorySafeWorkspaceError.posixFailure(errno)
        }
    }

    private func pathExists(parentDescriptor: Int32, leaf: String) -> Bool {
        var info = stat()
        return fstatat(parentDescriptor, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private func quarantineInstalledFileIfUnchanged(
        parentDescriptor: Int32,
        leaf: String,
        mutation: AgentHistorySafeMutation
    ) throws -> String? {
        let rollbackQuarantine = ".pine-undo-rollback-"
            + "\(mutation.transactionID.uuidString)-\(UUID().uuidString)"
        guard renameat(
            parentDescriptor,
            leaf,
            parentDescriptor,
            rollbackQuarantine
        ) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AgentHistorySafeWorkspaceError.posixFailure(errno)
        }
        guard fsync(parentDescriptor) == 0 else {
            let syncError = errno
            _ = restoreOrRecord(
                parentDescriptor: parentDescriptor,
                quarantine: rollbackQuarantine,
                leaf: leaf,
                relativePath: mutation.relativePath
            )
            throw AgentHistorySafeWorkspaceError.posixFailure(syncError)
        }
        do {
            let snapshot = try snapshotInParent(
                parentDescriptor: parentDescriptor,
                leaf: rollbackQuarantine,
                relativePath: mutation.relativePath,
                expectedByteCount: mutation.installedByteCount
            )
            guard snapshotMatchesInstalled(snapshot, mutation: mutation) else {
                try restoreQuarantine(
                    parentDescriptor: parentDescriptor,
                    quarantine: rollbackQuarantine,
                    leaf: leaf
                )
                return nil
            }
            return rollbackQuarantine
        } catch {
            if pathExists(
                parentDescriptor: parentDescriptor,
                leaf: rollbackQuarantine
            ) {
                _ = restoreOrRecord(
                    parentDescriptor: parentDescriptor,
                    quarantine: rollbackQuarantine,
                    leaf: leaf,
                    relativePath: mutation.relativePath
                )
            }
            throw error
        }
    }

    /// Moves the original after-state quarantine to a fresh unguessable name,
    /// then validates its complete identity before it may be restored/deleted.
    /// An old open file descriptor can mutate the quarantined inode after the
    /// initial apply check; this closes that rollback corruption path.
    private func stageExpectedQuarantine(
        parentDescriptor: Int32,
        mutation: AgentHistorySafeMutation,
        retainChangedContent: Bool = false
    ) throws -> String? {
        guard let quarantineName = mutation.quarantineName else { return nil }
        let staged = ".pine-undo-original-"
            + "\(mutation.transactionID.uuidString)-\(UUID().uuidString)"
        guard renameat(
            parentDescriptor,
            quarantineName,
            parentDescriptor,
            staged
        ) == 0 else {
            return nil
        }
        guard fsync(parentDescriptor) == 0 else {
            let syncError = errno
            _ = restoreOrRecord(
                parentDescriptor: parentDescriptor,
                quarantine: staged,
                leaf: quarantineName,
                relativePath: mutation.relativePath
            )
            throw AgentHistorySafeWorkspaceError.posixFailure(syncError)
        }
        do {
            let snapshot = try snapshotInParent(
                parentDescriptor: parentDescriptor,
                leaf: staged,
                relativePath: mutation.relativePath,
                expectedByteCount: mutation.quarantinedByteCount
            )
            guard snapshotMatchesQuarantined(snapshot, mutation: mutation) else {
                if retainChangedContent {
                    return staged
                }
                try restoreQuarantine(
                    parentDescriptor: parentDescriptor,
                    quarantine: staged,
                    leaf: quarantineName
                )
                return nil
            }
            return staged
        } catch {
            if retainChangedContent {
                // Commit must preserve an inode that no longer matches the
                // recorded size/hash (including an oversized late append).
                // Returning the staged name lets owner-private retention move
                // it without ever reading beyond the recorded byte ceiling.
                return staged
            }
            var restored = true
            if pathExists(parentDescriptor: parentDescriptor, leaf: staged) {
                restored = restoreOrRecord(
                    parentDescriptor: parentDescriptor,
                    quarantine: staged,
                    leaf: quarantineName,
                    relativePath: mutation.relativePath
                )
            }
            if let readError = error as? AgentHistoryBoundedFileReadError,
               case .byteCountMismatch = readError,
               restored {
                // A size drift is the bounded-reader equivalent of a digest
                // mismatch. Report it as an expected-content mismatch so the
                // caller can safely put the installed inverse back.
                return nil
            }
            throw error
        }
    }

    private func installedPathMatches(
        parentDescriptor: Int32,
        leaf: String,
        mutation: AgentHistorySafeMutation
    ) -> Bool {
        guard let snapshot = try? snapshotInParent(
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            relativePath: mutation.relativePath,
            expectedByteCount: mutation.installedByteCount
        ) else {
            return false
        }
        return snapshotMatchesInstalled(snapshot, mutation: mutation)
    }

    private func snapshotMatchesInstalled(
        _ snapshot: AgentHistorySafeFileSnapshot,
        mutation: AgentHistorySafeMutation
    ) -> Bool {
        guard let data = snapshot.data,
              snapshot.device == mutation.installedDevice,
              snapshot.inode == mutation.installedInode,
              snapshot.permissions == mutation.installedPermissions,
              UInt64(data.count) == mutation.installedByteCount,
              AgentHistoryContentHash.sha256Hex(data)
                == mutation.installedContentSHA256 else {
            return false
        }
        return true
    }

    private func snapshotMatchesQuarantined(
        _ snapshot: AgentHistorySafeFileSnapshot,
        mutation: AgentHistorySafeMutation
    ) -> Bool {
        guard let data = snapshot.data,
              snapshot.device == mutation.quarantinedDevice,
              snapshot.inode == mutation.quarantinedInode,
              snapshot.permissions == mutation.quarantinedPermissions,
              UInt64(data.count) == mutation.quarantinedByteCount,
              AgentHistoryContentHash.sha256Hex(data)
                == mutation.quarantinedContentSHA256 else {
            return false
        }
        return true
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw AgentHistorySafeWorkspaceError.posixFailure(errno)
                }
                offset += count
            }
        }
    }

    private func expectedCurrentByteCount(
        for change: AgentHistoryRecordedFileChange
    ) -> UInt64? {
        switch change.operation {
        case .modify, .create:
            change.after?.byteCount
        case .delete, .rename, .symlink, .unsupported:
            nil
        }
    }
}

nonisolated enum AgentHistorySafeWorkspaceError: Error, Equatable {
    case invalidRoot
    case rootIdentityChanged
    case invalidRelativePath(String)
    case unsafeAncestor(String)
    case notExclusiveRegularFile(String)
    case pathChanged(String)
    case destinationAppeared(String)
    case posixFailure(Int32)
}
