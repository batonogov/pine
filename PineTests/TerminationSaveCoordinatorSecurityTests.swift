//
//  TerminationSaveCoordinatorSecurityTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Termination Save Coordinator Security Tests", .serialized)
struct TerminationSaveCoordinatorSecurityTests {
    @Test func signedDeviceIdentityPreservesHighBitPattern() {
        let highBitDevice = dev_t(bitPattern: UInt32(0x8000_0000))

        #expect(
            TerminationSaveCoordinator.deviceIdentityBits(highBitDevice)
                == 0x8000_0000
        )
    }

    @Test func publicDestinationDoesNotWidenStagingBeforeInstall() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("public.txt")
        try Data("old public bytes".utf8).write(to: destination)
        #expect(Darwin.chmod(destination.path, mode_t(0o644)) == 0)

        let staged = try await stage(
            content: "private unsaved bytes",
            destination: destination
        )
        let status = try fileStatus(at: staged.stagingURL)
        #expect((status.st_mode & 0o7777) == 0o600)
        #expect(
            Set(try extendedAttributeNames(at: staged.stagingURL))
                .isSubset(of: ["com.apple.provenance"])
        )
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "old public bytes"
        )

        nonisolated(unsafe) var publicationWasPrivate = false
        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            afterDestinationPublication: {
                let live = try? fileStatus(at: destination)
                publicationWasPrivate = live.map {
                    ($0.st_mode & 0o7777) == 0o600
                } == true
                    && (try? String(
                        contentsOf: staged.stagingURL,
                        encoding: .utf8
                    )) == "old public bytes"
                    && (try? extendedACLText(at: destination)) == ""
            }
        )

        guard case .installed = result else {
            Issue.record("Expected existing destination install: \(result)")
            return
        }
        #expect(publicationWasPrivate)
    }

    @Test func missingDestinationMatchesNormalCreationMode() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let baseline = directory.appendingPathComponent("baseline.txt")
        try Data().write(to: baseline)
        let baselineMode = try fileStatus(at: baseline).st_mode & 0o7777
        let destination = directory.appendingPathComponent("new.txt")

        let staged = try await stage(
            content: "new private file",
            destination: destination
        )
        #expect((try fileStatus(at: staged.stagingURL).st_mode & 0o7777) == 0o600)

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5
        )

        guard case .installed = result else {
            Issue.record("Expected the missing destination to install: \(result)")
            return
        }
        #expect(
            (try fileStatus(at: destination).st_mode & 0o7777)
                == baselineMode
        )
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "new private file"
        )
    }

    @Test func missingDestinationPreservesInheritedDirectoryACL() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        try addInheritedReadACL(to: directory)
        let baseline = directory.appendingPathComponent("baseline.txt")
        try Data().write(to: baseline)
        let expectedACL = try extendedACLText(at: baseline)
        #expect(!expectedACL.isEmpty)

        let destination = directory.appendingPathComponent("new.txt")
        let staged = try await stage(
            content: "inherited policy",
            destination: destination
        )
        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5
        )

        guard case .installed = result else {
            Issue.record("Expected inherited-ACL install: \(result)")
            return
        }
        #expect(try extendedACLText(at: destination) == expectedACL)
    }

    @Test func existingDestinationPreservesOwnerModeAndXattrs() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("old bytes".utf8).write(to: destination)
        #expect(Darwin.chmod(destination.path, mode_t(0o640)) == 0)
        try setExtendedAttribute(
            at: destination,
            name: "com.pine.tests.preserved",
            value: Data("metadata".utf8)
        )
        let original = try fileStatus(at: destination)
        let staged = try await stage(
            content: "replacement bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5
        )

        guard case .installed = result else {
            Issue.record("Expected existing destination to install: \(result)")
            return
        }
        let installed = try fileStatus(at: destination)
        #expect(installed.st_uid == original.st_uid)
        #expect(installed.st_gid == original.st_gid)
        #expect((installed.st_mode & 0o7777) == 0o640)
        #expect(
            try extendedAttribute(
                at: destination,
                name: "com.pine.tests.preserved"
            ) == Data("metadata".utf8)
        )
    }

    @Test func restoredMtimeContentAndXattrRaceIsRejectedWithoutLoss() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("raced.txt")
        try Data("authorized".utf8).write(to: destination)
        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: destination.path)[
                .modificationDate
            ] as? Date
        )
        let staged = try await stage(
            content: "pine save!",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeDestinationQuarantine: {
                try? Data("externally".utf8).write(to: destination)
                try? setExtendedAttribute(
                    at: destination,
                    name: "com.pine.tests.raced",
                    value: Data("changed".utf8)
                )
                try? FileManager.default.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: destination.path
                )
            }
        )

        guard case .failed = result else {
            Issue.record("Expected the external change fence to reject the race")
            return
        }
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "externally"
        )
        #expect(
            try extendedAttribute(
                at: destination,
                name: "com.pine.tests.raced"
            ) == Data("changed".utf8)
        )
        #expect(TerminationSaveCoordinator.stagingIdentityIsCurrent(staged))
    }

    @Test func stagingCleanupFailureReturnsRetainedArtifact() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("cleanup.txt")
        let staged = try await stage(
            content: "still private",
            destination: destination
        )
        #expect(Darwin.chmod(directory.path, mode_t(0o500)) == 0)
        let result = TerminationSaveCoordinator.cleanup([staged])
        #expect(Darwin.chmod(directory.path, mode_t(0o700)) == 0)

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("Expected cleanup to return a typed failure")
            return
        }
        #expect(retainedArtifacts.contains(staged.stagingURL))
        #expect(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        #expect(TerminationSaveCoordinator.cleanup([staged]) == .cleaned)
    }

    @Test func cleanupTracksStagingDirectoryAcrossRename() async throws {
        let container = try makeDirectory()
        defer { remove(container) }
        let directory = container.appendingPathComponent("project")
        let movedDirectory = container.appendingPathComponent("project-moved")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let staged = try await stage(
            content: "private bytes in a moved directory",
            destination: directory.appendingPathComponent("moved.txt")
        )
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        #expect(TerminationSaveCoordinator.cleanup([staged]) == .cleaned)
        #expect(
            !FileManager.default.fileExists(
                atPath: movedDirectory.appendingPathComponent(
                    staged.stagingURL.lastPathComponent
                ).path
            )
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @Test func failedCleanupReportsArtifactInRenamedDirectory() async throws {
        let container = try makeDirectory()
        defer { remove(container) }
        let directory = container.appendingPathComponent("project")
        let movedDirectory = container.appendingPathComponent("project-moved")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let staged = try await stage(
            content: "private bytes retained after rename",
            destination: directory.appendingPathComponent("cleanup-moved.txt")
        )
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        #expect(Darwin.chmod(movedDirectory.path, mode_t(0o500)) == 0)
        let result = TerminationSaveCoordinator.cleanup([staged])
        #expect(Darwin.chmod(movedDirectory.path, mode_t(0o700)) == 0)

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("Expected cleanup failure in the renamed directory")
            return
        }
        let expectedArtifact = movedDirectory.appendingPathComponent(
            staged.stagingURL.lastPathComponent
        )
        #expect(
            retainedArtifacts.map { $0.resolvingSymlinksInPath() }
                == [expectedArtifact.resolvingSymlinksInPath()]
        )
        #expect(FileManager.default.fileExists(atPath: expectedArtifact.path))
        #expect(TerminationSaveCoordinator.cleanup([staged]) == .cleaned)
    }

    @Test func installedDestinationReportsRetainedRecoveryFailure() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("recovery.txt")
        try Data("authorized original".utf8).write(to: destination)
        let staged = try await stage(
            content: "installed new bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeRecoveryCleanup: {
                _ = Darwin.chmod(directory.path, mode_t(0o500))
            }
        )
        #expect(Darwin.chmod(directory.path, mode_t(0o700)) == 0)

        guard case .failed(let message, let retainedArtifacts) = result else {
            Issue.record("Expected recovery cleanup failure after install")
            return
        }
        #expect(message.contains(".pine-save-"))
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "installed new bytes"
        )
        let recovery = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".pine-save-") }
        let recoveryURL = try #require(recovery)
        #expect(
            retainedArtifacts.map { $0.resolvingSymlinksInPath() }
                == [recoveryURL.resolvingSymlinksInPath()]
        )
        #expect(
            try String(contentsOf: recoveryURL, encoding: .utf8)
                == "authorized original"
        )
    }

    @Test func movedParentDirectoryCannotProduceFalseInstalledResult() async throws {
        let container = try makeDirectory()
        defer { remove(container) }
        let directory = container.appendingPathComponent("project")
        let movedDirectory = container.appendingPathComponent("project-moved")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let destination = directory.appendingPathComponent("moved.txt")
        try Data("authorized original".utf8).write(to: destination)
        let staged = try await stage(
            content: "pine staged bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeDestinationQuarantine: {
                try? FileManager.default.moveItem(
                    at: directory,
                    to: movedDirectory
                )
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A moved parent must fail the installation")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        #expect(
            try String(
                contentsOf: movedDirectory.appendingPathComponent("moved.txt"),
                encoding: .utf8
            ) == "authorized original"
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func parentMovedAfterPublicationCannotProduceFalseInstalledResult() async throws {
        let container = try makeDirectory()
        defer { remove(container) }
        let directory = container.appendingPathComponent("project")
        let movedDirectory = container.appendingPathComponent("project-moved")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let destination = directory.appendingPathComponent("moved-late.txt")
        try Data("authorized original".utf8).write(to: destination)
        let staged = try await stage(
            content: "pine staged bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeRecoveryCleanup: {
                try? FileManager.default.moveItem(
                    at: directory,
                    to: movedDirectory
                )
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A late parent move must fail the installation")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        #expect(
            try String(
                contentsOf: movedDirectory.appendingPathComponent(
                    "moved-late.txt"
                ),
                encoding: .utf8
            ) == "authorized original"
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func publishedContentMutationIsNeverReportedInstalled() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("published.txt")
        try Data("authorized original".utf8).write(to: destination)
        let staged = try await stage(
            content: "pine staged bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            afterDestinationPublication: {
                let descriptor = Darwin.open(
                    destination.path,
                    O_WRONLY | O_TRUNC | O_CLOEXEC
                )
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                let bytes = Data("external replacement".utf8)
                _ = bytes.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A published-content mutation must fail closed")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "authorized original"
        )
        #expect(
            try String(contentsOf: staged.stagingURL, encoding: .utf8)
                == "external replacement"
        )
        #expect(
            (try fileStatus(at: staged.stagingURL).st_mode & 0o7777) == 0o600
        )
        #expect(try extendedACLText(at: staged.stagingURL) == "")
        #expect(
            Set(try extendedAttributeNames(at: staged.stagingURL))
                .isSubset(of: ["com.apple.provenance"])
        )
    }

    @Test func preCleanupContentMutationRollsBackPrivately() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("cleanup-raced.txt")
        try Data("authorized original".utf8).write(to: destination)
        #expect(Darwin.chmod(destination.path, mode_t(0o644)) == 0)
        try setExtendedAttribute(
            at: destination,
            name: "com.pine.tests.public",
            value: Data("public metadata".utf8)
        )
        let staged = try await stage(
            content: "pine staged bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeRecoveryCleanup: {
                let descriptor = Darwin.open(
                    destination.path,
                    O_WRONLY | O_TRUNC | O_CLOEXEC
                )
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                let bytes = Data("late external bytes".utf8)
                _ = bytes.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A pre-cleanup mutation must fail closed")
            return
        }
        #expect(retainedArtifacts.contains(staged.stagingURL))
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "authorized original"
        )
        #expect(
            try extendedAttribute(
                at: destination,
                name: "com.pine.tests.public"
            ) == Data("public metadata".utf8)
        )
        #expect(
            try String(contentsOf: staged.stagingURL, encoding: .utf8)
                == "late external bytes"
        )
        #expect(
            (try fileStatus(at: staged.stagingURL).st_mode & 0o7777) == 0o600
        )
        #expect(try extendedACLText(at: staged.stagingURL) == "")
        #expect(
            Set(try extendedAttributeNames(at: staged.stagingURL))
                .isSubset(of: ["com.apple.provenance"])
        )
    }

    @Test func postCleanupMutationFailsWithExactDestination() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("final-raced.txt")
        try Data("authorized original".utf8).write(to: destination)
        let staged = try await stage(
            content: "pine installed bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeFinalInstalledFence: {
                overwrite(destination, with: "post-cleanup external bytes")
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A post-cleanup mutation must not be reported installed")
            return
        }
        #expect(retainedArtifacts == [destination])
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "post-cleanup external bytes"
        )
        #expect(!FileManager.default.fileExists(atPath: staged.stagingURL.path))
    }

    @Test func displacedOriginalMutationIsRetainedInsteadOfDeleted() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("borrowed-fd.txt")
        try Data("authorized original".utf8).write(to: destination)
        let descriptor = Darwin.open(destination.path, O_RDWR | O_CLOEXEC)
        let liveDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { Darwin.close(liveDescriptor) }
        let staged = try await stage(
            content: "pine staged bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            afterDestinationPublication: {
                _ = Darwin.ftruncate(liveDescriptor, 0)
                _ = Data("external through old fd".utf8).withUnsafeBytes {
                    Darwin.write(liveDescriptor, $0.baseAddress, $0.count)
                }
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A displaced-original mutation must fail closed")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "external through old fd"
        )
        #expect(
            try String(contentsOf: staged.stagingURL, encoding: .utf8)
                == "pine staged bytes"
        )
    }

    @Test func newDestinationMutationFailsWithoutFalseCleanSuccess() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("new-raced.txt")
        let staged = try await stage(
            content: "pine new bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            afterDestinationPublication: {
                let descriptor = Darwin.open(
                    destination.path,
                    O_WRONLY | O_TRUNC | O_CLOEXEC
                )
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                let bytes = Data("external new bytes".utf8)
                _ = bytes.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A raced new destination must fail closed")
            return
        }
        #expect(!retainedArtifacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(
            try String(contentsOf: staged.stagingURL, encoding: .utf8)
                == "external new bytes"
        )
        #expect(
            (try fileStatus(at: staged.stagingURL).st_mode & 0o7777) == 0o600
        )
        #expect(try extendedACLText(at: staged.stagingURL) == "")
        #expect(
            Set(try extendedAttributeNames(at: staged.stagingURL))
                .isSubset(of: ["com.apple.provenance"])
        )
    }

    @Test func finalNewDestinationMutationReportsExactDestination() async throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let destination = directory.appendingPathComponent("new-final-raced.txt")
        let staged = try await stage(
            content: "pine new bytes",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeFinalInstalledFence: {
                overwrite(destination, with: "late external new bytes")
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A final new-file mutation must fail closed")
            return
        }
        #expect(retainedArtifacts == [destination])
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "late external new bytes"
        )
    }

    @Test func finalVerificationReportsDestinationAfterParentRename() async throws {
        let container = try makeDirectory()
        defer { remove(container) }
        let directory = container.appendingPathComponent("project")
        let movedDirectory = container.appendingPathComponent("project-moved")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let destination = directory.appendingPathComponent("new-moved.txt")
        let staged = try await stage(
            content: "installed before parent rename",
            destination: destination
        )

        let result = await TerminationSaveCoordinator.install(
            staged,
            until: .now() + 5,
            beforeFinalInstalledFence: {
                try? FileManager.default.moveItem(
                    at: directory,
                    to: movedDirectory
                )
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            }
        )

        guard case .failed(_, let retainedArtifacts) = result else {
            Issue.record("A renamed parent must fail final verification")
            return
        }
        let movedDestination = movedDirectory.appendingPathComponent(
            destination.lastPathComponent
        )
        #expect(
            retainedArtifacts.map { $0.resolvingSymlinksInPath() }
                == [movedDestination.resolvingSymlinksInPath()]
        )
        #expect(
            try String(contentsOf: movedDestination, encoding: .utf8)
                == "installed before parent rename"
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func stage(
        content: String,
        destination: URL
    ) async throws -> TerminationStagedSave {
        let state: TerminationDestinationState
        switch await TerminationSaveCoordinator.captureDestinationStates(
            at: [destination],
            until: .now() + 5
        ) {
        case .captured(let states):
            state = try #require(states.first)
        case .failed(let message):
            Issue.record("Could not capture destination: \(message)")
            throw CocoaError(.fileReadUnknown)
        case .timedOut:
            Issue.record("Destination capture timed out")
            throw CancellationError()
        }
        let request = TerminationSaveRequest(
            tabID: UUID(),
            contentVersion: 1,
            persistenceGeneration: 1,
            content: content,
            originalURL: state.exists ? destination : nil,
            destination: destination,
            expectedDestinationState: state,
            encodingRawValue: String.Encoding.utf8.rawValue,
            settings: EditorSaveSettingsSnapshot(
                insertFinalNewline: false,
                stripTrailingWhitespace: false,
                formatOnSave: false
            ),
            formatters: FileFormatterRegistry(formatters: [])
        )
        switch await TerminationSaveCoordinator.stage(
            [request],
            until: .now() + 5
        ) {
        case .ready(let staged):
            return try #require(staged.first)
        case .failed(let message, _):
            Issue.record("Could not stage save: \(message)")
            throw CocoaError(.fileWriteUnknown)
        case .timedOut:
            Issue.record("Staging timed out")
            throw CancellationError()
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTerminationSecurity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func remove(_ url: URL) {
        _ = Darwin.chmod(url.path, mode_t(0o700))
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status
    }

    nonisolated private func overwrite(_ url: URL, with content: String) {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_TRUNC | O_CLOEXEC
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Data(content.utf8).withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
    }

    private func extendedAttributeNames(at url: URL) throws -> [String] {
        let required = Darwin.listxattr(
            url.path,
            nil,
            0,
            XATTR_NOFOLLOW
        )
        guard required >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard required > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: required)
        let count = Darwin.listxattr(
            url.path,
            &bytes,
            bytes.count,
            XATTR_NOFOLLOW
        )
        guard count >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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

    nonisolated private func setExtendedAttribute(
        at url: URL,
        name: String,
        value: Data
    ) throws {
        let result = value.withUnsafeBytes { buffer in
            name.withCString {
                Darwin.setxattr(
                    url.path,
                    $0,
                    buffer.baseAddress,
                    buffer.count,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func extendedAttribute(at url: URL, name: String) throws -> Data {
        let required = name.withCString {
            Darwin.getxattr(url.path, $0, nil, 0, 0, XATTR_NOFOLLOW)
        }
        guard required >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var value = Data(count: required)
        let count = value.withUnsafeMutableBytes { buffer in
            name.withCString {
                Darwin.getxattr(
                    url.path,
                    $0,
                    buffer.baseAddress,
                    buffer.count,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
        guard count == required else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value
    }

    nonisolated private func addInheritedReadACL(to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = [
            "+a",
            "everyone allow read,file_inherit",
            directory.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    nonisolated private func extendedACLText(at url: URL) throws -> String {
        errno = 0
        guard let acl = Darwin.acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            guard errno == 0 || errno == ENOENT else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return ""
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = Darwin.acl_to_text(acl, &length) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(text)) }
        let bytes = UnsafeBufferPointer(
            start: text,
            count: Int(length)
        ).map { UInt8(bitPattern: $0) }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}
