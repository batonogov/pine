import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("OpenCode ACP launch boundary")
struct OpenCodeACPLaunchTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pine-1811-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real Mach-O binary (copied system utility) for pure file-level
    /// identity checks. It is never executed here: restricted platform
    /// binaries are SIGKILLed by the system when run outside their canonical
    /// location, so exec-based assertions are out of scope for unit tests.
    private func copySystemBinary(into directory: URL) throws -> URL {
        let target = directory.appending(path: "fake-opencode")
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: target.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    @Test func identityCapturesPinsAndDetectsExecutableChanges() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let identity = try await OpenCodeACPExecutableIdentity.capture(selectedURL: binary, deadline: deadline)
        #expect(!identity.sha256.isEmpty)
        #expect(identity.canonicalURL.lastPathComponent == "fake-opencode")
        await #expect(throws: Never.self) {
            try await identity.revalidate(deadline: deadline)
        }
        try identity.validateMetadataSynchronously()
        // Metadata-only change (mtime + size) must refuse the pin.
        let handle = try FileHandle(forWritingTo: binary)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        await #expect(throws: OpenCodeACPLaunchError.changed) {
            try await identity.revalidate(deadline: deadline)
        }
        await #expect(throws: OpenCodeACPLaunchError.changed) {
            try identity.validateMetadataSynchronously()
        }
    }

    @Test func identityRejectsScriptsAndPinsTheVersionString() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        // The real OpenCode binary is Mach-O; a shell script is refused.
        let script = directory.appending(path: "scripted-opencode")
        try "#!/bin/sh\nprintf '\(OpenCodeACPExecutableIdentity.supportedVersion)'\n".write(
            toFile: script.path, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        await #expect(throws: OpenCodeACPLaunchError.unsupportedBinary) {
            _ = try await OpenCodeACPExecutableIdentity.capture(selectedURL: script, deadline: deadline)
        }
        // Version gate: the exact pinned string is accepted, anything else is
        // refused, and a failed probe is unavailable. Never executed for real:
        // a copied platform binary cannot run from a temp location.
        let binary = try copySystemBinary(into: directory)
        let identity = try await OpenCodeACPExecutableIdentity.capture(selectedURL: binary, deadline: deadline)
        await #expect(throws: Never.self) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, _, _, _ in
                (true, OpenCodeACPExecutableIdentity.supportedVersion)
            }
        }
        await #expect(throws: OpenCodeACPLaunchError.unsupportedVersion) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, _, _, _ in
                (true, "opencode v2.9.9")
            }
        }
        await #expect(throws: OpenCodeACPLaunchError.unavailable) {
            try await identity.probeVersion(at: directory, deadline: deadline) { _, _, _, _ in
                (false, "")
            }
        }
    }

    @Test func launchRefusesUnboundWorkingDirectory() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let identity = try await OpenCodeACPExecutableIdentity.capture(
            selectedURL: binary, deadline: .now.advanced(by: .seconds(30))
        )
        let file = directory.appending(path: "not-a-directory")
        try Data().write(to: file)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        await #expect(throws: OpenCodeACPLaunchError.unavailable) {
            _ = try await OpenCodeACPLaunch.launch(
                executable: identity, workingDirectory: file,
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60))
            )
        }
        await #expect(throws: OpenCodeACPLaunchError.unavailable) {
            _ = try await OpenCodeACPLaunch.launch(
                executable: identity, workingDirectory: directory.appending(path: "missing"),
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60))
            )
        }
    }

    @Test func everyNonExitedSpawnPollTransfersReapingAndDeferredCleanup() async throws {
        for poll in [UserTaskProcessExitPoll.running, .waitFailed(Int32(ECHILD))] {
            let reaped = Mutex(false)
            let deferred = AsyncContinuationGate()
            OpenCodeACPNativeSpawner.transferFailedSpawn(
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
        OpenCodeACPNativeSpawner.transferFailedSpawn(
            poll: .exited(0), groupIsAlive: { false },
            reap: {
                reaped.withLock { $0 = true }
                return UserTaskBackgroundReaper()
            },
            finishDeferredCleanup: { Issue.record("Empty group must not enter deferred cleanup") }
        )
        #expect(!reaped.withLock { $0 })
        let deferred = AsyncContinuationGate()
        OpenCodeACPNativeSpawner.transferFailedSpawn(
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

    @Test func launchArgumentBoundsAreEnforced() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try copySystemBinary(into: directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        await #expect(throws: OpenCodeACPLaunchError.unavailable) {
            _ = try await OpenCodeACPLaunch.spawn(
                executableURL: binary, workingDirectory: directory,
                deadline: deadline, drainUntil: .now.advanced(by: .seconds(60)), arguments: []
            )
        }
    }
}
