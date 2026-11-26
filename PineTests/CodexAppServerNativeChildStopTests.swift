//
//  CodexAppServerNativeChildStopTests.swift
//  PineTests
//
//  Regression for #1865: `stop` must arm `finishDeferredCleanup` on
//  `group.isAlive`, not on the direct child's `.running` poll. The member
//  below ignores TERM and setsid-escapes the process group shortly after the
//  direct child is reaped, so the bounded TERM-to-KILL sequence reports the
//  group gone. Only a scheduled deferred cleanup re-signals this known
//  member; with the scheduling gap it survives stop.
//

import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("Codex native child stop", .serialized, .timeLimit(.minutes(2)))
nonisolated struct CodexAppServerNativeChildStopTests {
    /// Ignores TERM (survives the first escalation stage), announces its pid,
    /// leaves the process group 50 ms after the direct child is reaped —
    /// after stop's liveness check, before the bounded KILL window would
    /// reach it — then outlives the test unless cleanup is scheduled.
    private static let memberScript = """
    import os
    import signal
    import sys
    import time

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1], "w") as handle:
        handle.write(str(os.getpid()))
    leader = os.getppid()
    while True:
        try:
            os.kill(leader, 0)
        except OSError:
            break
        time.sleep(0.005)
    time.sleep(0.05)
    os.setsid()
    time.sleep(60)
    """

    @Test func stopArmsDeferredCleanupForSurvivingGroupMember() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pine-1865-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appending(path: "member-pid")
        let script = root.appending(path: "member.py")
        try Self.memberScript.write(toFile: script.path, atomically: true, encoding: .utf8)

        let ownership = try await Self.prepareOwnership(root: root)
        let subprocess = try await runOnBackground {
            try UserTaskSubprocess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                command: "/usr/bin/python3 \(script.path) \(marker.path) & exit 0",
                workingDirectory: root
            )
        }
        var memberPid: pid_t = 0
        var memberIdentity: UserTaskProcessIdentity?
        defer {
            // Hygiene: never leave the escaped member or an unreaped child.
            // The member kill is identity-qualified: a recycled pid must not
            // be signalled.
            _ = Darwin.kill(-subprocess.processGroup.identifier, SIGKILL)
            _ = subprocess.waitForExit()
            if let memberIdentity,
               UserTaskProcessInspector.identity(for: memberPid) == memberIdentity {
                _ = Darwin.kill(memberPid, SIGKILL)
            }
        }
        let leaderPid = subprocess.processGroup.identifier
        // sh exits milliseconds after spawn and stays a zombie until stop's
        // pollExit reaps it: read with zombies included, where the pid +
        // start-time identity is identical to the live one.
        let leaderIdentity = await runOnBackground { () -> UserTaskProcessIdentity? in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let identity = UserTaskProcessInspector.identity(for: leaderPid, includeZombie: true) {
                    return identity
                }
                Darwin.usleep(1_000)
            }
            return nil
        }
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(
            identity: try #require(leaderIdentity),
            ownership: ownership,
            inspectIdentity: { pid in UserTaskProcessInspector.identity(for: pid) }
        )
        let channel = try await runOnBackground {
            try CodexAppServerStdioChannel(
                standardInput: subprocess.standardInput,
                standardOutput: subprocess.standardOutput,
                standardError: subprocess.standardError
            )
        }
        let child = CodexAppServerNativeChild(subprocess: subprocess, channel: channel, receipt: receipt)

        let announcement = await runOnBackground { () -> (pid: pid_t, identity: UserTaskProcessIdentity?) in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let raw = try? String(contentsOfFile: marker.path, encoding: .utf8),
                   let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return (pid, UserTaskProcessInspector.identity(for: pid))
                }
                Darwin.usleep(10_000)
            }
            return (0, nil)
        }
        memberPid = announcement.pid
        memberIdentity = announcement.identity
        #expect(memberPid > 0, "Group member never announced its pid")
        #expect(memberIdentity != nil, "Group member vanished before its identity was captured")

        // The direct child must have exited but not yet been reaped: stop's
        // pollExit then observes .exited, never .running — the gap this fix
        // closes. Observe with waitid(WNOWAIT) like production does:
        // proc_pidinfo rejects zombies on this OS, and WNOWAIT never reaps.
        let childExited = await runOnBackground {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                var info = siginfo_t()
                let result = Darwin.waitid(
                    P_PID, id_t(leaderPid), &info, WEXITED | WNOHANG | WNOWAIT
                )
                if result == 0, info.si_pid == leaderPid {
                    return true
                }
                Darwin.usleep(10_000)
            }
            return false
        }
        #expect(childExited, "Direct child was not exited-unreaped before stop")

        // An expired shared deadline (the #1811 production scenario): the
        // bounded wait cannot outlast the member's escape, so the liveness
        // check is the only thing that can arm the deferred cleanup.
        await child.stop(deadline: .now)

        let member = memberPid
        let memberGone = await runOnBackground {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if UserTaskProcessInspector.identity(for: member) == nil {
                    return true
                }
                Darwin.usleep(10_000)
            }
            return UserTaskProcessInspector.identity(for: member) == nil
        }
        #expect(memberGone, "Deferred cleanup was not scheduled for the surviving group member")
    }

    /// Minimal registry-owned admission for one owned child; mirrors the
    /// native bridge fixtures.
    @MainActor
    private static func prepareOwnership(root: URL) async throws -> AgentTaskNativeOwnership {
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let store = StopInMemoryTaskStore()
        let tasks = AgentTaskRegistry(persistence: store)
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            title: "Stop task", objective: "Explicit request"
        ))
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = StopBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection,
            provenance: AgentTaskLaunchProvenance(
                authenticationOrigin: .inheritNative,
                environmentProvenance: .inheritedPineProcess
            )
        ) else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        return try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
    }

    private actor StopBindingValidator: AgentTaskNativeBindingValidator {
        let binding: AgentTaskEnvironmentBinding
        let lease: RecentAgentTaskFilesystemValidationLease
        init(binding: AgentTaskEnvironmentBinding, lease: RecentAgentTaskFilesystemValidationLease) {
            self.binding = binding
            self.lease = lease
        }
        func revalidate(_ requested: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease {
            guard requested == binding else { throw AgentTaskEnvironmentBindingError.staleBinding }
            try requested.validateAuthority()
            return lease
        }
    }
}

/// In-memory persistence for the stop fixture: the same durable round-trip
/// contract as the real store, minus file I/O.
private actor StopInMemoryTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil,
            requiresMigration: false,
            envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard tasks.allSatisfy({ $0.nativeDispatch?.isValid(for: $0) ?? true }),
              let encoded = try? JSONEncoder().encode(tasks) else { return .rejected(.invalidMetadata) }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}
