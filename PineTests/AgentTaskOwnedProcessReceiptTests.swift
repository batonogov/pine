import Darwin
import Foundation
import Synchronization
import Testing
@testable import Pine

/// Exercises the owned-process receipt against a real spawned child
/// (`/bin/sleep`) and the synthetic test hook for ownership races. This is
/// not evidence that the Codex bridge or kernel supervision works.
struct AgentTaskOwnedProcessReceiptTests {
    @Test func realSpawnBindsIdentityAndRevalidatesUntilRevoked() async throws {
        let fixture = try await ReceiptProcessFixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership
        let subprocess = try await runOnBackground {
            try UserTaskSubprocess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: fixture.root
            )
        }
        let receipt = try await runOnBackground {
            try AgentTaskOwnedProcessReceipt(process: subprocess, ownership: ownership) {
                try fixture.identity.validateProcessImageSynchronously(
                    processID: $0.processID, incarnation: $0
                )
            }
        }
        defer { await runOnBackground { fixture.teardown(subprocess) } }

        #expect(receipt.belongs(to: ownership))
        #expect(!receipt.belongs(to: fixture.otherOwnership))
        #expect(await receipt.revalidate())
        #expect(receipt.description == "<redacted:owned-process-receipt>")

        // Revoking the receipt revokes the owning ownership: the launch
        // authority dies with the child.
        receipt.revoke()
        #expect(await runOnBackground {
            (try? receipt.validateDispatch()) == nil
        })
        #expect(await receipt.revalidate() == false)
        #expect(await runOnBackground {
            (try? ownership.validateSelection()) == nil
        })
    }

    @Test func syntheticReceiptTracksIdentityDrift() async throws {
        let fixture = try await ReceiptProcessFixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership
        let identity = UserTaskProcessIdentity(processID: 4242, startSeconds: 1, startMicroseconds: 2)
        let inspect = Mutex<[Int32: UserTaskProcessIdentity]?>([4242: identity])
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(
            identity: identity,
            ownership: ownership,
            inspectIdentity: { pid in inspect.withLock { $0?[pid] } }
        )
        #expect(await receipt.revalidate())
        inspect.withLock { $0 = nil }
        #expect(await receipt.revalidate() == false)
        inspect.withLock { $0 = [4242: identity] }
        #expect(await receipt.revalidate())
        ownership.revoke()
        #expect(await receipt.revalidate() == false)
    }
}

nonisolated private struct ReceiptProcessFixture: Sendable {
    let root: URL
    let ownership: AgentTaskNativeOwnership
    let otherOwnership: AgentTaskNativeOwnership
    let identity: CodexAppServerExecutableIdentity

    @MainActor
    init() async throws {
        let base = try await NativeOwnershipFixture()
        root = base.root
        ownership = base.ownership
        otherOwnership = try AgentTaskNativeOwnership(
            policy: base.policy,
            binding: base.ownership.binding,
            filesystem: base.lease, bindings: base.validator,
            environment: ProcessInfo.processInfo.environment
        )
        // Pin the real /bin/sleep image; the spawn below uses the same file.
        identity = try await CodexAppServerExecutableIdentity.capture(
            selectedURL: URL(fileURLWithPath: "/bin/sleep"),
            deadline: .now.advanced(by: .seconds(10))
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func teardown(_ subprocess: UserTaskSubprocess) {
        let group = subprocess.processGroup
        if group.isAlive {
            group.requestTermination()
        }
        _ = group.waitForRequestedTermination(completionTimeout: 2)
        _ = subprocess.pollExit()
    }
}
