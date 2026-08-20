//
//  ProjectRegistry.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import Darwin
import os
import SwiftUI

nonisolated struct RecentAgentTaskFilesystemObjectProof:
    Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let kind: UInt16
}

nonisolated struct RecentAgentTaskRepositoryProof:
    Codable, Equatable, Sendable {
    let commonDirectoryDevice: UInt64
    let commonDirectoryInode: UInt64
    let commonDirectoryGeneration: UInt64
    let commonDirectoryBirthSeconds: Int64
    let commonDirectoryBirthNanoseconds: Int64
    /// Exact linked-worktree instance. Older records decode these as nil and
    /// therefore fail closed for every distinct project/worktree admission.
    let projectRoot: RecentAgentTaskFilesystemObjectProof?
    let projectGitDirectory: RecentAgentTaskFilesystemObjectProof?
    let worktreeRoot: RecentAgentTaskFilesystemObjectProof?
    let worktreeGitDirectory: RecentAgentTaskFilesystemObjectProof?

    init(
        commonDirectoryDevice: UInt64,
        commonDirectoryInode: UInt64,
        commonDirectoryGeneration: UInt64,
        commonDirectoryBirthSeconds: Int64,
        commonDirectoryBirthNanoseconds: Int64,
        projectRoot: RecentAgentTaskFilesystemObjectProof? = nil,
        projectGitDirectory: RecentAgentTaskFilesystemObjectProof? = nil,
        worktreeRoot: RecentAgentTaskFilesystemObjectProof? = nil,
        worktreeGitDirectory: RecentAgentTaskFilesystemObjectProof? = nil
    ) {
        self.commonDirectoryDevice = commonDirectoryDevice
        self.commonDirectoryInode = commonDirectoryInode
        self.commonDirectoryGeneration = commonDirectoryGeneration
        self.commonDirectoryBirthSeconds = commonDirectoryBirthSeconds
        self.commonDirectoryBirthNanoseconds = commonDirectoryBirthNanoseconds
        self.projectRoot = projectRoot
        self.projectGitDirectory = projectGitDirectory
        self.worktreeRoot = worktreeRoot
        self.worktreeGitDirectory = worktreeGitDirectory
    }

    var hasExactWorktreeInstance: Bool {
        projectRoot != nil
            && projectGitDirectory != nil
            && worktreeRoot != nil
            && worktreeGitDirectory != nil
    }

    func identifiesSameRepository(
        as other: RecentAgentTaskRepositoryProof
    ) -> Bool {
        commonDirectoryDevice == other.commonDirectoryDevice
            && commonDirectoryInode == other.commonDirectoryInode
            && commonDirectoryGeneration == other.commonDirectoryGeneration
            && commonDirectoryBirthSeconds
                == other.commonDirectoryBirthSeconds
            && commonDirectoryBirthNanoseconds
                == other.commonDirectoryBirthNanoseconds
    }
}

nonisolated private struct RecentAgentTaskProjectRecord:
    Codable, Equatable, Sendable {
    let identity: AgentTaskProjectIdentity
    let repositoryProof: RecentAgentTaskRepositoryProof?
}

nonisolated private func unsignedFilesystemIdentity<Identity>(
    _ identity: Identity
) -> UInt64 where Identity: FixedWidthInteger {
    // Darwin's `dev_t` is signed on supported SDKs. A value with its high bit
    // set must preserve that kernel bit pattern rather than trap in UInt64's
    // checked signed conversion. This also leaves unsigned `ino_t` unchanged.
    UInt64(truncatingIfNeeded: identity)
}

nonisolated private struct StableFilesystemObjectIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let kind: UInt16

    init(_ information: stat) {
        device = unsignedFilesystemIdentity(information.st_dev)
        inode = unsignedFilesystemIdentity(information.st_ino)
        generation = unsignedFilesystemIdentity(information.st_gen)
        birthSeconds = Int64(information.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(information.st_birthtimespec.tv_nsec)
        kind = information.st_mode & S_IFMT
    }

    init(
        device: UInt64,
        inode: UInt64,
        generation: UInt64,
        birthSeconds: Int64,
        birthNanoseconds: Int64,
        kind: UInt16
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
        self.kind = kind
    }

    var persistedProof: RecentAgentTaskFilesystemObjectProof {
        RecentAgentTaskFilesystemObjectProof(
            device: device,
            inode: inode,
            generation: generation,
            birthSeconds: birthSeconds,
            birthNanoseconds: birthNanoseconds,
            kind: kind
        )
    }
}

/// A descriptor-held path witness. Keeping the descriptor alive prevents the
/// validated object from disappearing while every graph edge is rechecked;
/// comparing its captured identity with both `fstat` and the current path
/// rejects atomic path replacement without doing filesystem I/O on MainActor.
nonisolated private final class StablePathDescriptor: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    let information: stat
    let kind: UInt16
    private let parent: StablePathDescriptor?
    private let entryName: String?

    init?(url: URL, kind: UInt16) {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            | (kind == S_IFDIR ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else { return nil }
        var information = stat()
        var currentPath = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == kind,
              lstat(url.path, &currentPath) == 0,
              RecentAgentTaskFilesystemValidator.stableIdentityMatches(
                  information,
                  currentPath,
                  kind: kind
              ) else {
            Darwin.close(descriptor)
            return nil
        }
        self.url = url
        self.descriptor = descriptor
        self.information = information
        self.kind = kind
        parent = nil
        entryName = nil
    }

    init?(
        parent: StablePathDescriptor,
        entryName: String,
        url: URL,
        kind: UInt16
    ) {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            | (kind == S_IFDIR ? O_DIRECTORY : 0)
        let descriptor = entryName.withCString {
            Darwin.openat(parent.descriptor, $0, flags)
        }
        guard descriptor >= 0 else { return nil }
        var information = stat()
        var currentEntry = stat()
        let entryResult = entryName.withCString {
            Darwin.fstatat(
                parent.descriptor,
                $0,
                &currentEntry,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &information) == 0,
              entryResult == 0,
              RecentAgentTaskFilesystemValidator.stableIdentityMatches(
                  information,
                  currentEntry,
                  kind: kind
              ) else {
            Darwin.close(descriptor)
            return nil
        }
        self.url = url
        self.descriptor = descriptor
        self.information = information
        self.kind = kind
        self.parent = parent
        self.entryName = entryName
    }

    deinit {
        Darwin.close(descriptor)
    }

    func revalidate() -> Bool {
        var descriptorState = stat()
        var pathState = stat()
        let pathResult: Int32
        if let parent, let entryName {
            pathResult = entryName.withCString {
                Darwin.fstatat(
                    parent.descriptor,
                    $0,
                    &pathState,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        } else {
            pathResult = lstat(url.path, &pathState)
        }
        guard fstat(descriptor, &descriptorState) == 0,
              pathResult == 0,
              RecentAgentTaskFilesystemValidator.stableIdentityMatches(
                  information,
                  descriptorState,
                  kind: kind
              ),
              RecentAgentTaskFilesystemValidator.stableIdentityMatches(
                  descriptorState,
                  pathState,
                  kind: kind
              ) else { return false }
        if kind == S_IFREG {
            return RecentAgentTaskFilesystemValidator
                .stableFileMetadataMatches(information, descriptorState)
        }
        return true
    }
}

/// Binds an intermediate symbolic-link edge to both its filesystem identity
/// and exact target text. The target is resolved explicitly by the descriptor
/// walker; no later open is allowed to follow an unrecorded link implicitly.
nonisolated private final class StableSymlinkWitness: @unchecked Sendable {
    let parent: StablePathDescriptor
    let entryName: String
    let information: stat
    let target: String

    init?(parent: StablePathDescriptor, entryName: String) {
        guard let snapshot = Self.snapshot(
            parent: parent,
            entryName: entryName
        ) else { return nil }
        self.parent = parent
        self.entryName = entryName
        information = snapshot.information
        target = snapshot.target
    }

    func revalidate() -> Bool {
        guard let current = Self.snapshot(
            parent: parent,
            entryName: entryName
        ) else { return false }
        return RecentAgentTaskFilesystemValidator.stableIdentityMatches(
            information,
            current.information,
            kind: S_IFLNK
        ) && current.target == target
    }

    private static func snapshot(
        parent: StablePathDescriptor,
        entryName: String
    ) -> (information: stat, target: String)? {
        var before = stat()
        let beforeResult = entryName.withCString {
            Darwin.fstatat(
                parent.descriptor,
                $0,
                &before,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard beforeResult == 0,
              (before.st_mode & S_IFMT) == S_IFLNK else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = entryName.withCString { name in
            bytes.withUnsafeMutableBytes { buffer in
                Darwin.readlinkat(
                    parent.descriptor,
                    name,
                    buffer.baseAddress,
                    Int(PATH_MAX)
                )
            }
        }
        guard count > 0, count <= Int(PATH_MAX) else { return nil }
        var after = stat()
        let afterResult = entryName.withCString {
            Darwin.fstatat(
                parent.descriptor,
                $0,
                &after,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard afterResult == 0,
              RecentAgentTaskFilesystemValidator.stableIdentityMatches(
                  before,
                  after,
                  kind: S_IFLNK
              ),
              let target = String(
                  bytes: bytes.prefix(count),
                  encoding: .utf8
              ),
              !target.isEmpty,
              !target.utf8.contains(0) else { return nil }
        return (before, target)
    }
}

/// Records that `commondir` did not exist relative to the exact Git directory
/// descriptor. A creation after graph resolution changes repository meaning
/// and must invalidate the whole lease.
nonisolated private struct MissingDirectoryEntryWitness: @unchecked Sendable {
    let parent: StablePathDescriptor
    let entryName: String

    func revalidate() -> Bool {
        var information = stat()
        let result = entryName.withCString {
            Darwin.fstatat(
                parent.descriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return result == -1 && errno == ENOENT
    }
}

/// Holds every filesystem object and absent edge used to derive one project /
/// worktree relationship. Callers retain this through their final MainActor
/// commit and perform a detached revalidation immediately before mutation.
nonisolated final class RecentAgentTaskFilesystemValidationLease:
    @unchecked Sendable {
    let identity: AgentTaskProjectIdentity
    let proof: RecentAgentTaskRepositoryProof?
    let canonicalWorktree: URL
    private let descriptors: [StablePathDescriptor]
    private let symlinks: [StableSymlinkWitness]
    private let missingEntries: [MissingDirectoryEntryWitness]

    fileprivate init(
        identity: AgentTaskProjectIdentity,
        proof: RecentAgentTaskRepositoryProof?,
        canonicalWorktree: URL,
        descriptors: [StablePathDescriptor],
        symlinks: [StableSymlinkWitness],
        missingEntries: [MissingDirectoryEntryWitness]
    ) {
        self.identity = identity
        self.proof = proof
        self.canonicalWorktree = canonicalWorktree
        self.descriptors = descriptors
        self.symlinks = symlinks
        self.missingEntries = missingEntries
    }

    func revalidate() -> Bool {
        descriptors.allSatisfy { $0.revalidate() }
            && symlinks.allSatisfy { $0.revalidate() }
            && missingEntries.allSatisfy { $0.revalidate() }
    }
}

nonisolated private struct PreparedQuickTerminalAgentScope: @unchecked Sendable {
    let registration: QuickTerminalAgentScopeRegistration
    let sourceRecord: RecentAgentTaskProjectRecord?
    let lease: RecentAgentTaskFilesystemValidationLease
}

/// Immutable filesystem validation used only from detached tasks. It owns no
/// application state and never hops onto the main actor for path, stat, or
/// bounded Git-control-file I/O.
nonisolated enum RecentAgentTaskFilesystemValidator {
    private struct WorkingTreeGraph {
        let workingTreeURL: URL
        let root: StablePathDescriptor
        let gitDirectory: StablePathDescriptor
        let commonDirectory: StablePathDescriptor
        let descriptors: [StablePathDescriptor]
        let symlinks: [StableSymlinkWitness]
        let missingEntries: [MissingDirectoryEntryWitness]
    }

    private struct DirectoryDescriptorWalk {
        let final: StablePathDescriptor
        let descriptors: [StablePathDescriptor]
        let symlinks: [StableSymlinkWitness]
    }

    fileprivate static func preparedRegistration(
        workingDirectory: URL,
        requestedSurface: AgentTaskTerminalSurface,
        record: RecentAgentTaskProjectRecord?
    ) -> PreparedQuickTerminalAgentScope? {
        guard requestedSurface.isQuickTerminal,
              let canonicalWorkingDirectory = canonicalExistingDirectory(
                  workingDirectory
              ),
              let standaloneLease = validationLease(
                  for: AgentTaskProjectIdentity(
                      canonicalProjectPath: canonicalWorkingDirectory.path,
                      canonicalWorktreePath: canonicalWorkingDirectory.path
                  ),
                  expectedProof: nil
              ) else { return nil }
        if requestedSurface == .quickTerminalProject,
           let record,
           record.identity.canonicalWorktreePath
                == canonicalWorkingDirectory.path,
           let projectLease = validationLease(
               for: record.identity,
               expectedProof: record.repositoryProof
           ) {
            return PreparedQuickTerminalAgentScope(
                registration: QuickTerminalAgentScopeRegistration(
                    project: record.identity,
                    surface: .quickTerminalProject
                ),
                sourceRecord: record,
                lease: projectLease
            )
        }
        return PreparedQuickTerminalAgentScope(
            registration: QuickTerminalAgentScopeRegistration(
                project: standaloneLease.identity,
                surface: .quickTerminalStandalone
            ),
            sourceRecord: record,
            lease: standaloneLease
        )
    }

    fileprivate static func validationLease(
        for identity: AgentTaskProjectIdentity,
        expectedProof: RecentAgentTaskRepositoryProof?
    ) -> RecentAgentTaskFilesystemValidationLease? {
        let projectURL = URL(
            fileURLWithPath: identity.canonicalProjectPath,
            isDirectory: true
        ).standardizedFileURL
        let worktreeURL = URL(
            fileURLWithPath: identity.canonicalWorktreePath,
            isDirectory: true
        ).standardizedFileURL
        guard projectURL.path == identity.canonicalProjectPath,
              worktreeURL.path == identity.canonicalWorktreePath else {
            return nil
        }

        if projectURL == worktreeURL {
            guard expectedProof == nil,
                  let root = canonicalDirectoryDescriptor(projectURL) else {
                return nil
            }
            let lease = RecentAgentTaskFilesystemValidationLease(
                identity: identity,
                proof: nil,
                canonicalWorktree: worktreeURL,
                descriptors: [root],
                symlinks: [],
                missingEntries: []
            )
            return lease.revalidate() ? lease : nil
        }

        guard let expectedProof,
              let project = workingTreeGraph(projectURL),
              let worktree = workingTreeGraph(worktreeURL),
              project.workingTreeURL == projectURL,
              worktree.workingTreeURL == worktreeURL,
              project.commonDirectory.url.path
                == worktree.commonDirectory.url.path,
              StableFilesystemObjectIdentity(
                  project.commonDirectory.information
              ) == StableFilesystemObjectIdentity(
                  worktree.commonDirectory.information
              ) else { return nil }
        let proof = repositoryProof(
            project: project,
            worktree: worktree
        )
        guard expectedProof.hasExactWorktreeInstance,
              proof == expectedProof else { return nil }
        let lease = RecentAgentTaskFilesystemValidationLease(
            identity: identity,
            proof: proof,
            canonicalWorktree: worktreeURL,
            descriptors: project.descriptors + worktree.descriptors,
            symlinks: project.symlinks + worktree.symlinks,
            missingEntries: project.missingEntries
                + worktree.missingEntries
        )
        return lease.revalidate() ? lease : nil
    }

    static func repositoryProof(
        for identity: AgentTaskProjectIdentity,
        afterGraphResolution: (() -> Void)? = nil
    ) -> RecentAgentTaskRepositoryProof? {
        guard identity.canonicalProjectPath
                != identity.canonicalWorktreePath,
              let project = workingTreeGraph(URL(
                  fileURLWithPath: identity.canonicalProjectPath,
                  isDirectory: true
              )),
              let worktree = workingTreeGraph(URL(
                  fileURLWithPath: identity.canonicalWorktreePath,
                  isDirectory: true
              )),
              project.workingTreeURL.path
                == identity.canonicalProjectPath,
              worktree.workingTreeURL.path
                == identity.canonicalWorktreePath,
              project.commonDirectory.url.path
                == worktree.commonDirectory.url.path,
              StableFilesystemObjectIdentity(
                  project.commonDirectory.information
              ) == StableFilesystemObjectIdentity(
                  worktree.commonDirectory.information
              ) else { return nil }
        let proof = repositoryProof(
            project: project,
            worktree: worktree
        )
        let lease = RecentAgentTaskFilesystemValidationLease(
            identity: identity,
            proof: proof,
            canonicalWorktree: worktree.workingTreeURL,
            descriptors: project.descriptors + worktree.descriptors,
            symlinks: project.symlinks + worktree.symlinks,
            missingEntries: project.missingEntries
                + worktree.missingEntries
        )
        afterGraphResolution?()
        return lease.revalidate() ? proof : nil
    }

    /// Captures the repository instance before a managed worktree mutation.
    /// The worktree service compares this token with the linked worktree's
    /// common-directory token after creation, so a path replacement at any
    /// suspension boundary fails closed instead of changing logical owner.
    static func repositoryProof(
        forRepository repository: URL
    ) -> RecentAgentTaskRepositoryProof? {
        guard let graph = workingTreeGraph(repository),
              graph.workingTreeURL.path == repository.path else { return nil }
        let proof = repositoryProof(commonDirectory: graph.commonDirectory)
        let lease = RecentAgentTaskFilesystemValidationLease(
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: graph.workingTreeURL.path,
                canonicalWorktreePath: graph.workingTreeURL.path
            ),
            proof: proof,
            canonicalWorktree: graph.workingTreeURL,
            descriptors: graph.descriptors,
            symlinks: graph.symlinks,
            missingEntries: graph.missingEntries
        )
        return lease.revalidate() ? proof : nil
    }

    private static func repositoryProof(
        commonDirectory: StablePathDescriptor
    ) -> RecentAgentTaskRepositoryProof {
        let identity = StableFilesystemObjectIdentity(
            commonDirectory.information
        )
        return RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: identity.device,
            commonDirectoryInode: identity.inode,
            commonDirectoryGeneration: identity.generation,
            commonDirectoryBirthSeconds: identity.birthSeconds,
            commonDirectoryBirthNanoseconds: identity.birthNanoseconds
        )
    }

    private static func repositoryProof(
        project: WorkingTreeGraph,
        worktree: WorkingTreeGraph
    ) -> RecentAgentTaskRepositoryProof {
        let common = StableFilesystemObjectIdentity(
            project.commonDirectory.information
        )
        return RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: common.device,
            commonDirectoryInode: common.inode,
            commonDirectoryGeneration: common.generation,
            commonDirectoryBirthSeconds: common.birthSeconds,
            commonDirectoryBirthNanoseconds: common.birthNanoseconds,
            projectRoot: StableFilesystemObjectIdentity(
                project.root.information
            ).persistedProof,
            projectGitDirectory: StableFilesystemObjectIdentity(
                project.gitDirectory.information
            ).persistedProof,
            worktreeRoot: StableFilesystemObjectIdentity(
                worktree.root.information
            ).persistedProof,
            worktreeGitDirectory: StableFilesystemObjectIdentity(
                worktree.gitDirectory.information
            ).persistedProof
        )
    }

    private static func workingTreeGraph(
        _ workingTree: URL
    ) -> WorkingTreeGraph? {
        let workingTreeURL = workingTree.standardizedFileURL
        guard let rootWalk = directoryDescriptorWalk(
            workingTreeURL
        ) else {
            return nil
        }
        let root = rootWalk.final
        var descriptors = rootWalk.descriptors
        var symlinks = rootWalk.symlinks
        var missingEntries: [MissingDirectoryEntryWitness] = []
        let controlPath = workingTreeURL.appendingPathComponent(
            ".git",
            isDirectory: false
        )
        var controlState = stat()
        guard lstat(controlPath.path, &controlState) == 0 else { return nil }

        let gitDirectory: StablePathDescriptor
        switch controlState.st_mode & S_IFMT {
        case S_IFDIR:
            guard let walk = directoryDescriptorWalk(controlPath) else {
                return nil
            }
            gitDirectory = walk.final
            descriptors.append(contentsOf: walk.descriptors)
            symlinks.append(contentsOf: walk.symlinks)
        case S_IFREG:
            guard let control = StablePathDescriptor(
                parent: root,
                entryName: ".git",
                url: controlPath,
                kind: S_IFREG
            ), let contents = boundedGitPathFile(control),
                contents.hasPrefix("gitdir: ") else { return nil }
            descriptors.append(control)
            let path = String(contents.dropFirst("gitdir: ".count))
            guard !path.isEmpty else { return nil }
            let candidate = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : root.url.appendingPathComponent(path, isDirectory: true)
            guard let walk = directoryDescriptorWalk(
                candidate
            ) else { return nil }
            gitDirectory = walk.final
            descriptors.append(contentsOf: walk.descriptors)
            symlinks.append(contentsOf: walk.symlinks)
        default:
            return nil
        }

        var commonControlState = stat()
        let commonControlResult = "commondir".withCString {
            Darwin.fstatat(
                gitDirectory.descriptor,
                $0,
                &commonControlState,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if commonControlResult == -1 {
            guard errno == ENOENT else { return nil }
            missingEntries.append(MissingDirectoryEntryWitness(
                parent: gitDirectory,
                entryName: "commondir"
            ))
            let graph = WorkingTreeGraph(
                workingTreeURL: workingTreeURL,
                root: root,
                gitDirectory: gitDirectory,
                commonDirectory: gitDirectory,
                descriptors: descriptors,
                symlinks: symlinks,
                missingEntries: missingEntries
            )
            return graphIsStable(graph) ? graph : nil
        }

        guard (commonControlState.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let commonControlPath = gitDirectory.url.appendingPathComponent(
            "commondir",
            isDirectory: false
        )
        guard let commonControl = StablePathDescriptor(
            parent: gitDirectory,
            entryName: "commondir",
            url: commonControlPath,
            kind: S_IFREG
        ), let commonPath = boundedGitPathFile(commonControl) else {
            return nil
        }
        descriptors.append(commonControl)
        let candidate = commonPath.hasPrefix("/")
            ? URL(fileURLWithPath: commonPath, isDirectory: true)
            : gitDirectory.url.appendingPathComponent(
                commonPath,
                isDirectory: true
            )
        guard let commonWalk = directoryDescriptorWalk(
            candidate
        ) else { return nil }
        let commonDirectory = commonWalk.final
        descriptors.append(contentsOf: commonWalk.descriptors)
        symlinks.append(contentsOf: commonWalk.symlinks)
        let graph = WorkingTreeGraph(
            workingTreeURL: workingTreeURL,
            root: root,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            descriptors: descriptors,
            symlinks: symlinks,
            missingEntries: missingEntries
        )
        return graphIsStable(graph) ? graph : nil
    }

    private static func graphIsStable(_ graph: WorkingTreeGraph) -> Bool {
        graph.descriptors.allSatisfy { $0.revalidate() }
            && graph.symlinks.allSatisfy { $0.revalidate() }
            && graph.missingEntries.allSatisfy { $0.revalidate() }
    }

    private static func canonicalDirectoryDescriptor(
        _ candidate: URL
    ) -> StablePathDescriptor? {
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        return directoryDescriptorWalk(canonical)?.final
    }

    /// Opens each canonical path component separately with `O_NOFOLLOW` and
    /// retains every descriptor in the resulting validation graph. Git path
    /// expressions that contain an intermediate symlink therefore fail
    /// closed; replacing a previously ordinary component with a symlink (or
    /// any other object) invalidates its retained descriptor/path token.
    private static func directoryDescriptorWalk(
        _ candidate: URL
    ) -> DirectoryDescriptorWalk? {
        guard let normalizedPath = lexicallyNormalizedAbsolutePath(
            candidate.path
        ) else { return nil }
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        guard let root = StablePathDescriptor(
            url: currentURL,
            kind: S_IFDIR
        ) else { return nil }
        var descriptors = [root]
        var symlinks: [StableSymlinkWitness] = []
        var current = root
        var components = normalizedPath.split(separator: "/").map(String.init)
        var followedLinkCount = 0
        while !components.isEmpty {
            let component = components.removeFirst()
            guard component != ".", component != "..", !component.isEmpty
            else { return nil }
            var entryState = stat()
            let entryResult = component.withCString {
                Darwin.fstatat(
                    current.descriptor,
                    $0,
                    &entryState,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard entryResult == 0 else { return nil }
            if (entryState.st_mode & S_IFMT) == S_IFLNK {
                guard followedLinkCount < 40 else { return nil }
                guard let witness = StableSymlinkWitness(
                          parent: current,
                          entryName: component
                      ) else {
                    return nil
                }
                followedLinkCount += 1
                symlinks.append(witness)
                var targetPath = witness.target.hasPrefix("/")
                    ? witness.target
                    : currentURL.path + "/" + witness.target
                if !components.isEmpty {
                    targetPath += "/" + components.joined(separator: "/")
                }
                guard let resolvedPath = lexicallyNormalizedAbsolutePath(
                    targetPath
                ) else { return nil }
                components = resolvedPath.split(separator: "/")
                    .map(String.init)
                current = root
                currentURL = URL(
                    fileURLWithPath: "/",
                    isDirectory: true
                )
                continue
            }
            guard (entryState.st_mode & S_IFMT) == S_IFDIR else {
                return nil
            }
            let nextURL = currentURL.appendingPathComponent(
                component,
                isDirectory: true
            )
            guard let next = StablePathDescriptor(
                parent: current,
                entryName: component,
                url: nextURL,
                kind: S_IFDIR
            ) else { return nil }
            descriptors.append(next)
            current = next
            currentURL = nextURL
        }
        return DirectoryDescriptorWalk(
            final: current,
            descriptors: descriptors,
            symlinks: symlinks
        )
    }

    /// Foundation canonicalizes `/private/var` back to `/var` on macOS. That
    /// is useful for app identity but would loop while explicitly resolving
    /// `/var -> private/var`. Git control paths need purely lexical dot-segment
    /// removal so the descriptor walker, not Foundation, owns every symlink.
    private static func lexicallyNormalizedAbsolutePath(
        _ path: String
    ) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var result: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default:
                result.append(component)
            }
        }
        return "/" + result.joined(separator: "/")
    }

    fileprivate static func canonicalExistingDirectory(
        _ candidate: URL
    ) -> URL? {
        guard let descriptor = canonicalDirectoryDescriptor(candidate),
              descriptor.revalidate() else { return nil }
        return candidate.standardizedFileURL
    }

    fileprivate static func boundedGitPathFile(
        _ url: URL,
        beforeRead: (() -> Void)? = nil
    ) -> String? {
        guard let descriptor = StablePathDescriptor(
            url: url,
            kind: S_IFREG
        ), let data = stableRegularFileBytes(
            descriptor,
            byteLimit: 4_096,
            beforeRead: beforeRead
        ), let text = String(data: data, encoding: .utf8) else { return nil }
        return boundedGitPathLine(text)
    }

    private static func boundedGitPathFile(
        _ descriptor: StablePathDescriptor
    ) -> String? {
        guard let data = stableRegularFileBytes(
            descriptor,
            byteLimit: 4_096
        ), let text = String(data: data, encoding: .utf8) else { return nil }
        return boundedGitPathLine(text)
    }

    private static func boundedGitPathLine(_ text: String) -> String? {
        var bytes = Array(text.utf8)
        if bytes.suffix(2).elementsEqual([0x0D, 0x0A]) {
            bytes.removeLast(2)
        } else if bytes.last == 0x0A {
            bytes.removeLast()
        }
        guard !bytes.isEmpty,
              !bytes.contains(0x00),
              !bytes.contains(0x0A),
              !bytes.contains(0x0D) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func stableRegularFileBytes(
        _ descriptor: StablePathDescriptor,
        byteLimit: Int,
        beforeRead: (() -> Void)? = nil
    ) -> Data? {
        guard byteLimit > 0 else { return nil }
        let before = descriptor.information
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0,
              before.st_size <= Int64(byteLimit) else { return nil }
        beforeRead?()

        var bytes = [UInt8](repeating: 0, count: byteLimit + 1)
        var count = 0
        var reachedEndOfFile = false
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor.descriptor,
                    buffer.baseAddress?.advanced(by: count),
                    buffer.count - count
                )
            }
            if readCount < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            if readCount == 0 {
                reachedEndOfFile = true
                break
            }
            count += readCount
        }

        var after = stat()
        guard fstat(descriptor.descriptor, &after) == 0,
              stableFileMetadataMatches(before, after),
              descriptor.revalidate(),
              reachedEndOfFile,
              Int64(count) == before.st_size,
              count <= byteLimit else { return nil }
        return Data(bytes.prefix(count))
    }

    fileprivate static func stableFileMetadataMatches(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        stableIdentityMatches(lhs, rhs, kind: S_IFREG)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    fileprivate static func stableIdentityMatches(
        _ lhs: stat,
        _ rhs: stat,
        kind: UInt16
    ) -> Bool {
        let left = StableFilesystemObjectIdentity(lhs)
        let right = StableFilesystemObjectIdentity(rhs)
        return left == right && left.kind == kind
    }
}

nonisolated enum AgentInboxNavigationResult: Equatable, Sendable {
    case focused(AgentTaskRoute)
    case taskMissing
    case projectUnavailable
    case routeStale
}

nonisolated enum AgentInboxRecoveryResult: Equatable, Sendable {
    case openedNewSession(terminalID: UUID)
    case resumed(terminalID: UUID)
    case taskMissing
    case projectUnavailable
    case unavailable(AgentTaskRecoveryUnavailableReason)
    case changedWhilePreparing
    case launchRejected
}

nonisolated struct QuickTerminalAgentScopeRegistration: Equatable, Sendable {
    let project: AgentTaskProjectIdentity
    let surface: AgentTaskTerminalSurface
}

/// Weak runtime boundary from durable task metadata back to the single
/// application-owned Quick Terminal. ProjectRegistry retains no panel, tab,
/// process, or detector object through this protocol.
@MainActor
protocol QuickTerminalAgentRouting: AnyObject {
    func resolveQuickTerminalAgentRoute(for task: AgentTask) -> AgentTaskRoute?
    func revealQuickTerminalAgentRoute(for task: AgentTask) -> AgentTaskRoute?
    func isQuickTerminalAgentTaskPresented(_ task: AgentTask) -> Bool
}

#if DEBUG
/// Keeps the live-agent XCUITest on the production registry mutation path
/// without reading or writing the developer's durable task metadata.
private actor LiveAgentUITestTaskPersistence: AgentTaskPersisting {
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        if let authorization {
            switch authorization.publishForTesting(operation: { true }) {
            case .published:
                break
            case .failed:
                return .rejected(.ioFailure)
            case .superseded:
                return .rejected(.superseded)
            }
        }
        return .saved(taskCount: tasks.count)
    }

    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }
}
#endif

/// App-wide snapshot of the exact user-task executions covered by one Quit
/// decision, keyed by their owning ProjectManager identity.
@MainActor
struct UserTaskShutdownAuthorization {
    fileprivate let byOwner: [
        ObjectIdentifier: UserTaskExecutionAuthorization
    ]

    var requiresConfirmation: Bool {
        byOwner.values.contains { $0.requiresConfirmation }
    }

    var confirmingOwnerIDs: Set<ObjectIdentifier> {
        Set(byOwner.compactMap { owner, authorization in
            authorization.requiresConfirmation ? owner : nil
        })
    }
}

/// Stable application-wide ownership fence for Quit's machine save phase.
/// Planned Save As tabs may move from their original backing to the one
/// destination chosen by the user; every other project, pane manager, tab,
/// and backing URL must remain identical until the transaction completes.
@MainActor
struct TerminationSaveInventoryAuthorization {
    fileprivate let projectsByRoot: [URL: ObjectIdentifier]
    fileprivate let tabsByProject: [
        ObjectIdentifier: ProjectManager.TerminationOpenTabInventory
    ]
}

/// Manages open projects and recent project history.
/// Each project directory maps to a single ProjectManager instance.
@MainActor
@Observable
final class ProjectRegistry: LSPSettingsObserver {
    private struct AgentInboxPresentationAuthorization {
        let projectURL: URL
        let projectIdentity: AgentTaskProjectIdentity
        let manager: ProjectManager
        let operationID: UUID
        let leaseID: UUID
        let ownerWindow: NSWindow
        let ownerWindowGeneration: UUID
    }

    /// Open projects keyed by their root directory URL.
    private(set) var openProjects: [URL: ProjectManager] = [:]
    /// Projects whose window was closed but whose ProjectManager (and terminal processes)
    /// are kept alive. Reopening the same project returns the existing PM.
    private(set) var backgroundProjects: Set<URL> = []
    /// Project managers detached after their directory disappeared. They stay
    /// retained until user-task process cleanup completes, so a later Quit
    /// can still wait for and reap those executions.
    @ObservationIgnored
    private var detachedTaskCleanupProjects: [
        ObjectIdentifier: ProjectManager
    ] = [:]
    /// Recently opened project paths (most recent first), persisted to UserDefaults.
    var recentProjects: [URL] = []

    /// Application-wide LSP preferences shared by every project manager.
    let lspSettings: LSPSettings
    /// Application-lifetime durable agent identity across every project.
    let agentTasks: AgentTaskRegistry
    @ObservationIgnored
    weak var quickTerminalAgentRouter: (any QuickTerminalAgentRouting)?

    /// Live window sessions, weakly held. A window session belongs to its
    /// SwiftUI scene and dies with it; the registry only needs to be able to
    /// ask "which window already holds this project?", and a strong reference
    /// here would keep closed windows answering that question forever.
    ///
    /// Released entries are compacted on every read, so a missed
    /// ``unregisterWindowSession(_:)`` costs one empty box, not a leak.
    @ObservationIgnored
    private var windowSessionRefs: [WeakWindowSession] = []

    /// The window session that most recently became key. This is the window a
    /// user means by "here" — where a project with no window of its own should
    /// open rather than in a new window.
    @ObservationIgnored
    private weak var keyWindowSessionRef: ProjectWindowSession?

    private struct WeakWindowSession {
        weak var session: ProjectWindowSession?
    }

    private static let recentProjectsKey = "recentProjectPaths"
    private static let recentProjectAgentIdentitiesKey =
        "recentProjectAgentTaskIdentities"
    private static let maxRecentProjects = 10
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let agentRecoveryInspector: AgentTaskRecoveryInspector
    @ObservationIgnored private let agentProcessSnapshotPoller: AgentProcessSnapshotPoller
    @ObservationIgnored private let agentInboxProjectCanonicalizer:
        @Sendable (URL) async -> URL
    /// Testable suspension boundary between detached validation and its final
    /// detached revalidation. Production is a no-op; no filesystem operation
    /// from this protocol executes on MainActor.
    @ObservationIgnored private let agentTaskFilesystemValidationCommitSeam:
        @Sendable () async -> Void
    @ObservationIgnored private let agentTaskWorkspaceValidationSeam:
        @Sendable () async -> Void
    @ObservationIgnored private let contextPresentationGate =
        ContextPresentationCommandGate()
    @ObservationIgnored private var contextPresentationEpochs: [URL: UInt64] = [:]
    @ObservationIgnored private let backgroundReclamationInterval: Duration
    @ObservationIgnored private let backgroundReclamationBatchSize: Int
    @ObservationIgnored private var backgroundReclamationTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundReclamationQueue: [UInt64: URL] = [:]
    @ObservationIgnored private var backgroundReclamationQueuedURLs: Set<URL> = []
    @ObservationIgnored private var nextBackgroundReclamationQueueID: UInt64 = 0
    @ObservationIgnored private var nextBackgroundReclamationDequeueID: UInt64 = 0
    @ObservationIgnored private var backgroundReclamationCycleRemaining = 0
    #if DEBUG
    @ObservationIgnored private(set) var lastReclaimPassCountForTesting = 0
    #endif
    @ObservationIgnored
    private var backgroundPresentationLeases: [URL: Set<UUID>] = [:]
    @ObservationIgnored
    private var agentInboxPresentationOperations: [URL: UUID] = [:]
    @ObservationIgnored
    private var agentTaskProjectsByRoot: [URL: AgentTaskProjectIdentity] = [:] {
        didSet {
            // Opening or closing a project window changes which identities the
            // attention badge projects onto (#1337). Funnelled through `didSet`
            // so every mutation site stays in sync without remembering to call
            // the recompute by hand.
            guard oldValue != agentTaskProjectsByRoot else { return }
            recomputeAgentInboxAttentionCounts()
        }
    }
    /// Exact repository/worktree identities retained independently of live
    /// managers so Quick Terminal never fabricates project ownership from a
    /// recent worktree URL after background reclamation or app relaunch.
    @ObservationIgnored
    private var recentAgentTaskProjectsByRoot: [
        URL: RecentAgentTaskProjectRecord
    ] = [:]
    /// Rotates whenever the persisted Recent identity inventory changes.
    /// Async Recent admission captures this token with its exact record and
    /// checks both again after the final detached filesystem revalidation, so
    /// remove/re-add and A -> B -> A record ABA cannot commit stale authority.
    @ObservationIgnored
    private var recentAgentTaskRecordsGeneration = UUID()
    /// Admission-time proof for live managers. It is deliberately not
    /// regenerated while that manager remains admitted: replacing both the
    /// repository and worktree directories at the same paths must not bless a
    /// stale manager with the replacement repository's identity.
    @ObservationIgnored
    private var agentTaskRepositoryProofsByRoot: [
        URL: RecentAgentTaskRepositoryProof
    ] = [:]
    /// Per-project count of durable agent tasks in the Inbox's
    /// `needsAttention` section, keyed by canonical project URL (#1337).
    ///
    /// Deliberately a cache rather than a computed property: it is read from
    /// `ContentView.body`, and computing it on demand would make every project
    /// window's root view observe the whole durable task array — any task
    /// mutation anywhere would then rebuild an `AgentInboxSnapshot` per window
    /// per body pass. Recomputing on task change instead means windows are
    /// invalidated only when a count they display actually moves.
    private var agentInboxAttentionCounts: [URL: Int] = [:]

    /// Serializes settings lifecycle changes so rapid Apply/Reset operations
    /// cannot race each other across projects.
    @ObservationIgnored
    private var lspSettingsChangeTask: Task<Void, Never>?
    /// Prevents a ProjectManager from being created without a matching agent
    /// metadata registration while that registry has frozen admission.
    @ObservationIgnored
    private(set) var isProjectAdmissionFrozenForTermination = false
    @ObservationIgnored
    private var isAutoSaveFrozenForTermination = false

    init(
        lspSettings: LSPSettings = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        agentTasks: AgentTaskRegistry? = nil,
        agentRecoveryInspector: AgentTaskRecoveryInspector = AgentTaskRecoveryInspector(),
        agentInboxProjectCanonicalizer: @escaping @Sendable (URL) async -> URL = { rawURL in
            await Task.detached {
                ProjectRegistry.canonicalProjectURL(rawURL)
            }.value
        },
        agentTaskFilesystemValidationCommitSeam: @escaping @Sendable () async -> Void = {},
        agentTaskWorkspaceValidationSeam: @escaping @Sendable () async -> Void = {},
        agentDetectionProcessRunner: @escaping ProcessRunner = runRealProcess,
        agentDetectionPollInterval: TimeInterval = 2.0,
        agentDetectionInitialPollDelay: TimeInterval? = nil,
        backgroundReclamationInterval: Duration = .seconds(30),
        backgroundReclamationBatchSize: Int = 4,
        clearRecentProjects: Bool = CommandLine.arguments.contains(
            "--clear-recent-projects"
        )
    ) {
        self.lspSettings = lspSettings
        self.agentTasks = agentTasks ?? Self.makeDefaultAgentTaskRegistry()
        self.defaults = defaults
        self.fileManager = fileManager
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-vendor-recovery"
        ) {
            let descriptor = AgentDescriptor(
                agentType: .codex,
                launchExecutable: "codex"
            )
            self.agentRecoveryInspector = AgentTaskRecoveryInspector(
                recipes: [AgentTaskResumeRecipe(
                    provider: "pine-ui-test",
                    agentTypeIdentifier: descriptor.typeIdentifier,
                    executableAliases: ["codex"],
                    supportedVersions: ["pine-ui-test-version"],
                    identifierArgumentPrefix: ["resume"],
                    identifierArgumentSuffix: []
                )]
            )
        } else {
            self.agentRecoveryInspector = agentRecoveryInspector
        }
        #else
        self.agentRecoveryInspector = agentRecoveryInspector
        #endif
        self.agentInboxProjectCanonicalizer = agentInboxProjectCanonicalizer
        self.agentTaskFilesystemValidationCommitSeam =
            agentTaskFilesystemValidationCommitSeam
        self.agentTaskWorkspaceValidationSeam = agentTaskWorkspaceValidationSeam
        self.agentProcessSnapshotPoller = AgentProcessSnapshotPoller(
            processRunner: agentDetectionProcessRunner,
            pollInterval: agentDetectionPollInterval,
            initialPollDelay: agentDetectionInitialPollDelay
        )
        self.backgroundReclamationInterval = backgroundReclamationInterval
        self.backgroundReclamationBatchSize = max(1, backgroundReclamationBatchSize)
        if clearRecentProjects {
            defaults.removeObject(forKey: Self.recentProjectsKey)
            defaults.removeObject(
                forKey: Self.recentProjectAgentIdentitiesKey
            )
        }
        loadRecentProjects()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-inbox-marketing"
        ) {
            self.agentTasks.seedMarketingInboxForUITesting()
        }
        #endif
        lspSettings.addObserver(self)
        // Keeps the toolbar attention badge current (#1337). The token is not
        // retained: this registry owns `agentTasks`, so the observer cannot
        // outlive its target, and the closure holds `self` weakly.
        _ = self.agentTasks.addTaskChangeObserver { [weak self] _, tasks in
            self?.recomputeAgentInboxAttentionCounts(tasks: tasks)
        }
    }

    private static func makeDefaultAgentTaskRegistry() -> AgentTaskRegistry {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset-state"),
           arguments.contains("--ui-test-live-agent") {
            return AgentTaskRegistry(
                persistence: LiveAgentUITestTaskPersistence()
            )
        }
        #endif
        return AgentTaskRegistry()
    }

    /// Returns the ProjectManager for a given project URL, creating one if needed.
    /// URLs are resolved to their canonical (real) path to prevent duplicates via symlinks.
    /// Returns nil if the directory no longer exists on disk.
    func projectManager(for projectURL: URL) -> ProjectManager? {
        let canonical = canonicalProjectURL(projectURL)
        return projectManager(
            forCanonicalWorktree: canonical,
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: canonical.path,
                canonicalWorktreePath: canonical.path
            )
        )
    }

    /// Opens one Recent entry through its persisted immutable identity.
    ///
    /// Linked worktrees must never pass through the ordinary URL-only opener,
    /// which intentionally models an independently opened folder as
    /// `project == worktree`. This path instead captures the exact Recent
    /// record and generation, builds a descriptor-held graph lease off-main,
    /// crosses the injectable suspension boundary, then revalidates both the
    /// lease and record immediately before the synchronous admission commit.
    /// A stale or missing linked-worktree proof fails closed without rewriting
    /// the persisted record.
    func projectManagerForRecentProject(
        _ projectURL: URL
    ) async -> ProjectManager? {
        guard !isProjectAdmissionFrozenForTermination else { return nil }
        let canonical = await Task.detached(priority: .utility) {
            Self.canonicalProjectURL(projectURL)
        }.value
        guard !Task.isCancelled,
              !isProjectAdmissionFrozenForTermination else { return nil }

        let capturedRecord = recentAgentTaskProjectsByRoot[canonical]
        let capturedGeneration = recentAgentTaskRecordsGeneration
        let identity = capturedRecord?.identity ?? AgentTaskProjectIdentity(
            canonicalProjectPath: canonical.path,
            canonicalWorktreePath: canonical.path
        )
        guard identity.canonicalWorktreePath == canonical.path else {
            return nil
        }
        let expectedProof = capturedRecord?.repositoryProof
        let lease = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.validationLease(
                for: identity,
                expectedProof: expectedProof
            )
        }.value
        guard !Task.isCancelled, let lease else { return nil }

        await agentTaskFilesystemValidationCommitSeam()
        let isStillValid = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        guard !Task.isCancelled,
              isStillValid,
              !isProjectAdmissionFrozenForTermination,
              recentAgentTaskRecordsGeneration == capturedGeneration,
              recentAgentTaskProjectsByRoot[canonical] == capturedRecord else {
            return nil
        }
        return projectManager(
            forCanonicalWorktree: canonical,
            identity: identity,
            repositoryProof: expectedProof,
            validationLease: lease
        )
    }

    /// Non-admitting lookup for SwiftUI scene roots that may outlive their
    /// native window. A stale hidden `ProjectWindowView` must never recreate a
    /// manager after bounded reclamation.
    func projectManagerIfAdmitted(for projectURL: URL) -> ProjectManager? {
        openProjects[canonicalProjectURL(projectURL)]
    }

    /// Whether an admitted URL is an ordinary folder project rather than a
    /// linked-worktree scope that requires its persisted exact proof.
    func isOrdinaryProjectScope(_ projectURL: URL) -> Bool {
        let canonical = canonicalProjectURL(projectURL)
        guard let identity = agentTaskProjectsByRoot[canonical] else {
            return false
        }
        return identity.canonicalProjectPath == identity.canonicalWorktreePath
    }

    /// Registers the immutable persistence/ownership scope captured when the
    /// keep-alive Quick Terminal session is first created. A project-backed
    /// session reuses the exact open worktree identity when available; the
    /// standalone fallback remains explicitly distinguished by its route
    /// surface and is never presented as a project in Agent Inbox.
    func resolveQuickTerminalAgentScope(
        workingDirectory: URL,
        surface: AgentTaskTerminalSurface
    ) async -> QuickTerminalAgentScopeRegistration? {
        guard surface.isQuickTerminal else { return nil }
        let canonical = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.canonicalExistingDirectory(
                workingDirectory
            )
        }.value
        guard !Task.isCancelled, let canonical else { return nil }

        let exactProjectRecord = exactAgentTaskProjectRecord(for: canonical)
        let prepared = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.preparedRegistration(
                workingDirectory: canonical,
                requestedSurface: surface,
                record: exactProjectRecord
            )
        }.value
        guard !Task.isCancelled, let prepared else { return nil }
        let isStillValid = await Task.detached(priority: .utility) {
            prepared.lease.revalidate()
        }.value
        guard !Task.isCancelled, isStillValid else { return nil }
        if prepared.registration.surface == .quickTerminalProject {
            guard exactAgentTaskProjectRecord(for: canonical)
                == exactProjectRecord else { return nil }
        }
        return prepared.registration
    }

    /// Final scope commit invoked only after the controller's generation and
    /// termination fences accepted the prepared registration. The graph is
    /// rebuilt from the current immutable registry record, an injectable
    /// suspension is crossed, then every held descriptor/path/absence witness
    /// is revalidated off-main immediately before the no-await registration.
    func commitQuickTerminalAgentScope(
        _ registration: QuickTerminalAgentScopeRegistration,
        workingDirectory: URL,
        requestedSurface: AgentTaskTerminalSurface
    ) async -> Bool {
        guard requestedSurface.isQuickTerminal else { return false }
        let canonical = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.canonicalExistingDirectory(
                workingDirectory
            )
        }.value
        guard !Task.isCancelled, let canonical else { return false }
        let exactProjectRecord = exactAgentTaskProjectRecord(for: canonical)
        let prepared = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.preparedRegistration(
                workingDirectory: canonical,
                requestedSurface: requestedSurface,
                record: exactProjectRecord
            )
        }.value
        guard !Task.isCancelled,
              let prepared,
              prepared.registration == registration else { return false }
        await agentTaskFilesystemValidationCommitSeam()
        let isStillValid = await Task.detached(priority: .utility) {
            prepared.lease.revalidate()
        }.value
        guard !Task.isCancelled,
              isStillValid,
              exactAgentTaskProjectRecord(for: canonical)
                == exactProjectRecord else { return false }
        agentTasks.registerProject(registration.project)
        return true
    }

    /// Rebuilds the exact filesystem lease for a later lazy consumer such as
    /// Quick Terminal PTY start. Registration never turns a path into a
    /// permanently trusted capability.
    func validateQuickTerminalAgentScope(
        _ registration: QuickTerminalAgentScopeRegistration,
        workingDirectory: URL
    ) async -> Bool {
        let canonical = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.canonicalExistingDirectory(
                workingDirectory
            )
        }.value
        guard !Task.isCancelled, let canonical else { return false }
        let record = exactAgentTaskProjectRecord(for: canonical)
        let prepared = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.preparedRegistration(
                workingDirectory: canonical,
                requestedSurface: registration.surface,
                record: record
            )
        }.value
        guard !Task.isCancelled,
              let prepared,
              prepared.registration == registration else { return false }
        let valid = await Task.detached(priority: .utility) {
            prepared.lease.revalidate()
        }.value
        return !Task.isCancelled
            && valid
            && exactAgentTaskProjectRecord(for: canonical) == record
    }

    private func exactAgentTaskProjectRecord(
        for canonical: URL
    ) -> RecentAgentTaskProjectRecord? {
        if let liveIdentity = agentTaskProjectsByRoot[canonical] {
            return RecentAgentTaskProjectRecord(
                identity: liveIdentity,
                repositoryProof: agentTaskRepositoryProofsByRoot[canonical]
            )
        }
        return recentAgentTaskProjectsByRoot[canonical]
    }

    /// Attaches the keep-alive Quick Terminal to the same application-owned
    /// process poller as project terminals. The opt-out matches project
    /// detection and this method never creates a second capture source.
    @discardableResult
    func subscribeQuickTerminalAgentSnapshots(
        _ consumer: any AgentProcessSnapshotConsuming
    ) -> Bool {
        guard !Self.isAgentDetectionDisabled else { return false }
        agentProcessSnapshotPoller.subscribe(consumer)
        return true
    }

    func unsubscribeQuickTerminalAgentSnapshots(
        _ consumer: any AgentProcessSnapshotConsuming
    ) {
        agentProcessSnapshotPoller.unsubscribe(consumer)
    }

    private static var isAgentDetectionDisabled: Bool {
        CommandLine.arguments.contains("--disable-agent-detection")
            || ProcessInfo.processInfo.environment[
                "PINE_DISABLE_AGENT_DETECTION"
            ] != nil
    }

    /// Opens a Pine-managed worktree while retaining the owning repository as
    /// the shared project scope. Sibling worktrees therefore remain comparable
    /// without sharing terminal, task, event, checkpoint, or notification IDs.
    func projectManager(
        for worktree: AgentManagedWorktree
    ) async -> ProjectManager? {
        let repository = canonicalProjectURL(worktree.repositoryRoot)
        let managedRoot = canonicalProjectURL(worktree.managedRoot)
        let worktreeRoot = canonicalProjectURL(worktree.worktreeRoot)
        guard repository == worktree.repositoryRoot.standardizedFileURL,
              managedRoot == worktree.managedRoot.standardizedFileURL,
              worktreeRoot == worktree.worktreeRoot.standardizedFileURL,
              worktreeRoot.deletingLastPathComponent() == managedRoot else {
            return nil
        }
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: repository.path,
            canonicalWorktreePath: worktreeRoot.path
        )
        let lease = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.validationLease(
                for: identity,
                expectedProof: worktree.repositoryProof
            )
        }.value
        guard !Task.isCancelled, let lease else { return nil }
        await agentTaskFilesystemValidationCommitSeam()
        let isStillValid = await Task.detached(priority: .utility) {
            lease.revalidate()
        }.value
        guard !Task.isCancelled, isStillValid else { return nil }
        return projectManager(
            forCanonicalWorktree: worktreeRoot,
            identity: identity,
            repositoryProof: worktree.repositoryProof,
            validationLease: lease
        )
    }

    /// Reopens a persisted exact project/worktree scope after both paths have
    /// been canonicalized again. This is used by Inbox navigation and recovery.
    private func projectManager(
        for identity: AgentTaskProjectIdentity,
        reopenBackgroundProject: Bool = true,
        admitMissingProjectInBackground: Bool = false
    ) async -> ProjectManager? {
        let project = canonicalProjectURL(URL(
            fileURLWithPath: identity.canonicalProjectPath,
            isDirectory: true
        ))
        let worktree = canonicalProjectURL(URL(
            fileURLWithPath: identity.canonicalWorktreePath,
            isDirectory: true
        ))
        guard project.path == identity.canonicalProjectPath,
              worktree.path == identity.canonicalWorktreePath else {
            return nil
        }
        var validationLease: RecentAgentTaskFilesystemValidationLease?
        var repositoryProof: RecentAgentTaskRepositoryProof?
        if project != worktree {
            guard let exactRecord = exactAgentTaskProjectRecord(for: worktree),
                  exactRecord.identity == identity,
                  let expectedProof = exactRecord.repositoryProof else {
                return nil
            }
            let lease = await Task.detached(priority: .utility) {
                RecentAgentTaskFilesystemValidator.validationLease(
                    for: identity,
                    expectedProof: expectedProof
                )
            }.value
            guard !Task.isCancelled, let lease else { return nil }
            await agentTaskFilesystemValidationCommitSeam()
            let isStillValid = await Task.detached(priority: .utility) {
                lease.revalidate()
            }.value
            guard !Task.isCancelled,
                  isStillValid,
                  exactAgentTaskProjectRecord(for: worktree)
                    == exactRecord else { return nil }
            repositoryProof = expectedProof
            validationLease = lease
        }
        return projectManager(
            forCanonicalWorktree: worktree,
            identity: identity,
            repositoryProof: repositoryProof,
            validationLease: validationLease,
            reopenBackgroundProject: reopenBackgroundProject,
            admitMissingProjectInBackground: admitMissingProjectInBackground
        )
    }

    private func projectManager(
        forCanonicalWorktree canonical: URL,
        identity: AgentTaskProjectIdentity,
        repositoryProof: RecentAgentTaskRepositoryProof? = nil,
        validationLease: RecentAgentTaskFilesystemValidationLease? = nil,
        reopenBackgroundProject: Bool = true,
        admitMissingProjectInBackground: Bool = false
    ) -> ProjectManager? {
        // Retain descriptor ownership through the entire synchronous commit.
        // Distinct project/worktree callers cannot enter without this lease.
        guard identity.canonicalProjectPath == identity.canonicalWorktreePath
                || validationLease != nil else { return nil }
        let hasValidatedFilesystem = validationLease?.identity == identity
            && validationLease?.canonicalWorktree == canonical
        guard validationLease == nil || hasValidatedFilesystem else {
            return nil
        }
        if let existing = openProjects[canonical] {
            guard agentTaskProjectsByRoot[canonical] == identity else {
                return nil
            }
            if identity.canonicalProjectPath
                != identity.canonicalWorktreePath {
                guard let validationLease else { return nil }
                existing.replaceAgentTaskFilesystemAdmission(
                    validationLease,
                    identity: identity
                )
            }
            // Verify directory still exists when reopening from background
            if backgroundProjects.contains(canonical) {
                if !hasValidatedFilesystem {
                    var isDir: ObjCBool = false
                    guard fileManager.fileExists(
                        atPath: canonical.path,
                        isDirectory: &isDir
                    ), isDir.boolValue else {
                        // Directory was deleted while in background — clean up
                        existing.requestUserTaskShutdown()
                        existing.terminal.terminateAll()
                        existing.shutdownReclaimableProject()
                        let ownerID = ObjectIdentifier(existing)
                        detachedTaskCleanupProjects[ownerID] = existing
                        Task { @MainActor [weak self] in
                            let didStop = await existing.shutdownUserTasks(
                                until: .now() + 2
                            )
                            if didStop {
                                self?.detachedTaskCleanupProjects.removeValue(
                                    forKey: ownerID
                                )
                            }
                        }
                        openProjects.removeValue(forKey: canonical)
                        agentTaskProjectsByRoot.removeValue(forKey: canonical)
                        agentTaskRepositoryProofsByRoot.removeValue(
                            forKey: canonical
                        )
                        backgroundProjects.remove(canonical)
                        agentTasks.setWindowOpen(
                            false,
                            project: identity
                        )
                        existing.terminal.setAgentTaskWindowOpen(false)
                        recentProjects.removeAll { $0 == canonical }
                        removeRecentAgentTaskRecord(for: canonical)
                        saveRecentProjects()
                        return nil
                    }
                }
                if reopenBackgroundProject {
                    existing.prepareForWindowPresentation()
                    _ = markProjectWindowOpen(
                        canonical,
                        identity: identity,
                        manager: existing
                    )
                }
            }
            addToRecent(canonical, identity: identity)
            return existing
        }
        // Validate that the directory still exists
        if !hasValidatedFilesystem {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(
                atPath: canonical.path,
                isDirectory: &isDir
            ), isDir.boolValue else {
                recentProjects.removeAll { $0 == canonical }
                removeRecentAgentTaskRecord(for: canonical)
                saveRecentProjects()
                return nil
            }
            var isProjectDir: ObjCBool = false
            guard fileManager.fileExists(
                atPath: identity.canonicalProjectPath,
                isDirectory: &isProjectDir
            ), isProjectDir.boolValue else { return nil }
        }
        guard !isProjectAdmissionFrozenForTermination else { return nil }
        agentTasks.registerProject(identity)
        let contextEpoch = contextPresentationEpochs[canonical, default: 0] &+ 1
        contextPresentationEpochs[canonical] = contextEpoch
        let pm = ProjectManager(
            lspSettings: lspSettings,
            sessionDefaults: defaults,
            agentProcessSnapshotPoller: agentProcessSnapshotPoller,
            agentTaskRegistry: agentTasks,
            workspaceFilesystemValidationSeam:
                agentTaskWorkspaceValidationSeam,
            contextFileWriter: ContextFileWriter(
                presentationGate: contextPresentationGate
            ),
            contextPresentationIdentity: ContextPresentationIdentity(
                epoch: contextEpoch
            )
        )
        if isAutoSaveFrozenForTermination {
            pm.freezeAutoSaveForTermination()
        }
        pm.loadDirectory(
            url: canonical,
            agentTaskProject: identity,
            filesystemAdmission: validationLease
        )
        openProjects[canonical] = pm
        agentTaskProjectsByRoot[canonical] = identity
        if let repositoryProof,
           identity.canonicalProjectPath != identity.canonicalWorktreePath {
            agentTaskRepositoryProofsByRoot[canonical] = repositoryProof
        }
        if admitMissingProjectInBackground {
            backgroundProjects.insert(canonical)
            pm.suspendEditorServices()
            agentTasks.setWindowOpen(false, project: identity)
            pm.terminal.setAgentTaskWindowOpen(false)
            enqueueBackgroundReclamationCandidate(canonical)
            scheduleBackgroundReclamationIfNeeded()
        } else {
            agentTasks.setWindowOpen(true, project: identity)
            pm.terminal.setAgentTaskWindowOpen(true)
        }
        addToRecent(canonical, identity: identity)
        #if DEBUG
        seedAgentRecoveryUITestFixture(
            project: identity
        )
        #endif
        return pm
    }

    /// Commits the retained-project presentation transition only for the
    /// exact manager and project/worktree identity that were resolved. Inbox
    /// recovery deliberately defers this until an eligible window exists.
    @discardableResult
    private func markProjectWindowOpen(
        _ canonical: URL,
        identity: AgentTaskProjectIdentity,
        manager: ProjectManager
    ) -> Bool {
        guard openProjects[canonical] === manager,
              agentTaskProjectsByRoot[canonical] == identity else {
            return false
        }
        backgroundProjects.remove(canonical)
        manager.resumeEditorServices()
        agentTasks.setWindowOpen(true, project: identity)
        manager.terminal.setAgentTaskWindowOpen(true)
        return true
    }

    #if DEBUG
    /// Creates a durable, terminated Pine-owned task only for the explicit
    /// recovery XCUITest. A second launch loads the persisted card instead of
    /// seeding another one, exercising the real restore boundary.
    private func seedAgentRecoveryUITestFixture(
        project: AgentTaskProjectIdentity
    ) {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-recovery"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await agentTasks.flushPersistence(
                maximumDuration: .seconds(2)
            )
            guard !agentTasks.tasks.contains(where: { $0.project == project }) else {
                return
            }
            let startedAt = Date()
            let terminalID = UUID()
            let context = AgentTaskBridgeContext(
                project: project,
                route: AgentTaskRoute(
                    paneID: UUID(),
                    tabID: terminalID,
                    terminalID: terminalID
                ),
                origin: .pineLaunched,
                observedAt: startedAt
            )
            let launch = agentTasks.preparePineLaunch(
                descriptor: AgentDescriptor(
                    agentType: .codex,
                    launchExecutable: "codex"
                ),
                context: context,
                title: "Recovery fixture",
                objective: "Finish the Pine 2.0 release",
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: startedAt
                )
            )
            guard case .reserved(let reservation) = launch,
                  agentTasks.armLaunch(reservation) else { return }
            let session = AgentSession(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000001307"
                ) ?? UUID(),
                agentType: .codex,
                state: .executing,
                startedAt: startedAt
            )
            _ = session.bindProcessEvidence(AgentProcessEvidence(
                processIdentifier: 13_007,
                processGeneration: 1,
                startIdentifier: "ui-recovery-fixture",
                observedStartedAt: startedAt,
                startIsAuthoritative: true
            ))
            agentTasks.bridge(
                session,
                replacing: nil,
                context: context,
                reservation: reservation
            )
            session.applyLiveness(.terminated)
            agentTasks.bridge(session, replacing: session, context: context)
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-test-agent-vendor-recovery"
            ), let taskID = agentTasks.tasks.first(where: {
                $0.runs.last?.id == session.id
            })?.id,
               var task = agentTasks.task(for: taskID),
               !task.runs.isEmpty {
                task.lifecycle = .paused
                task.runs[task.runs.count - 1].vendorIdentity =
                    AgentVendorSessionIdentity(
                        provider: "pine-ui-test",
                        opaqueIdentifier: "ui-test-session",
                        executableVersion: "pine-ui-test-version"
                    )
                agentTasks.setTasksForTesting(agentTasks.tasks.map {
                    $0.id == taskID ? task : $0
                })
            }
            _ = await agentTasks.flushPersistence(
                maximumDuration: .seconds(2)
            )
        }
    }

    /// Gives the Open Folder lifecycle XCUITest a deterministic live-agent
    /// transition after the project window has installed its native delegate.
    /// The pane runs a deterministic inert child rather than the user's shell;
    /// agent evidence is synthetic and `ps` polling remains disabled.
    /// The fixture exists only in Debug test hosts and only behind an explicit
    /// launch argument (#1407).
    func seedLiveAgentUITestFixture(
        afterWindowBindingFor projectManager: ProjectManager
    ) async {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-live-agent"
        ) else { return }
        guard await projectManager.awaitDialogOwnerWindow() != nil else {
            guard !Task.isCancelled else { return }
            assertionFailure(
                "Live-agent UI fixture requires a bound project window"
            )
            return
        }
        guard let rootURL = projectManager.rootURL,
              let project = agentTaskProjectsByRoot[canonicalProjectURL(rootURL)] else {
            assertionFailure(
                "Live-agent UI fixture requires a registered project"
            )
            return
        }
        guard !projectManager.terminal.allTerminalTabs.contains(where: {
            $0.agentSession?.currentTask == Self.liveAgentUITestTask
        }) else { return }

        let tab: TerminalTab
        if let existing = projectManager.terminal.allTerminalTabs.first {
            tab = existing
        } else {
            projectManager.paneManager.createTerminalPaneAtBottom(
                workingDirectory: rootURL,
                initialProcess: TerminalInitialProcess(
                    executablePath: "/bin/cat",
                    arguments: []
                )
            )
            guard let created = projectManager.terminal.allTerminalTabs.first else {
                assertionFailure("Live-agent UI fixture requires a terminal tab")
                return
            }
            tab = created
        }
        let startedAt = Date()
        let session = AgentSession(
            agentType: .codex,
            state: .executing,
            startedAt: startedAt,
            currentTask: Self.liveAgentUITestTask
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 14_007,
            processGeneration: 1,
            startIdentifier: "ui-live-agent-1407",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        tab.agentSession = session
        // Exercise the same durable registry mutation and project-window
        // observation invalidation as a genuinely detected active agent.
        projectManager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        assert(agentTasks.tasks.contains(where: { $0.project == project }))
    }

    private static let liveAgentUITestTask =
        "Verify Open Folder while an agent is active"
    #endif

    /// Opens a project via folder picker. Returns the project URL if opened.
    @discardableResult
    func openProjectViaPanel(
        context: DialogPresentationContext
    ) async -> URL? {
        guard let canonical = await chooseProjectViaPanel(context: context),
              projectManager(for: canonical) != nil else { return nil }
        return canonical
    }

    /// Chooses a project directory without admitting it into the registry.
    ///
    /// Multi-project windows need to perform their own collision check before
    /// admission. Reusing ``openProjectViaPanel(context:)`` there would create
    /// the manager first, making a newly selected directory indistinguishable
    /// from a project already presented by another window.
    @discardableResult
    func chooseProjectViaPanel(
        context: DialogPresentationContext
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Strings.openPanelMessage
        panel.prompt = Strings.openPanelPrompt

        guard await panel.runSheet(on: context) == .OK,
              let url = panel.url else { return nil }
        return canonicalProjectURL(url)
    }

    /// Opens a project via folder picker, first waiting for the project
    /// window to bind a dialog owner (#1344).
    ///
    /// Project scenes bind their AppKit owner asynchronously
    /// (`WindowCloseInterceptor` → `DialogPresenter.register` →
    /// `bindDialogOwnerWindow`), so callers that capture the presentation
    /// context synchronously — e.g. the toolbar Open Folder button and the
    /// `openNewProject()` duplicates — fire into a `nil` owner right after a
    /// window appears or is replaced, and `NSSavePanel.runSheet` silently
    /// aborts. This bounds the wait on `awaitDialogOwnerWindow`, then presents
    /// the panel anchored to the freshly bound owner. Returns `nil` if the
    /// owner never becomes eligible or the user cancels.
    @discardableResult
    func openProjectViaPanel(
        for projectManager: ProjectManager,
        maximumAttempts: Int = 80,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        isEligible: (@MainActor (NSWindow) -> Bool)? = nil
    ) async -> URL? {
        guard await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: maximumAttempts,
            waitForNextAttempt: waitForNextAttempt,
            isEligible: isEligible
        ) != nil else {
            Logger.app.error("Open Folder aborted: no eligible project dialog owner after bounded recovery (#1407)")
            return nil
        }
        let context = DialogPresenter.forProject(projectManager)
        return await openProjectViaPanel(context: context)
    }

    /// Project-window variant of ``chooseProjectViaPanel(context:)``. It keeps
    /// the same bounded owner recovery as the admitting API while leaving the
    /// selected URL untouched until the window session validates it.
    @discardableResult
    func chooseProjectViaPanel(
        for projectManager: ProjectManager,
        maximumAttempts: Int = 80,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        isEligible: (@MainActor (NSWindow) -> Bool)? = nil
    ) async -> URL? {
        guard await projectManager.awaitDialogOwnerWindow(
            maximumAttempts: maximumAttempts,
            waitForNextAttempt: waitForNextAttempt,
            isEligible: isEligible
        ) != nil else {
            Logger.app.error("Open Folder aborted: no eligible project dialog owner after bounded recovery (#1407)")
            return nil
        }
        let context = DialogPresenter.forProject(projectManager)
        return await chooseProjectViaPanel(context: context)
    }

    /// Closes the project window but keeps the ProjectManager alive. Terminal
    /// sessions and user tasks continue in the background; reopening the
    /// project restores access to their current state and output history.
    func closeProjectWindow(_ url: URL) {
        closeProjectWindow(
            url,
            expectedManager: nil,
            expectedWindowGeneration: nil
        )
    }

    /// Window-delegate close path. Both object identity and binding generation
    /// must still match so a delayed close from window A cannot background a
    /// replacement manager/window B registered for the same URL.
    func closeProjectWindow(
        _ url: URL,
        expectedManager: ProjectManager?,
        expectedWindowGeneration: UUID?
    ) {
        let canonical = canonicalProjectURL(url)
        guard let manager = openProjects[canonical] else { return }
        if let expectedManager, manager !== expectedManager { return }
        if let expectedWindowGeneration,
           manager.dialogOwnerWindowGeneration != expectedWindowGeneration {
            return
        }
        manager.saveSession()
        backgroundProjects.insert(canonical)
        manager.suspendEditorServices()
        if let identity = agentTaskProjectsByRoot[canonical] {
            agentTasks.setWindowOpen(false, project: identity)
        }
        manager.terminal.setAgentTaskWindowOpen(false)
        enqueueBackgroundReclamationCandidate(canonical)
        scheduleBackgroundReclamationIfNeeded()
    }

    /// Reclaims one bounded set of editor-only background managers. Process,
    /// launch, agent, and user-task evidence all fail closed and keep the exact
    /// manager alive for the next pass.
    func runBackgroundReclamationPassForTesting() {
        let hasMoreInCycle = reclaimIdleBackgroundProjects()
        scheduleBackgroundReclamationIfNeeded(
            delayUntilNextCycle: !hasMoreInCycle
        )
    }

    #if DEBUG
    var agentSnapshotSubscriberCountForTesting: Int {
        agentProcessSnapshotPoller.subscriberCountForTesting
    }

    func runAgentProcessSnapshotForTesting() {
        agentProcessSnapshotPoller.runSnapshotForTesting()
    }

    /// Runs the same off-main capture used by production polling, but without
    /// waiting for the timer. Reserved for deterministic integration tests
    /// that launch controlled local processes.
    func runRealAgentProcessSnapshotForTesting() async {
        await agentProcessSnapshotPoller.runRealSnapshotForTesting()
    }

    func captureRealAgentProcessesForTesting() async -> [DetectedProcess]? {
        await agentProcessSnapshotPoller.captureRealProcessesForTesting()
    }

    func applyCompleteAgentProcessTreeForTesting(
        _ processes: [DetectedProcess]
    ) {
        agentProcessSnapshotPoller.applyCompleteProcessTreeForTesting(
            processes
        )
    }
    #endif

    /// Processes at most one fixed-size batch. Retained projects rotate to the
    /// next delayed cycle; remaining candidates in the current cycle continue
    /// on later MainActor turns without another 30-second delay.
    @discardableResult
    private func reclaimIdleBackgroundProjects() -> Bool {
        guard !isProjectAdmissionFrozenForTermination,
              !isAutoSaveFrozenForTermination else { return false }
        if backgroundReclamationCycleRemaining == 0 {
            backgroundReclamationCycleRemaining =
                backgroundReclamationQueuedURLs.count
        }
        let candidateLimit = min(
            backgroundReclamationBatchSize,
            backgroundReclamationCycleRemaining
        )
        var processedCount = 0
        for _ in 0..<candidateLimit {
            guard let canonical = dequeueBackgroundReclamationCandidate() else {
                backgroundReclamationCycleRemaining = 0
                break
            }
            backgroundReclamationCycleRemaining -= 1
            processedCount += 1
            guard let manager = openProjects[canonical],
                  backgroundProjects.contains(canonical) else {
                continue
            }
            guard backgroundPresentationLeases[canonical]?.isEmpty != false,
                  !manager.requiresBackgroundRetention else {
                enqueueBackgroundReclamationCandidate(canonical)
                continue
            }
            manager.saveSession()
            manager.shutdownReclaimableProject()
            openProjects.removeValue(forKey: canonical)
            agentTaskProjectsByRoot.removeValue(forKey: canonical)
            agentTaskRepositoryProofsByRoot.removeValue(forKey: canonical)
            backgroundProjects.remove(canonical)
        }
        #if DEBUG
        lastReclaimPassCountForTesting = processedCount
        #endif
        return backgroundReclamationCycleRemaining > 0
    }

    private func enqueueBackgroundReclamationCandidate(_ canonical: URL) {
        guard backgroundReclamationQueuedURLs.insert(canonical).inserted else {
            return
        }
        let queueID = nextBackgroundReclamationQueueID
        nextBackgroundReclamationQueueID &+= 1
        backgroundReclamationQueue[queueID] = canonical
    }

    private func dequeueBackgroundReclamationCandidate() -> URL? {
        while nextBackgroundReclamationDequeueID
                < nextBackgroundReclamationQueueID {
            let queueID = nextBackgroundReclamationDequeueID
            nextBackgroundReclamationDequeueID &+= 1
            guard let canonical = backgroundReclamationQueue.removeValue(
                forKey: queueID
            ), backgroundReclamationQueuedURLs.remove(canonical) != nil else {
                continue
            }
            return canonical
        }
        return nil
    }

    private func scheduleBackgroundReclamationIfNeeded(
        delayUntilNextCycle: Bool = true
    ) {
        guard backgroundReclamationTask == nil,
              !backgroundReclamationQueuedURLs.isEmpty,
              !isProjectAdmissionFrozenForTermination,
              !isAutoSaveFrozenForTermination else { return }
        let interval = backgroundReclamationInterval
        backgroundReclamationTask = Task { @MainActor [weak self] in
            if delayUntilNextCycle {
                try? await Task.sleep(for: interval)
            } else {
                await Task.yield()
            }
            guard let self, !Task.isCancelled else { return }
            backgroundReclamationTask = nil
            let hasMoreInCycle = reclaimIdleBackgroundProjects()
            scheduleBackgroundReclamationIfNeeded(
                delayUntilNextCycle: !hasMoreInCycle
            )
        }
    }

    @discardableResult
    func retainBackgroundProjectForPresentation(
        _ url: URL,
        manager: ProjectManager
    ) -> UUID? {
        let canonical = canonicalProjectURL(url)
        guard openProjects[canonical] === manager else { return nil }
        let leaseID = UUID()
        backgroundPresentationLeases[canonical, default: []].insert(leaseID)
        return leaseID
    }

    func releaseBackgroundProjectPresentation(
        _ leaseID: UUID,
        for url: URL
    ) {
        let canonical = canonicalProjectURL(url)
        backgroundPresentationLeases[canonical]?.remove(leaseID)
        if backgroundPresentationLeases[canonical]?.isEmpty == true {
            backgroundPresentationLeases[canonical] = nil
        }
        scheduleBackgroundReclamationIfNeeded()
    }

    /// Closes a project and removes it from open projects.
    /// For backwards compatibility, delegates to `closeProjectWindow`.
    func closeProject(_ url: URL) {
        closeProjectWindow(url)
    }

    /// True only when the exact live terminal route is already visible in the
    /// key project window. Merely having Pine active or the project open is not
    /// enough to suppress a notification for another pane or terminal tab.
    func isAgentTaskPresented(_ taskID: UUID) -> Bool {
        guard let task = agentTasks.task(for: taskID),
              task.lifecycle == .active,
              task.route.availability == .available,
              let run = task.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: task.route.terminalID,
                  runID: run.id
              ) else { return false }
        if task.route.surface.isQuickTerminal {
            return quickTerminalAgentRouter?
                .isQuickTerminalAgentTaskPresented(task) == true
        }
        guard task.route.surface == .projectWindow else { return false }
        let projectURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        ).standardizedFileURL
        guard !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              manager.paneManager.activePaneID.id == task.route.paneID,
              manager.paneManager.terminalState(
                  for: PaneID(id: task.route.paneID)
              )?.activeTerminalID == task.route.tabID,
              let window = manager.dialogOwnerWindow,
              window.isVisible,
              window.isKeyWindow,
              window.occlusionState.contains(.visible) else { return false }
        return true
    }

    func canOfferAgentTaskVendorResume(_ taskID: UUID) -> Bool {
        guard agentTasks.canResumeTask(taskID),
              let task = agentTasks.task(for: taskID) else { return false }
        return agentRecoveryInspector.canOfferVendorResume(for: task)
    }

    /// Re-resolves a persisted route against current application ownership.
    /// No UI object is retained by the durable registry; every activation must
    /// cross this boundary immediately before use.
    func resolveAgentTaskRoute(
        _ taskID: UUID,
        targetTerminalID: UUID? = nil
    ) async -> AgentTaskRoute? {
        guard let task = agentTasks.task(for: taskID) else { return nil }
        if task.lifecycle == .paused, let targetTerminalID {
            return await resolvePausedAgentTaskRoute(
                task,
                targetTerminalID: targetTerminalID
            )
        }
        guard task.lifecycle == .active,
              task.route.availability == .available,
              let run = task.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: task.route.terminalID,
                  runID: run.id
              ) else { return nil }
        if task.route.surface.isQuickTerminal {
            guard let route = quickTerminalAgentRouter?
                    .resolveQuickTerminalAgentRoute(for: task),
                  route == task.route,
                  agentTasks.task(for: taskID) == task,
                  agentTasks.isExactLiveOwner(
                    taskID: taskID,
                    terminalID: route.terminalID,
                    runID: run.id
                  ) else { return nil }
            return route
        }
        guard task.route.surface == .projectWindow else { return nil }
        let rawURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await agentInboxProjectCanonicalizer(rawURL)
        guard let currentTask = agentTasks.task(for: taskID),
              currentTask == task,
              currentTask.lifecycle == .active,
              currentTask.route.availability == .available,
              let currentRun = currentTask.runs.last,
              currentRun == run,
              currentRun.liveness == .live,
              currentRun.endedAt == nil,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: currentTask.route.terminalID,
                  runID: currentRun.id
              ),
              !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              projectURL.path == task.project.canonicalWorktreePath else {
            return nil
        }

        var matches: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard let state = manager.paneManager.terminalState(for: paneID) else {
                continue
            }
            for tab in state.terminalTabs {
                guard tab.id == task.route.terminalID,
                      let session = tab.agentSession,
                      session.id == run.id,
                      session.liveness == .live,
                      session.agentType == task.descriptor.agentType,
                      let observed = session.processEvidence,
                      observed.identifiesSameProcess(as: run.process),
                      run.terminalID == tab.id,
                      agentTasks.isExactLiveOwner(
                          taskID: taskID,
                          terminalID: tab.id,
                          runID: session.id
                      ) else {
                    continue
                }
                matches.append(AgentTaskRoute(
                    paneID: paneID.id,
                    tabID: tab.id,
                    terminalID: tab.id
                ))
            }
        }
        guard matches.count == 1,
              matches[0] == currentTask.route,
              agentTasks.task(for: taskID) == currentTask,
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: currentTask.route.terminalID,
                  runID: currentRun.id
              ),
              !backgroundProjects.contains(projectURL) else { return nil }
        return matches[0]
    }

    /// Opens (when necessary), re-resolves, and focuses one exact live agent
    /// route. Every suspension is followed by the same task/run/process
    /// validation used by `resolveAgentTaskRoute`; a replacement shell or PID
    /// generation therefore degrades to `.routeStale` without navigation.
    func navigateToAgentTaskFromInbox(
        _ taskID: UUID,
        openProjectWindow: @escaping @MainActor (URL) -> Void,
        waitUntilPresented: (@MainActor (ProjectManager) async -> Bool)? = nil,
        activateApplication: (@MainActor (ProjectManager) -> Void)? = nil,
        expectedNotificationRoute: AgentNotificationRouteIdentity? = nil
    ) async -> AgentInboxNavigationResult {
        guard let initialTask = agentTasks.task(for: taskID) else {
            return .taskMissing
        }
        guard initialTask.lifecycle == .active,
              initialTask.route.availability != .missing,
              matches(initialTask, expectedNotificationRoute) else {
            return .routeStale
        }

        if initialTask.route.surface.isQuickTerminal {
            guard let run = initialTask.runs.last,
                  run.liveness == .live,
                  run.endedAt == nil,
                  agentTasks.isExactLiveOwner(
                    taskID: taskID,
                    terminalID: initialTask.route.terminalID,
                    runID: run.id
                  ),
                  let route = quickTerminalAgentRouter?
                    .revealQuickTerminalAgentRoute(for: initialTask),
                  route == initialTask.route,
                  let currentTask = agentTasks.task(for: taskID),
                  currentTask == initialTask,
                  matches(currentTask, expectedNotificationRoute),
                  agentTasks.isExactLiveOwner(
                    taskID: taskID,
                    terminalID: route.terminalID,
                    runID: run.id
                  ) else {
                return .routeStale
            }
            _ = agentTasks.setReviewed(true, taskID: taskID)
            return .focused(route)
        }
        guard initialTask.route.surface == .projectWindow else {
            return .routeStale
        }

        let rawURL = URL(
            fileURLWithPath: initialTask.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await agentInboxProjectCanonicalizer(rawURL)
        guard projectURL.path == initialTask.project.canonicalWorktreePath,
              let presentation = await ensureAgentInboxProjectPresented(
                initialTask,
                at: projectURL,
                openProjectWindow: openProjectWindow,
                waitUntilPresented: waitUntilPresented
              ) else {
            return .projectUnavailable
        }
        let manager = presentation.manager
        defer { finishAgentInboxPresentation(presentation) }

        guard let route = await resolveAgentTaskRoute(taskID),
              let currentTask = agentTasks.task(for: taskID),
              currentTask.lifecycle == .active,
              currentTask.route == route,
              currentTask.route.availability == .available,
              let run = currentTask.runs.last,
              run.liveness == .live,
              run.endedAt == nil,
              matches(currentTask, expectedNotificationRoute),
              agentTasks.isExactLiveOwner(
                  taskID: taskID,
                  terminalID: route.terminalID,
                  runID: run.id
              ), presentationIsCurrent(presentation) else {
            return .routeStale
        }

        let activate: @MainActor () -> Void
        if let activateApplication {
            activate = { activateApplication(manager) }
        } else if let window = manager.dialogOwnerWindow {
            activate = {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        } else {
            return .projectUnavailable
        }

        guard manager.terminal.activateTerminal(
            paneID: PaneID(id: route.paneID),
            tabID: route.tabID
        ) else {
            return .routeStale
        }
        _ = agentTasks.setReviewed(true, taskID: taskID)
        activate()
        return .focused(route)
    }

    /// Recovers a durable task only after an explicit Inbox action. The task,
    /// project binding, executable and adapter version are inspected again
    /// after the project window is presented and immediately before launch.
    func recoverAgentTaskFromInbox(
        _ taskID: UUID,
        action: AgentTaskRecoveryAction,
        openProjectWindow: @escaping @MainActor (URL) -> Void,
        waitUntilPresented: (@MainActor (ProjectManager) async -> Bool)? = nil,
        activateApplication: (@MainActor (ProjectManager) -> Void)? = nil
    ) async -> AgentInboxRecoveryResult {
        guard let initialTask = agentTasks.task(for: taskID) else {
            return .taskMissing
        }
        // Recovery currently launches only into project-pane TerminalManager.
        // Quick Terminal tasks must never fall through this path and admit a
        // project manager from durable path metadata.
        guard initialTask.route.surface == .projectWindow else {
            return .launchRejected
        }
        let rawURL = URL(
            fileURLWithPath: initialTask.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await agentInboxProjectCanonicalizer(rawURL)
        guard projectURL.path == initialTask.project.canonicalWorktreePath,
              let presentation = await ensureAgentInboxProjectPresented(
                initialTask,
                at: projectURL,
                openProjectWindow: openProjectWindow,
                waitUntilPresented: waitUntilPresented
              ) else {
            return .projectUnavailable
        }
        let manager = presentation.manager
        defer { finishAgentInboxPresentation(presentation) }
        guard agentTasks.task(for: taskID) == initialTask else {
            return .changedWhilePreparing
        }

        let evaluation = await agentRecoveryInspector.inspect(
            task: initialTask,
            action: action
        )
        guard agentTasks.task(for: taskID) == initialTask else {
            return .changedWhilePreparing
        }
        guard case .ready(let plan) = evaluation else {
            if case .unavailable(let reason) = evaluation {
                return .unavailable(reason)
            }
            return .launchRejected
        }

        guard await manager.revalidateAgentTaskFilesystemAdmission(
            expectedIdentity: initialTask.project,
            workingDirectory: plan.workingDirectory
        ) else { return .changedWhilePreparing }

        // No suspension occurs between this full ownership fence and launch.
        // A concurrent presentation, stale close, reclaim, task mutation, or
        // owner replacement therefore cannot launch into an obsolete manager.
        guard !Task.isCancelled,
              agentTasks.task(for: taskID) == initialTask,
              presentationIsCurrent(presentation) else {
            return .changedWhilePreparing
        }
        let result = manager.terminal.launchAgentRecovery(plan)
        let terminalID: UUID
        switch result {
        case .openedNewSession(let id):
            terminalID = id
        case .resumed(let id):
            terminalID = id
        case .rejected:
            return .launchRejected
        }
        guard let route = resolveAgentRecoveryTerminal(
            terminalID,
            in: manager
        ), manager.terminal.activateTerminal(
            paneID: PaneID(id: route.paneID),
            tabID: route.tabID
        ) else { return .launchRejected }

        if let activateApplication {
            activateApplication(manager)
        } else if let window = manager.dialogOwnerWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return switch result {
        case .openedNewSession: .openedNewSession(terminalID: terminalID)
        case .resumed: .resumed(terminalID: terminalID)
        case .rejected: .launchRejected
        }
    }

    /// Resolves and presents one exact Inbox project without exposing an
    /// intermediate logically-open state. The presentation requirement is
    /// captured before retained-manager lookup, because ordinary lookup is a
    /// reopening mutation. Success commits availability once an eligible
    /// owner exists; cancellation or failure restores the background state.
    private func ensureAgentInboxProjectPresented(
        _ task: AgentTask,
        at projectURL: URL,
        openProjectWindow: @escaping @MainActor (URL) -> Void,
        waitUntilPresented: (@MainActor (ProjectManager) async -> Bool)?
    ) async -> AgentInboxPresentationAuthorization? {
        // Canonicalization suspends the caller. Revalidate the value snapshot
        // before retained lookup can admit/background a manager or disturb a
        // window that another operation opened while that await was pending.
        let canonicalProjectIdentityURL = canonicalProjectURL(URL(
            fileURLWithPath: task.project.canonicalProjectPath,
            isDirectory: true
        ))
        guard !Task.isCancelled,
              agentTasks.task(for: task.id) == task,
              projectURL.path == task.project.canonicalWorktreePath,
              canonicalProjectIdentityURL.path
                == task.project.canonicalProjectPath else {
            return nil
        }
        // Even an already-retained background manager must cross the same
        // repository-instance validation boundary. Path equality alone cannot
        // resume A after its repository/worktree paths were replaced by B.
        guard let manager = await projectManager(
            for: task.project,
            reopenBackgroundProject: false,
            admitMissingProjectInBackground: true
        ), manager.rootURL == projectURL,
            agentTasks.task(for: task.id) == task,
            agentTaskProjectsByRoot[projectURL] == task.project else {
            return nil
        }
        let hasEligibleCurrentOwner = manager.dialogOwnerWindow.map {
            DialogPresenter.isEligibleApplicationOwner($0)
        } == true
        let requiresPresentation = backgroundProjects.contains(projectURL)
            || !isWindowOpen(projectURL)
            || !hasEligibleCurrentOwner
        let operationID = UUID()
        agentInboxPresentationOperations[projectURL] = operationID
        guard let presentationLease = retainBackgroundProjectForPresentation(
            projectURL,
            manager: manager
        ) else {
            if agentInboxPresentationOperations[projectURL] == operationID {
                agentInboxPresentationOperations[projectURL] = nil
            }
            return nil
        }
        var transfersAuthorization = false
        defer {
            if !transfersAuthorization {
                releaseBackgroundProjectPresentation(
                    presentationLease,
                    for: projectURL
                )
                if agentInboxPresentationOperations[projectURL] == operationID {
                    agentInboxPresentationOperations[projectURL] = nil
                }
            }
        }

        if requiresPresentation {
            guard !Task.isCancelled,
                  agentTasks.task(for: task.id) == task,
                  openProjects[projectURL] === manager,
                  agentTaskProjectsByRoot[projectURL] == task.project else {
                return nil
            }
            // A previously unknown durable project is admitted by lookup but
            // still has no window. Keep that new manager transactional too.
            manager.prepareForWindowPresentation()
            guard await routeToWindow(
                projectURL,
                task: task,
                manager: manager,
                openProjectWindow: openProjectWindow
            ) else { return nil }
        }
        let presentationReported: Bool
        if let waitUntilPresented {
            presentationReported = await waitUntilPresented(manager)
        } else {
            presentationReported = await manager.awaitDialogOwnerWindow() != nil
        }
        guard presentationReported,
              !Task.isCancelled,
              agentInboxPresentationOperations[projectURL] == operationID,
              openProjects[projectURL] === manager,
              agentTaskProjectsByRoot[projectURL] == task.project,
              let ownerWindow = manager.dialogOwnerWindow,
              DialogPresenter.isEligibleApplicationOwner(ownerWindow) else {
            if requiresPresentation,
               backgroundProjects.contains(projectURL),
               agentInboxPresentationOperations[projectURL] == operationID {
                closeProjectWindow(
                    projectURL,
                    expectedManager: manager,
                    expectedWindowGeneration:
                        manager.dialogOwnerWindowGeneration
                )
            }
            return nil
        }
        guard await manager.revalidateAgentTaskFilesystemAdmission(
            expectedIdentity: task.project,
            workingDirectory: projectURL
        ) else { return nil }
        guard markProjectWindowOpen(
            projectURL,
            identity: task.project,
            manager: manager
        ) else {
            return nil
        }
        let authorization = AgentInboxPresentationAuthorization(
            projectURL: projectURL,
            projectIdentity: task.project,
            manager: manager,
            operationID: operationID,
            leaseID: presentationLease,
            ownerWindow: ownerWindow,
            ownerWindowGeneration: manager.dialogOwnerWindowGeneration
        )
        transfersAuthorization = true
        return authorization
    }

    /// Puts one Inbox project on screen, and reports whether the caller's
    /// transaction survived doing so.
    ///
    /// Multi-project windows are why this is not a bare `openProjectWindow`.
    /// A project sitting behind its neighbour in an existing window is
    /// suspended, so `isWindowOpen` reports no window at all and the direct
    /// path opens a second one — the Inbox spawning windows for projects that
    /// were open the whole time. Ask the windows first: whichever one owns the
    /// project switches to it, and opening its *scene* URL raises that window
    /// instead of creating another.
    ///
    /// A project no window owns goes to the key window, for the same reason a
    /// user opened several projects in one window to begin with. Only when
    /// there is no window at all does this fall back to opening one.
    private func routeToWindow(
        _ projectURL: URL,
        task: AgentTask,
        manager: ProjectManager,
        openProjectWindow: @escaping @MainActor (URL) -> Void
    ) async -> Bool {
        if let session = windowSession(owning: projectURL) {
            await session.activate(projectURL, registry: self)
            guard agentInboxTransactionHolds(
                projectURL,
                task: task,
                manager: manager
            ) else { return false }
            openProjectWindow(session.sceneProjectURL)
            return true
        }

        if let session = keyWindowSession() {
            await session.openProject(
                projectURL,
                registry: self,
                allowAlreadyOpenTarget: true
            )
            guard agentInboxTransactionHolds(
                projectURL,
                task: task,
                manager: manager
            ) else { return false }
            // The window can refuse — the directory may have gone missing
            // between admission and here, and the session drops targets it
            // cannot activate. Only claim the window if it took the project.
            if session.contains(canonicalProjectURL(projectURL)) {
                openProjectWindow(session.sceneProjectURL)
                return true
            }
        }

        closeProjectWindow(
            projectURL,
            expectedManager: manager,
            expectedWindowGeneration: nil
        )
        openProjectWindow(projectURL)
        return true
    }

    /// What must still hold after routing suspends: the project binding and
    /// the manager this presentation authorized are the ones in effect.
    ///
    /// Deliberately not the task value. Presenting a project marks its window
    /// open, which rewrites the very task being routed to — comparing against
    /// the pre-presentation snapshot would reject every success. Task freshness
    /// is re-established by the caller after presentation, against the route it
    /// is about to focus.
    private func agentInboxTransactionHolds(
        _ projectURL: URL,
        task: AgentTask,
        manager: ProjectManager
    ) -> Bool {
        !Task.isCancelled
            && openProjects[projectURL] === manager
            && agentTaskProjectsByRoot[projectURL] == task.project
    }

    private func presentationIsCurrent(
        _ authorization: AgentInboxPresentationAuthorization
    ) -> Bool {
        !Task.isCancelled
            && agentInboxPresentationOperations[authorization.projectURL]
                == authorization.operationID
            && openProjects[authorization.projectURL]
                === authorization.manager
            && agentTaskProjectsByRoot[authorization.projectURL]
                == authorization.projectIdentity
            && !backgroundProjects.contains(authorization.projectURL)
            && authorization.manager.presentationLifecycle == .visible
            && authorization.manager.dialogOwnerWindow
                === authorization.ownerWindow
            && authorization.manager.dialogOwnerWindowGeneration
                == authorization.ownerWindowGeneration
            && DialogPresenter.isEligibleApplicationOwner(
                authorization.ownerWindow
            )
    }

    private func finishAgentInboxPresentation(
        _ authorization: AgentInboxPresentationAuthorization
    ) {
        releaseBackgroundProjectPresentation(
            authorization.leaseID,
            for: authorization.projectURL
        )
        if agentInboxPresentationOperations[authorization.projectURL]
                == authorization.operationID {
            agentInboxPresentationOperations[authorization.projectURL] = nil
        }
    }

    private func resolveAgentRecoveryTerminal(
        _ terminalID: UUID,
        in manager: ProjectManager
    ) -> AgentTaskRoute? {
        var routes: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard manager.paneManager.terminalState(for: paneID)?
                .terminalTabs.contains(where: { $0.id == terminalID }) == true else {
                continue
            }
            routes.append(AgentTaskRoute(
                paneID: paneID.id,
                tabID: terminalID,
                terminalID: terminalID
            ))
        }
        return routes.count == 1 ? routes[0] : nil
    }

    private func matches(
        _ task: AgentTask,
        _ expected: AgentNotificationRouteIdentity?
    ) -> Bool {
        guard let expected else { return true }
        guard task.id == expected.taskID,
              let run = task.runs.last else { return false }
        return run.id == expected.runID
            && run.process.processGeneration == expected.processGeneration
    }

    private func resolvePausedAgentTaskRoute(
        _ task: AgentTask,
        targetTerminalID: UUID
    ) async -> AgentTaskRoute? {
        guard task.route.surface == .projectWindow else { return nil }
        let rawURL = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        )
        let projectURL = await agentInboxProjectCanonicalizer(rawURL)
        guard let currentTask = agentTasks.task(for: task.id),
              currentTask == task,
              agentTasks.canResumeTask(task.id),
              !backgroundProjects.contains(projectURL),
              let manager = openProjects[projectURL],
              agentTaskProjectsByRoot[projectURL] == task.project,
              manager.rootURL == projectURL,
              projectURL.path == task.project.canonicalWorktreePath else {
            return nil
        }

        var matches: [AgentTaskRoute] = []
        for paneID in manager.paneManager.terminalPaneIDs {
            guard let state = manager.paneManager.terminalState(for: paneID) else {
                continue
            }
            for tab in state.terminalTabs where tab.id == targetTerminalID {
                matches.append(AgentTaskRoute(
                    paneID: paneID.id,
                    tabID: tab.id,
                    terminalID: tab.id
                ))
            }
        }
        guard matches.count == 1,
              agentTasks.task(for: task.id) == currentTask else {
            return nil
        }
        return matches[0]
    }

    func freezeAgentTasksForTermination() {
        isProjectAdmissionFrozenForTermination = true
        backgroundReclamationTask?.cancel()
        backgroundReclamationTask = nil
        for manager in openProjects.values {
            manager.terminal.freezeAgentTasksForTermination()
        }
        for manager in detachedTaskCleanupProjects.values {
            manager.terminal.freezeAgentTasksForTermination()
        }
    }

    func freezeAutoSaveForTermination() {
        guard !isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = true
        // This is the first mutation in the Quit transaction, before human
        // decisions and inventory capture. Freeze reclamation here so that
        // captured project/tab ownership cannot disappear mid-handshake.
        backgroundReclamationTask?.cancel()
        backgroundReclamationTask = nil
        openProjects.values.forEach { $0.freezeAutoSaveForTermination() }
        detachedTaskCleanupProjects.values.forEach {
            $0.freezeAutoSaveForTermination()
        }
    }

    func captureApplicationTerminationSaveInventory(
        allowingSaveAs destinationsByTabID: [UUID: URL]
    ) -> TerminationSaveInventoryAuthorization {
        let projectsByRoot = openProjects.mapValues(ObjectIdentifier.init)
        return TerminationSaveInventoryAuthorization(
            projectsByRoot: projectsByRoot,
            tabsByProject: Dictionary(uniqueKeysWithValues: openProjects
                .values.map { projectManager in
                    (
                        ObjectIdentifier(projectManager),
                        projectManager.captureTerminationOpenTabInventory(
                            allowingSaveAs: destinationsByTabID
                        )
                    )
                })
        )
    }

    func applicationTerminationSaveInventoryStillMatches(
        _ authorization: TerminationSaveInventoryAuthorization
    ) -> Bool {
        guard openProjects.mapValues(ObjectIdentifier.init)
                == authorization.projectsByRoot else {
            return false
        }
        return openProjects.values.allSatisfy { projectManager in
            guard let inventory = authorization.tabsByProject[
                ObjectIdentifier(projectManager)
            ] else {
                return false
            }
            return projectManager.terminationOpenTabInventoryStillMatches(
                inventory
            )
        }
    }

    func cancelAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        openProjects.values.forEach {
            $0.cancelAutoSaveTerminationFreeze()
        }
        detachedTaskCleanupProjects.values.forEach {
            $0.cancelAutoSaveTerminationFreeze()
        }
        scheduleBackgroundReclamationIfNeeded()
    }

    func finishAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        openProjects.values.forEach {
            $0.finishAutoSaveTerminationFreeze()
        }
        detachedTaskCleanupProjects.values.forEach {
            $0.finishAutoSaveTerminationFreeze()
        }
    }

    @discardableResult
    func cancelAgentTaskTermination(
        maximumDuration: Duration? = nil
    ) async -> Bool {
        let windowOpenByProject = Dictionary(
            agentTaskProjectsByRoot.map { url, identity in
                (identity, !backgroundProjects.contains(url))
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let rollbackWasSaved = await agentTasks
            .cancelApplicationTerminationAndFlush(
                reconcilingWindowOpen: windowOpenByProject,
                maximumDuration: maximumDuration
            )
        for (url, manager) in openProjects {
            let isWindowOpen = !backgroundProjects.contains(url)
            manager.terminal.setAgentTaskWindowOpen(isWindowOpen)
            manager.terminal.cancelAgentTaskTermination()
        }
        for manager in detachedTaskCleanupProjects.values {
            manager.terminal.cancelAgentTaskTermination()
        }
        isProjectAdmissionFrozenForTermination = false
        scheduleBackgroundReclamationIfNeeded()
        return rollbackWasSaved
    }

    @discardableResult
    func cancelAgentTaskTermination(
        until deadline: DispatchTime
    ) async -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining: Duration = if now < deadline.uptimeNanoseconds {
            .nanoseconds(
                Int64(clamping: deadline.uptimeNanoseconds - now)
            )
        } else {
            .zero
        }
        return await cancelAgentTaskTermination(
            maximumDuration: remaining
        )
    }

    /// Whether any open or detached project still owns a user-task execution.
    /// Application termination uses this for its aggregated preflight and
    /// final revalidation. Only an explicit Quit Anyway decision authorizes
    /// bounded TERM/KILL cleanup before project ownership is destroyed.
    var hasOutstandingUserTaskExecution: Bool {
        userTaskOwners.contains { $0.hasOutstandingUserTaskExecution }
    }

    func captureUserTaskShutdownAuthorization()
        -> UserTaskShutdownAuthorization {
        UserTaskShutdownAuthorization(byOwner: Dictionary(
            uniqueKeysWithValues: userTaskOwners.map { projectManager in
                (
                    ObjectIdentifier(projectManager),
                    projectManager.captureUserTaskShutdownAuthorization()
                )
            }
        ))
    }

    func userTaskShutdownAuthorizationStillCovers(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        userTaskOwners.allSatisfy { projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownAuthorizationStillCovers(
                captured
            )
        }
    }

    /// Cancels and waits for all project-owned user tasks against one shared
    /// absolute deadline. Blocking process waits happen off the main actor.
    @discardableResult
    func shutdownUserTasks(
        authorizedBy authorization: UserTaskShutdownAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        // Snapshot before the first suspension point. Main-actor reentrancy may
        // otherwise mutate the registry while an iterator is held across an
        // `await`.
        let projectManagers = userTaskOwners
        guard projectManagers.allSatisfy({ projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownAuthorizationStillCovers(
                captured
            )
        }) else {
            return false
        }
        for projectManager in projectManagers {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            guard projectManager.requestUserTaskShutdown(
                authorizedBy: captured
            ) else {
                return false
            }
        }
        var allCompleted = true
        for projectManager in projectManagers {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            let didComplete = await projectManager.waitForUserTaskShutdown(
                authorizedBy: captured,
                until: deadline
            )
            allCompleted = allCompleted && didComplete
        }

        // Waiting is only the prepare phase. Revalidate every original owner
        // and every owner admitted during a suspension before clearing any
        // store, so one later timeout or launch cannot erase an earlier
        // owner's runs and output when application shutdown rolls back.
        guard allCompleted,
              projectManagers.allSatisfy({ projectManager in
                  let captured = authorization.byOwner[
                      ObjectIdentifier(projectManager)
                  ] ?? UserTaskExecutionAuthorization()
                  return projectManager
                      .userTaskShutdownIsPreparedForCommit(
                          authorizedBy: captured
                      )
              }),
              userTaskShutdownAuthorizationStillCovers(authorization) else {
            return false
        }

        // Application Quit performs its final dirty/terminal authorization
        // recheck after this prepare phase. It commits every prepared store
        // only after that global check succeeds.
        return true
    }

    func userTaskShutdownIsPreparedForCommit(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        userTaskOwners.allSatisfy { projectManager in
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            return projectManager.userTaskShutdownIsPreparedForCommit(
                authorizedBy: captured
            )
        } && userTaskShutdownAuthorizationStillCovers(authorization)
    }

    @discardableResult
    func commitPreparedUserTaskShutdown(
        _ authorization: UserTaskShutdownAuthorization
    ) -> Bool {
        guard userTaskShutdownIsPreparedForCommit(authorization) else {
            return false
        }
        // No suspension is allowed between the aggregate preflight above and
        // the last commit below. Main-actor isolation makes this one global
        // commit boundary for all prepared project stores.
        for projectManager in userTaskOwners {
            let captured = authorization.byOwner[
                ObjectIdentifier(projectManager)
            ] ?? UserTaskExecutionAuthorization()
            projectManager.commitPreparedUserTaskShutdown(
                authorizedBy: captured
            )
        }
        detachedTaskCleanupProjects = detachedTaskCleanupProjects.filter {
            $0.value.hasOutstandingUserTaskExecution
        }
        return !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        })
    }

    /// Legacy project-teardown entry point. Its snapshot is captured at the
    /// call boundary, so it cannot cancel executions created after an await.
    @discardableResult
    func shutdownUserTasks(until deadline: DispatchTime) async -> Bool {
        let authorization = captureUserTaskShutdownAuthorization()
        guard await shutdownUserTasks(
            authorizedBy: authorization,
            until: deadline
        ) else { return false }
        return commitPreparedUserTaskShutdown(authorization)
    }

    /// Fully destroys all project managers after task cleanup has completed.
    ///
    /// Fails closed instead of discarding cancellation handles if a caller
    /// attempts teardown while any user-task execution is still owned.
    @discardableResult
    func destroyAllProjects() -> Bool {
        guard !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        }) else {
            for projectManager in userTaskOwners {
                projectManager.requestUserTaskShutdown()
            }
            return false
        }

        lspSettingsChangeTask?.cancel()
        lspSettingsChangeTask = nil
        backgroundReclamationTask?.cancel()
        backgroundReclamationTask = nil
        backgroundReclamationQueue.removeAll()
        backgroundReclamationQueuedURLs.removeAll()
        backgroundReclamationCycleRemaining = 0
        backgroundPresentationLeases.removeAll()
        agentInboxPresentationOperations.removeAll()
        for (_, pm) in openProjects {
            pm.terminal.terminateAll()
            pm.shutdownReclaimableProject()
        }
        openProjects.removeAll()
        agentTaskProjectsByRoot.removeAll()
        agentTaskRepositoryProofsByRoot.removeAll()
        backgroundProjects.removeAll()
        detachedTaskCleanupProjects.removeAll()
        return true
    }

    /// Internal lifecycle observability used by unit tests.
    var detachedUserTaskCleanupCount: Int {
        detachedTaskCleanupProjects.count
    }

    /// Returns true if the project has an open (non-background) window.
    func isWindowOpen(_ url: URL) -> Bool {
        let canonical = canonicalProjectURL(url)
        return openProjects[canonical] != nil && !backgroundProjects.contains(canonical)
    }

    // MARK: - Window sessions

    /// Announces a window session while its scene is alive. Idempotent: SwiftUI
    /// re-runs a scene's task on restoration, and the same session must not be
    /// counted twice.
    func registerWindowSession(_ session: ProjectWindowSession) {
        compactWindowSessions()
        guard !windowSessionRefs.contains(where: { $0.session === session })
        else { return }
        windowSessionRefs.append(WeakWindowSession(session: session))
    }

    func unregisterWindowSession(_ session: ProjectWindowSession) {
        windowSessionRefs.removeAll {
            $0.session == nil || $0.session === session
        }
        if keyWindowSessionRef === session {
            keyWindowSessionRef = nil
        }
    }

    /// Records the window the user is looking at. Called when a project scene
    /// becomes key, which is the only evidence of "current window" that does
    /// not depend on AppKit window ordering being settled.
    func noteKeyWindowSession(_ session: ProjectWindowSession) {
        registerWindowSession(session)
        keyWindowSessionRef = session
    }

    /// The window holding `url`, if any — including as an agent worktree.
    ///
    /// A project belongs to at most one window: ``ProjectWindowSession``
    /// refuses to open a project another window already shows, so the first
    /// match is the only match.
    func windowSession(owning url: URL) -> ProjectWindowSession? {
        let canonical = canonicalProjectURL(url)
        compactWindowSessions()
        return windowSessionRefs.lazy
            .compactMap(\.session)
            .first { $0.contains(canonical) }
    }

    /// The window a project with no window of its own should open into.
    ///
    /// Falls back to the most recently registered live session when nothing
    /// has been key yet — at launch the first window may be routed to before
    /// it ever reports key, and putting the project there still beats opening
    /// a second window.
    func keyWindowSession() -> ProjectWindowSession? {
        compactWindowSessions()
        if let keyWindowSessionRef { return keyWindowSessionRef }
        return windowSessionRefs.last?.session
    }

    private func compactWindowSessions() {
        windowSessionRefs.removeAll { $0.session == nil }
    }

    /// Repairs a retained manager when AppKit makes its SwiftUI project scene
    /// key without replaying the normal Open Recent admission path. This can
    /// happen when window restoration reuses a WindowGroup scene after an
    /// earlier close callback suspended editor-only services.
    @discardableResult
    func reconcileKeyProjectPresentation(
        _ projectManager: ProjectManager
    ) -> Bool {
        guard let rootURL = projectManager.rootURL else { return false }
        let canonical = canonicalProjectURL(rootURL)
        guard openProjects[canonical] === projectManager,
              let identity = agentTaskProjectsByRoot[canonical] else {
            return false
        }
        guard backgroundProjects.contains(canonical) else {
            return projectManager.presentationLifecycle == .visible
        }
        return markProjectWindowOpen(
            canonical,
            identity: identity,
            manager: projectManager
        )
    }

    /// Checks if a project is already open (including background).
    func isProjectOpen(_ url: URL) -> Bool {
        openProjects[canonicalProjectURL(url)] != nil
    }

    // MARK: - Agent Inbox

    /// Number of durable agent tasks currently in the Agent Inbox's
    /// "needs attention" section, scoped to one open project window. Drives
    /// the per-project toolbar badge (#1337).
    ///
    /// Returns 0 for unknown/closed projects and for projects with no tasks
    /// awaiting input. Reads the cache maintained by
    /// ``recomputeAgentInboxAttentionCounts(tasks:)``, so this is O(1) and safe
    /// to call from a view body. Per-project scoping (rather than a global
    /// count) keeps sibling project windows from showing each other's
    /// attention counts; a global dock-tile badge is a follow-up.
    func agentInboxAttentionCount(for projectURL: URL) -> Int {
        agentInboxAttentionCounts[canonicalProjectURL(projectURL)] ?? 0
    }

    /// Rebuilds ``agentInboxAttentionCounts`` from a durable task snapshot.
    ///
    /// Called once per task mutation and once per project open/close, never
    /// from a view body. Reuses ``AgentInboxSnapshot`` so the badge always
    /// agrees with the `needsAttention` section the Inbox renders, and groups
    /// rows by project identity so all open windows are updated in a single
    /// O(rows + windows) pass rather than one filter per window.
    private func recomputeAgentInboxAttentionCounts(
        tasks: [AgentTask]? = nil
    ) {
        let tasks = tasks ?? agentTasks.tasks
        var counts: [URL: Int] = [:]
        defer {
            // Assigning an equal value still fires an observation transaction,
            // which would invalidate every project window's root view on any
            // task mutation. Durable tasks churn far more often than the
            // attention count moves, so only publish real changes.
            if agentInboxAttentionCounts != counts {
                agentInboxAttentionCounts = counts
            }
        }
        guard !tasks.isEmpty, !agentTaskProjectsByRoot.isEmpty else { return }
        let snapshot = AgentInboxSnapshot(
            tasks: tasks,
            accuracyPolicy: agentTasks.lifecycleAccuracyPolicy
        )
        guard let needsAttention = snapshot.sections.first(where: {
            $0.id == .needsAttention
        }) else { return }
        // Rows in this section are needs-attention by construction, so only
        // the per-project grouping remains.
        var countsByIdentity: [AgentTaskProjectIdentity: Int] = [:]
        for row in needsAttention.rows {
            let identity = AgentTaskProjectIdentity(
                canonicalProjectPath: row.projectPath,
                canonicalWorktreePath: row.worktreePath
            )
            countsByIdentity[identity, default: 0] += 1
        }
        for (url, identity) in agentTaskProjectsByRoot {
            guard let count = countsByIdentity[identity] else { continue }
            counts[url] = count
        }
    }

    // MARK: - Language Server Settings

    func lspSettingsDidChange(_ change: LSPSettingsChange) {
        let previous = lspSettingsChangeTask
        lspSettingsChangeTask = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            let projectManagers = Array(self.openProjects.values)
            for projectManager in projectManagers {
                guard !Task.isCancelled else { return }
                await projectManager.lspManager.applySettingsChange(change)
            }
        }
    }

    /// Test synchronization point for asynchronous graceful restarts.
    func waitForLSPSettingsChanges() async {
        await lspSettingsChangeTask?.value
    }

    // MARK: - Recent Projects

    /// Shared title for File > Open Recent and the Dock menu. Including the
    /// abbreviated full path keeps equal project basenames distinguishable.
    static func recentProjectDisplayTitle(for url: URL) -> String {
        "\(url.lastPathComponent) — \(url.abbreviatedPath)"
    }

    /// Removes a single project from the recent projects list.
    func removeFromRecent(_ url: URL) {
        let canonical = canonicalProjectURL(url)
        recentProjects.removeAll { $0 == canonical }
        removeRecentAgentTaskRecord(for: canonical)
        saveRecentProjects()
    }

    /// Removes every recent project from all app surfaces (File menu,
    /// Welcome, and Dock menu) through the registry's single shared source.
    func clearRecentProjects() {
        recentProjects.removeAll()
        if !recentAgentTaskProjectsByRoot.isEmpty {
            recentAgentTaskProjectsByRoot.removeAll()
            recentAgentTaskRecordsGeneration = UUID()
        }
        saveRecentProjects()
    }

    private func addToRecent(
        _ url: URL,
        identity: AgentTaskProjectIdentity
    ) {
        // Every caller has already resolved the registry key. Avoid repeating
        // filesystem canonicalization on MainActor at the admission commit.
        let canonical = url.standardizedFileURL
        recentProjects.removeAll { $0 == canonical }
        recentProjects.insert(canonical, at: 0)
        let retainedProof: RecentAgentTaskRepositoryProof? = if let liveProof =
            agentTaskRepositoryProofsByRoot[canonical] {
            liveProof
        } else if recentAgentTaskProjectsByRoot[canonical]?.identity
                    == identity {
            recentAgentTaskProjectsByRoot[canonical]?.repositoryProof
        } else {
            nil
        }
        recentAgentTaskProjectsByRoot[canonical] =
            RecentAgentTaskProjectRecord(
                identity: identity,
                repositoryProof: retainedProof
            )
        if recentProjects.count > Self.maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(Self.maxRecentProjects))
        }
        recentAgentTaskProjectsByRoot = recentAgentTaskProjectsByRoot.filter {
            recentProjects.contains($0.key)
        }
        recentAgentTaskRecordsGeneration = UUID()
        saveRecentProjects()
    }

    private func loadRecentProjects() {
        guard let paths = defaults.stringArray(forKey: Self.recentProjectsKey) else {
            return
        }
        var seen: Set<URL> = []
        recentProjects = paths.compactMap { path in
            let canonical = canonicalProjectURL(
                URL(fileURLWithPath: path)
            )
            var isDir: ObjCBool = false
            guard fileManager.fileExists(
                atPath: canonical.path,
                isDirectory: &isDir
            ),
            isDir.boolValue,
            seen.insert(canonical).inserted else {
                return nil
            }
            return canonical
        }
        recentProjects = Array(recentProjects.prefix(Self.maxRecentProjects))
        loadRecentAgentTaskProjectIdentities()
        if paths != recentProjects.map(\.path) {
            saveRecentProjects()
        }
    }

    private func saveRecentProjects() {
        let paths = recentProjects.map(\.path)
        defaults.set(paths, forKey: Self.recentProjectsKey)
        let records = recentProjects.compactMap {
            recentAgentTaskProjectsByRoot[$0]
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.recentProjectAgentIdentitiesKey)
        }
    }

    private func loadRecentAgentTaskProjectIdentities() {
        guard let data = defaults.data(
            forKey: Self.recentProjectAgentIdentitiesKey
        ), let records = try? JSONDecoder().decode(
            [RecentAgentTaskProjectRecord].self,
            from: data
        ) else {
            recentAgentTaskProjectsByRoot = [:]
            recentAgentTaskRecordsGeneration = UUID()
            return
        }
        let recentByPath = Dictionary(
            uniqueKeysWithValues: recentProjects.map { ($0.path, $0) }
        )
        recentAgentTaskProjectsByRoot = records.reduce(into: [:]) { result, record in
            let identity = record.identity
            let project = URL(
                fileURLWithPath: identity.canonicalProjectPath,
                isDirectory: true
            ).standardizedFileURL
            let worktree = URL(
                fileURLWithPath: identity.canonicalWorktreePath,
                isDirectory: true
            ).standardizedFileURL
            guard project.path == identity.canonicalProjectPath,
                  worktree.path == identity.canonicalWorktreePath,
                  let canonical = recentByPath[worktree.path],
                  result[canonical] == nil,
                  project == worktree || record.repositoryProof != nil else {
                return
            }
            result[canonical] = record
        }
        recentAgentTaskRecordsGeneration = UUID()
    }

    private func removeRecentAgentTaskRecord(for canonical: URL) {
        guard recentAgentTaskProjectsByRoot.removeValue(
            forKey: canonical
        ) != nil else { return }
        recentAgentTaskRecordsGeneration = UUID()
    }

    #if DEBUG
    nonisolated static func unsignedFilesystemIdentityForTesting(
        _ value: Int64
    ) -> UInt64 {
        unsignedFilesystemIdentity(value)
    }

    nonisolated static func filesystemIdentityMatchesForTesting(
        leftGeneration: UInt64,
        rightGeneration: UInt64
    ) -> Bool {
        let left = StableFilesystemObjectIdentity(
            device: 1,
            inode: 2,
            generation: leftGeneration,
            birthSeconds: 3,
            birthNanoseconds: 4,
            kind: S_IFREG
        )
        let right = StableFilesystemObjectIdentity(
            device: 1,
            inode: 2,
            generation: rightGeneration,
            birthSeconds: 3,
            birthNanoseconds: 4,
            kind: S_IFREG
        )
        return left == right
    }

    nonisolated static func boundedGitPathFileForTesting(
        _ url: URL,
        beforeRead: @escaping () -> Void
    ) -> String? {
        RecentAgentTaskFilesystemValidator.boundedGitPathFile(
            url,
            beforeRead: beforeRead
        )
    }
    #endif

    func canonicalProjectURL(_ projectURL: URL) -> URL {
        Self.canonicalProjectURL(projectURL)
    }

    /// Resolves a stable project identity even after the project directory is
    /// deleted. `resolvingSymlinksInPath()` requires the path to exist before
    /// it reliably resolves prefix symlinks such as `/var` → `/private/var`.
    /// Resolve the nearest existing ancestor, then append every missing
    /// component to preserve the key previously stored in `openProjects`.
    nonisolated static func canonicalProjectURL(_ projectURL: URL) -> URL {
        let standardized = projectURL.standardizedFileURL
        var existingAncestor = standardized
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(
            atPath: existingAncestor.path
        ) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return URL(
            fileURLWithPath: canonical.path,
            isDirectory: true
        ).standardizedFileURL
    }

    private var userTaskOwners: [ProjectManager] {
        var owners: [ObjectIdentifier: ProjectManager] =
            detachedTaskCleanupProjects
        for projectManager in openProjects.values {
            owners[ObjectIdentifier(projectManager)] = projectManager
        }
        return Array(owners.values)
    }
}
