import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("ClaudeCode ACP launch boundary")
struct ClaudeCodeACPLaunchTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pine-1727-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real Mach-O binary (copied system utility) for pure file-level
    /// identity checks. It is never executed here: restricted platform
    /// binaries are SIGKILLed by the system when run outside their canonical
    /// location, so exec-based assertions are out of scope for unit tests.
    private func copySystemBinary(into directory: URL) throws -> URL {
        let target = directory.appending(path: "fake-claude-code")
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: target.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    @Test func identityCapturesPinsAndDetectsExecutableChanges() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let identity = try await ClaudeCodeACPExecutableIdentity.capture(selectedURL: binary, deadline: deadline)
        #expect(!identity.sha256.isEmpty)
        #expect(identity.canonicalURL.lastPathComponent == "fake-claude-code")
        await #expect(throws: Never.self) {
            try await identity.revalidate(deadline: deadline)
        }
        try identity.validateMetadataSynchronously()
        // Metadata-only change (mtime + size) must refuse the pin.
        let handle = try FileHandle(forWritingTo: binary)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        await #expect(throws: ClaudeCodeACPLaunchError.changed) {
            try await identity.revalidate(deadline: deadline)
        }
        await #expect(throws: ClaudeCodeACPLaunchError.changed) {
            try identity.validateMetadataSynchronously()
        }
    }

    @Test func identityRejectsScriptsAndPinsTheVersionString() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        // The official standalone adapter is Mach-O; a shell script is refused.
        let script = directory.appending(path: "scripted-claude-code")
        try "#!/bin/sh\nprintf '\(ClaudeCodeACPExecutableIdentity.supportedVersion)'\n".write(
            toFile: script.path, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        await #expect(throws: ClaudeCodeACPLaunchError.unsupportedBinary) {
            _ = try await ClaudeCodeACPExecutableIdentity.capture(selectedURL: script, deadline: deadline)
        }
        // Version gate: the exact pinned string is accepted, anything else is
        // refused, and a failed probe is unavailable. Never executed for real:
        // a copied platform binary cannot run from a temp location.
        let binary = try copySystemBinary(into: directory)
        let identity = try await ClaudeCodeACPExecutableIdentity.capture(selectedURL: binary, deadline: deadline)
        let probeTimeout = Mutex(TimeInterval.zero)
        await #expect(throws: Never.self) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, arguments, _, timeout in
                probeTimeout.withLock { $0 = timeout }
                #expect(arguments == ["--version"])
                return (true, ClaudeCodeACPExecutableIdentity.supportedVersion)
            }
        }
        #expect(probeTimeout.withLock { $0 } == 5)
        #expect(ClaudeCodeACPExecutableIdentity.supportedVersion == "0.109.1")
        #expect(ClaudeCodeACPExecutableIdentity.acpArguments.isEmpty)
        await #expect(throws: ClaudeCodeACPLaunchError.unsupportedVersion) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, _, _, _ in
                (true, "0.109.2")
            }
        }
        await #expect(throws: ClaudeCodeACPLaunchError.unavailable) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, _, _, _ in
                (false, "")
            }
        }
    }

    @Test func launchRefusesUnboundWorkingDirectory() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let identity = try await ClaudeCodeACPExecutableIdentity.capture(
            selectedURL: binary, deadline: .now.advanced(by: .seconds(30))
        )
        let file = directory.appending(path: "not-a-directory")
        try Data().write(to: file)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        await #expect(throws: ClaudeCodeACPLaunchError.unavailable) {
            _ = try await ClaudeCodeACPLaunch.launch(
                executable: identity, workingDirectory: file,
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60))
            )
        }
        await #expect(throws: ClaudeCodeACPLaunchError.unavailable) {
            _ = try await ClaudeCodeACPLaunch.launch(
                executable: identity, workingDirectory: directory.appending(path: "missing"),
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60))
            )
        }
    }

    @Test func everyNonExitedSpawnPollTransfersReapingAndDeferredCleanup() async throws {
        for poll in [UserTaskProcessExitPoll.running, .waitFailed(Int32(ECHILD))] {
            let reaped = Mutex(false)
            let deferred = AsyncContinuationGate()
            ClaudeCodeACPNativeSpawner.transferFailedSpawn(
                poll: poll,
                groupIsAlive: { true },
                reap: {
                    reaped.withLock { $0 = true }
                    return UserTaskBackgroundReaper()
                },
                finishDeferredCleanup: { deferred.resolve() }
            )
            await deferred.wait()
            #expect(reaped.withLock { $0 })
        }
        let reaped = Mutex(false)
        ClaudeCodeACPNativeSpawner.transferFailedSpawn(
            poll: .exited(0), groupIsAlive: { false },
            reap: {
                reaped.withLock { $0 = true }
                return UserTaskBackgroundReaper()
            },
            finishDeferredCleanup: { Issue.record("Empty group must not enter deferred cleanup") }
        )
        #expect(!reaped.withLock { $0 })
        let deferred = AsyncContinuationGate()
        ClaudeCodeACPNativeSpawner.transferFailedSpawn(
            poll: .exited(0), groupIsAlive: { true },
            reap: {
                reaped.withLock { $0 = true }
                return UserTaskBackgroundReaper()
            },
            finishDeferredCleanup: { deferred.resolve() }
        )
        await deferred.wait()
        #expect(!reaped.withLock { $0 })
    }

    @Test func ownedChildReflectionDoesNotExposeBufferedWirePayload() throws {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading,
            requireJSONRPCVersion: true
        )
        let child = ClaudeCodeACPOwnedChild(
            channel: channel, close: { channel.close() }, stop: { _ in channel.close() }
        )
        let secret = "sk-buffered-SECRET-marker"
        try output.fileHandleForWriting.write(contentsOf: Data(secret.utf8))
        var diagnostic = ""
        dump(child, to: &diagnostic)
        #expect(!diagnostic.contains(secret))
        #expect(diagnostic.contains("<redacted:claude-code-owned-child>"))
        channel.close()
        output.fileHandleForWriting.closeFile()
        error.fileHandleForWriting.closeFile()
    }

    @Test func launchArgumentBoundsAreEnforced() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        await #expect(throws: ClaudeCodeACPLaunchError.unavailable) {
            _ = try await ClaudeCodeACPLaunch.spawn(
                executableURL: binary, workingDirectory: directory,
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60)),
                arguments: Array(repeating: "x", count: 257)
            )
        }
    }
}
