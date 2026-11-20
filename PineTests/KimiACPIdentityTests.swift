import Foundation
import Testing
@testable import Pine

@Suite("Kimi executable identity and account authority")
struct KimiACPIdentityTests {
    private let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pine-kimi-identity-\(UUID().uuidString)")

    private func makeTree(subdir: String,
                          interpreterBody: String = "#!/bin/sh\nexit 0\n",
                          entryBody: String) throws -> (entry: URL, interpreter: URL) {
        let root = tempRoot.appending(path: subdir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let interpreter = root.appending(path: "node")
        try interpreterBody.write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        let entry = root.appending(path: "kimi")
        try entryBody.write(to: entry, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        return (entry, interpreter)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    @Test func shebangEntryPinsEntryAndInterpreter() async throws {
        let interpreter = tempRoot.appending(path: "pin/node")
        let (entry, _) = try makeTree(
            subdir: "pin", entryBody: "#!\(interpreter.path)\n// fixture entry\n"
        )
        defer { cleanup() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let identity = try await KimiACPExecutableIdentity.capture(selectedURL: entry, deadline: deadline)
        try identity.validateMetadataSynchronously()
        try await identity.revalidate(deadline: deadline)
        // Interpreter replacement must be detected.
        try "#!/bin/sh\nexit 0\n# rotated\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        await #expect(throws: KimiACPExecutableError.changed) {
            try await identity.revalidate(deadline: deadline)
        }
    }

    @Test func nativeMachOMagicIsAcceptedAndPlainScriptRefused() async throws {
        let (entry, _) = try makeTree(subdir: "native", entryBody: "#!/bin/sh\nexit 0\n")
        try Data([0xCF, 0xFA, 0xED, 0xFE] + Array("fixture-macho".utf8)).write(to: entry)
        defer { cleanup() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        _ = try await KimiACPExecutableIdentity.capture(selectedURL: entry, deadline: deadline)
        let (plain, _) = try makeTree(subdir: "plain", entryBody: "console.log('fixture');\n")
        await #expect(throws: KimiACPExecutableError.unsupportedBinary) {
            _ = try await KimiACPExecutableIdentity.capture(selectedURL: plain, deadline: deadline)
        }
    }

    @Test func nonExecutableEntryIsRefused() async throws {
        let (entry, _) = try makeTree(subdir: "noexec", entryBody: "#!/bin/sh\nexit 0\n")
        defer { cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entry.path)
        await #expect(throws: KimiACPExecutableError.unsupportedBinary) {
            _ = try await KimiACPExecutableIdentity.capture(
                selectedURL: entry, deadline: ContinuousClock.now.advanced(by: .seconds(10))
            )
        }
    }

    @Test func versionProbeAcceptsPinnedVersionOnly() async throws {
        let (entry, _) = try makeTree(
            subdir: "pinned",
            entryBody: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "2.6.2"; exit 0; fi
            exit 1
            """
        )
        defer { cleanup() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        let identity = try await KimiACPExecutableIdentity.capture(selectedURL: entry, deadline: deadline)
        try await identity.probeVersion(at: tempRoot, deadline: deadline)
        let (other, _) = try makeTree(
            subdir: "mismatch",
            entryBody: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "9.9.9"; exit 0; fi
            exit 1
            """
        )
        let otherIdentity = try await KimiACPExecutableIdentity.capture(selectedURL: other, deadline: deadline)
        await #expect(throws: KimiACPExecutableError.unsupportedVersion) {
            try await otherIdentity.probeVersion(at: tempRoot, deadline: deadline)
        }
    }

    @Test func accountAuthorityFailsClosedWithoutVerifiedObservation() throws {
        let required = KimiACPAccountAuthority(managedAccount: true)
        #expect(throws: KimiACPWireError.authenticationRequired) { try required.validate() }
        required.observe("fixture-digest")
        #expect(throws: KimiACPWireError.authenticationRequired) { try required.validate() }
        let read = try required.beginRead()
        #expect(try required.verify("fixture-digest", read: read))
        try required.validate()
        // A rotated outcome invalidates the previous verification.
        required.observe("fixture-digest-rotated")
        #expect(throws: KimiACPWireError.authenticationRequired) { try required.validate() }
        let staleRead = try required.beginRead()
        required.observe("fixture-digest-rotated")
        #expect(try !required.verify("fixture-digest-rotated", read: staleRead))
        let freshRead = try required.beginRead()
        #expect(try required.verify("fixture-digest-rotated", read: freshRead))
        try required.validate()
        required.close()
        #expect(throws: KimiACPWireError.unavailable) { try required.validate() }

        // An external-provider agent needs no managed observation.
        let external = KimiACPAccountAuthority(managedAccount: false)
        try external.validate()
        external.close()
    }
}
