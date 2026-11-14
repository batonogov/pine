import Darwin
import Foundation
import Synchronization
import Testing
@testable import Pine

struct CodexAppServerExecutableIdentityTests {
    @Test func signedDeviceIdentifiersPreserveTheirKernelBitPattern() {
        let cases: [(dev_t, UInt64)] = [
            (-1, UInt64.max), (.min, 0xFFFF_FFFF_8000_0000),
            (0, 0), (.max, 0x7FFF_FFFF)
        ]
        for (device, expected) in cases {
            #expect(CodexAppServerExecutableIdentity.filesystemDeviceIdentityForTesting(device) == expected)
        }
    }

    @MainActor
    @Test func selectedFIFOIsRejectedBeforeAnyWriterConnects() async throws {
        let fixture = try await runOnBackground { try ExecutableFixture() }
        defer { fixture.remove() }
        let fifo = fixture.root.appending(path: "selected-fifo")
        try #require(Darwin.mkfifo(fifo.path, 0o700) == 0)
        let finished = Mutex(false)
        let capture = Task {
            defer { finished.withLock { $0 = true } }
            do {
                _ = try await CodexAppServerExecutableIdentity.capture(
                    selectedURL: fifo, deadline: .now.advanced(by: .seconds(20))
                )
                return Optional<CodexAppServerExecutableError>.none
            } catch let error as CodexAppServerExecutableError {
                return error
            } catch {
                return CodexAppServerExecutableError.unavailable
            }
        }
        let rejectedWithoutWriter = await waitUntilMainActor { finished.withLock { $0 } }
        // Always connect an owned nonblocking writer before awaiting the worker:
        // the old blocking-open implementation must also exit on a failed test.
        let writer = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        defer { if writer >= 0 { Darwin.close(writer) } }
        #expect(writer >= 0)
        let result = await capture.value
        #expect(rejectedWithoutWriter)
        #expect(result == .unsupportedBinary)
    }

    @Test func executableContentMutationInvalidatesThePin() async throws {
        let fixture = try await runOnBackground { try ExecutableFixture() }
        defer { fixture.remove() }
        let identity = try await CodexAppServerExecutableIdentity.capture(
            selectedURL: fixture.binary, deadline: .now.advanced(by: .seconds(20))
        )
        #expect(identity.description == "<redacted:codex-executable>")
        try await runOnBackground { try fixture.write([1, 3]) }
        await #expect(throws: CodexAppServerExecutableError.changed) {
            try await identity.revalidate(deadline: .now.advanced(by: .seconds(20)))
        }
    }

    @Test func changingSelectedSymlinkCannotLaunchAnotherBinary() async throws {
        let fixture = try await runOnBackground { try ExecutableFixture() }
        defer { fixture.remove() }
        let alias = fixture.root.appending(path: "selected")
        let other = fixture.root.appending(path: "other")
        try await runOnBackground {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.binary)
            try Data([0xCF, 0xFA, 0xED, 0xFE, 9]).write(to: other)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path)
        }
        let identity = try await CodexAppServerExecutableIdentity.capture(selectedURL: alias, deadline: .now.advanced(by: .seconds(20)))
        try await runOnBackground {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        }
        #expect(throws: CodexAppServerExecutableError.changed) { try identity.validateMetadataSynchronously() }
        await #expect(throws: CodexAppServerExecutableError.changed) {
            try await identity.revalidate(deadline: .now.advanced(by: .seconds(20)))
        }
    }

    @Test func shellWrappersRemainUnsupportedUntilSeparatelyVerified() async throws {
        let fixture = try await runOnBackground { try ExecutableFixture() }
        defer { fixture.remove() }
        try await runOnBackground { try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.binary) }
        await #expect(throws: CodexAppServerExecutableError.unsupportedBinary) {
            try await CodexAppServerExecutableIdentity.capture(selectedURL: fixture.binary, deadline: .now.advanced(by: .seconds(20)))
        }
    }
}

nonisolated private struct ExecutableFixture: Sendable {
    let root: URL
    let binary: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PineExecutable-\(UUID())")
        binary = root.appending(path: "native-candidate")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try write([1, 2])
    }
    func write(_ suffix: [UInt8]) throws {
        // A synthetic Mach-O header is read as data, never executed.
        try Data([0xCF, 0xFA, 0xED, 0xFE] + suffix).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
