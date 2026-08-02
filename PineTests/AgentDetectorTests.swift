//
//  AgentDetectorTests.swift
//  PineTests
//
//  Tests for AgentDetector (vision #933, Phase 1 — process-name detection).
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentDetectorTests {
    @Test("monotonic counters fail closed before wrap")
    func monotonicCounterExhaustion() {
        #expect(AgentMonotonicCounter.next(after: UInt64.max - 1) == UInt64.max)
        #expect(AgentMonotonicCounter.next(after: UInt64.max) == nil)
    }

    // MARK: - Detection of known agents

    @Test func detectsClaudeCode() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
        #expect(detector.detectedSessions[0].state == .idle)
        #expect(detector.activeCount == 1)
    }

    @Test func detectsCodex() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 101, command: "codex"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .codex)
    }

    @Test func detectsAider() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 102, command: "aider"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .aider)
    }

    @Test func detectsPi() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 103, command: "pi"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .pi)
    }

    @Test func detectsCopilotViaBothCliNames() {
        let detector1 = AgentDetector()
        detector1.processSnapshotDidUpdate([
            DetectedProcess(pid: 110, command: "github-copilot-cli"),
        ])
        #expect(detector1.detectedSessions[0].agentType == .copilot)

        let detector2 = AgentDetector()
        detector2.processSnapshotDidUpdate([
            DetectedProcess(pid: 111, command: "copilot"),
        ])
        #expect(detector2.detectedSessions[0].agentType == .copilot)
    }

    // MARK: - Full-path resolution

    @Test func detectsAgentFromFullPath() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 200, command: "/usr/local/bin/claude --verbose"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
    }

    @Test func detectsAgentFromBinPathWithoutArgs() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 201, command: "/opt/homebrew/bin/codex"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .codex)
    }

    // MARK: - Interpreter-wrapper resolution (node/python/… script CLIs)

    @Test func detectsPiLaunchedViaNodeWrapper() {
        // Homebrew `pi` is a node script: `ps` reports `node /opt/homebrew/bin/pi`.
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 250, command: "node /opt/homebrew/bin/pi"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .pi)
    }

    @Test func detectsAgentViaNodeWrapperWithArgs() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 251, command: "/opt/homebrew/opt/node/bin/node /opt/homebrew/bin/pi -p \"task\""),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .pi)
    }

    @Test func detectsAgentViaNodeWrapperScriptExtension() {
        // When an agent ships as a `<name>.js` script, the wrapper resolves
        // to the agent's CLI name (extension stripped): `claude.js` → `claude`.
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 252, command: "node /usr/local/bin/claude.js"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
    }

    @Test func doesNotResolveNestedScriptNamedAfterEntryPoint() {
        // A script whose filename is NOT an agent CLI name (e.g. a generic
        // `cli.js` buried under `node_modules/`) resolves to that filename and
        // is not tracked — precise resolution of such paths is left to output-
        // pattern matching (out of scope for process-name detection).
        //
        // Pin both halves explicitly: the `.js` extension IS stripped (`cli.js` →
        // `cli`), but `cli` is not a registered agent CLI name, so the entry is
        // not tracked. A bare `.isEmpty` assertion would pass even if stripping
        // silently regressed.
        #expect(AgentDetector.extractExecutableName(from: "node /usr/local/lib/node_modules/acme/cli.js") == "cli")
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 257, command: "node /usr/local/lib/node_modules/acme/cli.js"),
        ])
        #expect(detector.detectedSessions.isEmpty)
    }

    @Test func noFalsePositiveOnNodeScriptNotMatchingAgent() {
        // `node server.js` → `server` → generic → not tracked (no false positive).
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 253, command: "node server.js"),
            DetectedProcess(pid: 254, command: "python3 unrelated_script.py"),
        ])
        #expect(detector.detectedSessions.isEmpty)
    }

    @Test func interpreterAloneDoesNotMatch() {
        // A bare interpreter with no second token resolves to itself (`node`),
        // which is generic and must not be tracked.
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 255, command: "node"),
        ])
        #expect(detector.detectedSessions.isEmpty)
    }

    // MARK: - Interpreter-wrapper resolution — extended coverage

    @Test func detectsAgentLaunchedViaNpx() {
        // `npx` is in the interpreter-wrapper set: `npx <pkg>` resolves to the
        // package name. `npx claude` → `claude` → `.claudeCode`.
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 260, command: "npx claude --verbose"),
        ])
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
    }

    @Test func extractExecutableNameFromTsxWrapperStripsTsExtension() {
        // `tsx` is in the wrapper set; the `.ts` extension is stripped.
        #expect(AgentDetector.extractExecutableName(from: "tsx /opt/aider/aider.ts") == "aider")
    }

    @Test func extractExecutableNameFromExeInterpreterVariant() {
        // The `*.exe` interpreter variants are declared for completeness; pin
        // that the lowercased comparison resolves them like the bare form.
        #expect(AgentDetector.extractExecutableName(from: "node.exe /opt/homebrew/bin/pi") == "pi")
    }

    @Test func extractExecutableNameCaseInsensitiveInterpreter() {
        // The interpreter name is matched case-insensitively, while the resolved
        // CLI stem preserves its original casing.
        #expect(AgentDetector.extractExecutableName(from: "NODE /opt/homebrew/bin/pi") == "pi")
        #expect(AgentDetector.extractExecutableName(from: "Python3 /usr/local/bin/aider") == "aider")
    }

    @Test func extractExecutableNameFromNodeWrapperMultipleSpaces() {
        // `split(omittingEmptySubsequences:)` collapses internal runs of spaces
        // so the wrapper still resolves with extra spacing in `ps` output.
        #expect(AgentDetector.extractExecutableName(from: "node    /opt/homebrew/bin/pi") == "pi")
    }

    @Test func pythonWrapperDoesNotStripPyExtension() {
        // Only JS/TS script extensions are stripped; a `.py`/`.rb` script is
        // left as-is, so `aider.py` does not match the `aider` CLI name and is
        // not tracked. (pip/npm install agents as plain executables without an
        // extension, so this is the intended behavior.)
        #expect(AgentDetector.extractExecutableName(from: "python3 /x/aider.py") == "aider.py")
    }

    @Test func idempotentWrapperFormDoesNotDuplicate() {
        // A wrapper-form pid is deduplicated by pid just like a bare command.
        let detector = AgentDetector()
        let snapshot = [DetectedProcess(pid: 320, command: "node /opt/homebrew/bin/pi")]
        detector.processSnapshotDidUpdate(snapshot)
        detector.processSnapshotDidUpdate(snapshot)
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .pi)
    }

    // MARK: - No false positives

    @Test func noFalsePositivesOnShellCommands() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 1, command: "bash"),
            DetectedProcess(pid: 2, command: "ls -la"),
            DetectedProcess(pid: 3, command: "git status"),
            DetectedProcess(pid: 4, command: "vim README.md"),
            DetectedProcess(pid: 5, command: "node server.js"),
            DetectedProcess(pid: 6, command: "/bin/zsh"),
            DetectedProcess(pid: 7, command: "python3 script.py"),
        ])
        #expect(detector.detectedSessions.isEmpty)
        #expect(detector.activeCount == 0)
    }

    @Test func noFalsePositivesOnAgentAdjacentNames() {
        // Names that resemble agent CLIs but are not exact matches must not
        // trigger detection (cliNames uses exact membership).
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 10, command: "claude-code"),
            DetectedProcess(pid: 11, command: "myclaude"),
            DetectedProcess(pid: 12, command: "codex-helper"),
            DetectedProcess(pid: 13, command: "/usr/bin/ping"),
        ])
        #expect(detector.detectedSessions.isEmpty)
    }

    @Test func ignoresEmptyCommand() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 20, command: ""),
            DetectedProcess(pid: 21, command: "   "),
        ])
        #expect(detector.detectedSessions.isEmpty)
    }

    // MARK: - Idempotency

    @Test func idempotentSameSnapshotDoesNotDuplicate() {
        let detector = AgentDetector()
        let snapshot = [DetectedProcess(pid: 300, command: "claude")]

        detector.processSnapshotDidUpdate(snapshot)
        #expect(detector.detectedSessions.count == 1)
        let firstSessionID = detector.detectedSessions[0].id

        detector.processSnapshotDidUpdate(snapshot)
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].id == firstSessionID)
    }

    @Test func idempotentMultipleAgentsStableIDs() {
        let detector = AgentDetector()
        let snapshot = [
            DetectedProcess(pid: 310, command: "claude"),
            DetectedProcess(pid: 311, command: "codex"),
            DetectedProcess(pid: 312, command: "aider"),
        ]

        detector.processSnapshotDidUpdate(snapshot)
        let idsAfterFirst = detector.detectedSessions.map(\.id)

        detector.processSnapshotDidUpdate(snapshot)
        let idsAfterSecond = detector.detectedSessions.map(\.id)

        #expect(idsAfterFirst == idsAfterSecond)
        #expect(detector.detectedSessions.count == 3)
    }

    // MARK: - Lifecycle

    @Test func lifecycleStartThenDoneWhenPidDisappears() {
        let detector = AgentDetector()

        // Start: agent detected.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 400, command: "claude"),
        ])
        #expect(detector.activeCount == 1)
        #expect(detector.detectedSessions[0].state == .idle)

        // Snapshot no longer includes the pid → session marked .done.
        detector.processSnapshotDidUpdate([])
        #expect(detector.activeCount == 0)
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].state == .done)
    }

    @Test func lifecycleOnlyExitedPidsMarkedDone() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 410, command: "claude"),
            DetectedProcess(pid: 411, command: "codex"),
        ])
        #expect(detector.activeCount == 2)

        // Only claude disappears.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 411, command: "codex"),
        ])
        #expect(detector.activeCount == 1)
        let claudeSession = detector.detectedSessions.first { $0.agentType == .claudeCode }
        let codexSession = detector.detectedSessions.first { $0.agentType == .codex }
        #expect(claudeSession?.state == .done)
        #expect(codexSession?.state == .idle)
    }

    @Test func reconcileMarksMissingPidsDone() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 420, command: "claude"),
            DetectedProcess(pid: 421, command: "pi"),
        ])
        #expect(detector.activeCount == 2)

        // Standalone reconcile: only pid 420 still alive.
        detector.reconcile(activePIDs: [420])
        #expect(detector.activeCount == 1)
        let piSession = detector.detectedSessions.first { $0.agentType == .pi }
        #expect(piSession?.state == .done)
    }

    @Test func reconcileIsNoOpWhenAllPidsActive() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 430, command: "claude"),
        ])
        detector.reconcile(activePIDs: [430])
        #expect(detector.activeCount == 1)
        #expect(detector.detectedSessions[0].state == .idle)
    }

    // MARK: - Pid reuse creates a new session

    @Test func pidReuseCreatesNewSession() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 500, command: "claude"),
        ])
        let originalID = detector.detectedSessions[0].id
        let originalGeneration = detector.detectedSessions[0]
            .processEvidence?.processGeneration

        // Process exits.
        detector.processSnapshotDidUpdate([])
        #expect(detector.detectedSessions[0].state == .done)

        // Same pid reappears (OS recycled it) → new session, not resurrection.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 500, command: "claude"),
        ])
        let allClaude = detector.detectedSessions.filter { $0.agentType == .claudeCode }
        #expect(allClaude.count == 2)
        #expect(allClaude[1].id != originalID)
        #expect(allClaude[1].state == .idle)
        #expect(allClaude[0].state == .done)
        #expect(
            allClaude[1].processEvidence?.processGeneration
                != originalGeneration
        )
    }

    @Test func samePidCpuRegressionCreatesFreshSession() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 510, command: "claude", cpuTime: 100),
        ])
        let original = try #require(detector.session(forPID: 510))

        let terminated = detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 510, command: "claude", cpuTime: 2),
        ])

        let replacement = try #require(detector.session(forPID: 510))
        #expect(terminated == [original.id])
        #expect(original.state == .done)
        #expect(original.liveness == .terminated)
        #expect(replacement !== original)
        #expect(replacement.state == .idle)
        #expect(
            replacement.processEvidence?.processGeneration
                != original.processEvidence?.processGeneration
        )
    }

    @Test func changedProcessStartIdentifierCreatesFreshSession() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 511,
                command: "codex",
                cpuTime: 10,
                startIdentifier: "Mon Jul 20 10:00:00 2026"
            ),
        ])
        let original = try #require(detector.session(forPID: 511))

        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 511,
                command: "codex",
                cpuTime: 11,
                startIdentifier: "Tue Jul 21 10:00:00 2026"
            ),
        ])

        let replacement = try #require(detector.session(forPID: 511))
        #expect(original.state == .done)
        #expect(replacement !== original)
        #expect(
            replacement.processEvidence?.processGeneration
                != original.processEvidence?.processGeneration
        )
    }

    @Test func stableProcessStartIdentifierKeepsSessionIdentity() throws {
        let detector = AgentDetector()
        let start = "Mon Jul 20 10:00:00 2026"
        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 512,
                command: "pi",
                cpuTime: 10,
                startIdentifier: start
            ),
        ])
        let original = try #require(detector.session(forPID: 512))

        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 512,
                command: "pi",
                cpuTime: 11,
                startIdentifier: start
            ),
        ])

        #expect(detector.session(forPID: 512) === original)
        #expect(detector.detectedSessions == [original])
        #expect(original.processEvidence?.startIdentifier == start)
    }

    @Test func preciseProcessStartIsRuntimeAuthorityEvidence() throws {
        let detector = AgentDetector()
        let preciseStart = Date(timeIntervalSince1970: 7_000.125)
        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 515,
                command: "codex",
                startIdentifier: "Mon Jul 20 10:00:00 2026",
                preciseStartedAt: preciseStart
            ),
        ])
        let precise = try #require(detector.session(forPID: 515))
        #expect(precise.processEvidence?.observedStartedAt == preciseStart)
        #expect(precise.processEvidence?.startIsAuthoritative == true)

        detector.processSnapshotDidUpdate([
            DetectedProcess(
                pid: 515,
                command: "codex",
                startIdentifier: "Mon Jul 20 10:00:00 2026",
                preciseStartedAt: preciseStart.addingTimeInterval(0.25)
            ),
        ])
        let replacement = try #require(detector.session(forPID: 515))
        #expect(replacement.id != precise.id)
        #expect(
            replacement.processEvidence?.processGeneration
                == (precise.processEvidence?.processGeneration ?? 0) + 1
        )

        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 516, command: "pi"),
        ])
        let fallback = try #require(detector.session(forPID: 516))
        #expect(fallback.processEvidence?.startIsAuthoritative == false)
    }

    @Test func processSampleRequiresCoherentGeneration() {
        let coarse = Date(timeIntervalSince1970: 1_722_000_000)
        let precise = Date(timeIntervalSince1970: 1_722_000_000.125)
        #expect(AgentDetectionCoordinator.processSampleIsCoherentForTesting(
            coarseStart: coarse,
            beforeStart: precise,
            afterStart: precise,
            observedExecutable: "codex",
            currentExecutable: "codex"
        ))
        #expect(!AgentDetectionCoordinator.processSampleIsCoherentForTesting(
            coarseStart: coarse,
            beforeStart: precise,
            afterStart: precise.addingTimeInterval(0.001),
            observedExecutable: "codex",
            currentExecutable: "codex"
        ))
        #expect(!AgentDetectionCoordinator.processSampleIsCoherentForTesting(
            coarseStart: coarse,
            beforeStart: precise,
            afterStart: precise,
            observedExecutable: "codex",
            currentExecutable: "node"
        ))
        #expect(!AgentDetectionCoordinator.processSampleIsCoherentForTesting(
            coarseStart: coarse.addingTimeInterval(-1),
            beforeStart: precise,
            afterStart: precise,
            observedExecutable: "codex",
            currentExecutable: "codex"
        ))
    }

    @Test func detectorHistoryIsBoundedWithoutDroppingLiveSessions() {
        let detector = AgentDetector(maxSessionHistory: 2)
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 801, command: "codex"),
            DetectedProcess(pid: 802, command: "pi"),
            DetectedProcess(pid: 803, command: "aider"),
        ])
        #expect(detector.detectedSessions.count == 2)
        #expect(detector.activeCount == 2)

        detector.processSnapshotDidUpdate([])
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 804, command: "codex"),
            DetectedProcess(pid: 805, command: "pi"),
        ])
        #expect(detector.detectedSessions.count == 2)
        #expect(detector.activeCount == 2)
    }

    @Test func olderSuccessfulSnapshotCannotTerminateNewerEvidence() throws {
        let detector = AgentDetector()
        let baseline = Date(timeIntervalSince1970: 6_000)
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 513, command: "aider")],
            observation: stamp(
                baseline,
                uptime: 200,
                generation: 2,
                sequence: 2
            )
        )
        let session = try #require(detector.session(forPID: 513))

        let terminated = detector.processSnapshotDidUpdate(
            [],
            observation: stamp(
                baseline.addingTimeInterval(100),
                uptime: 300,
                generation: 2,
                sequence: 1
            )
        )

        #expect(terminated.isEmpty)
        #expect(detector.session(forPID: 513) === session)
        #expect(session.liveness == .live)
    }

    @Test func duplicateOrderedSnapshotCannotTerminateExistingEvidence() throws {
        let detector = AgentDetector()
        let baseline = Date(timeIntervalSince1970: 6_500)
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 515, command: "aider")],
            observation: stamp(
                baseline,
                uptime: 200,
                generation: 2,
                sequence: 3
            )
        )
        let session = try #require(detector.session(forPID: 515))

        let terminated = detector.processSnapshotDidUpdate(
            [],
            observation: stamp(
                baseline.addingTimeInterval(100),
                uptime: 300,
                generation: 2,
                sequence: 3
            )
        )

        #expect(terminated.isEmpty)
        #expect(detector.session(forPID: 515) === session)
        #expect(session.liveness == .live)
    }

    @Test func olderFailedSnapshotCannotStaleNewerEvidence() throws {
        let detector = AgentDetector(staleAfter: 1)
        let baseline = Date(timeIntervalSince1970: 7_000)
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 514, command: "claude")],
            observation: stamp(
                baseline,
                uptime: 200,
                generation: 3,
                sequence: 2
            )
        )
        let session = try #require(detector.session(forPID: 514))

        let checks = detector.processSnapshotDidFail(
            observation: stamp(
                baseline.addingTimeInterval(100),
                uptime: 400,
                generation: 3,
                sequence: 1
            )
        )

        #expect(checks.isEmpty)
        #expect(session.liveness == .live)
    }

    // MARK: - Mixed snapshot: agents + non-agents

    @Test func mixedSnapshotDetectsOnlyAgents() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 600, command: "bash"),
            DetectedProcess(pid: 601, command: "claude"),
            DetectedProcess(pid: 602, command: "git log"),
            DetectedProcess(pid: 603, command: "codex"),
            DetectedProcess(pid: 604, command: "vim"),
        ])
        #expect(detector.detectedSessions.count == 2)
        let types = detector.detectedSessions.map(\.agentType)
        #expect(types.contains(.claudeCode))
        #expect(types.contains(.codex))
    }

    // MARK: - clearFinishedSessions

    @Test func clearFinishedSessionsRemovesOnlyDone() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 700, command: "claude"),
            DetectedProcess(pid: 701, command: "codex"),
        ])
        // Codex exits.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 700, command: "claude"),
        ])
        #expect(detector.detectedSessions.count == 2)

        detector.clearFinishedSessions()
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
        #expect(detector.detectedSessions[0].state == .idle)
    }

    // MARK: - activeSessions computed property

    @Test func activeSessionsExcludesDone() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 800, command: "claude"),
            DetectedProcess(pid: 801, command: "pi"),
        ])
        // Claude exits.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 801, command: "pi"),
        ])
        #expect(detector.detectedSessions.count == 2)
        #expect(detector.activeSessions.count == 1)
        #expect(detector.activeSessions[0].agentType == .pi)
    }

    @Test func failedSnapshotDoesNotReconcileTrackedSession() throws {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let detector = AgentDetector(staleAfter: 300)
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 810, command: "claude")],
            observation: stamp(
                baseline,
                uptime: 100,
                generation: 1,
                sequence: 1
            )
        )
        let session = try #require(detector.session(forPID: 810))

        detector.processSnapshotDidFail(
            observation: stamp(
                baseline.addingTimeInterval(299),
                uptime: 399,
                generation: 1,
                sequence: 2
            )
        )

        #expect(detector.session(forPID: 810) === session)
        #expect(session.state == .idle)
        #expect(session.liveness == .live)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func failedSnapshotMakesOldEvidenceStaleAndExcludesAttribution() throws {
        let baseline = Date(timeIntervalSince1970: 2_000)
        let detector = AgentDetector(staleAfter: 300)
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 811, command: "codex")],
            observation: stamp(
                baseline,
                uptime: 100,
                generation: 1,
                sequence: 1
            )
        )
        let session = try #require(detector.session(forPID: 811))

        detector.processSnapshotDidFail(
            observation: stamp(
                baseline.addingTimeInterval(300),
                uptime: 400,
                generation: 1,
                sequence: 2
            )
        )

        #expect(detector.session(forPID: 811) === session)
        #expect(session.state == .idle)
        #expect(session.liveness == .stale)
        #expect(detector.activeSessions.isEmpty)
        #expect(detector.activeCount == 0)
    }

    @Test func successfulObservationRevivesStaleTrackedSession() throws {
        let baseline = Date(timeIntervalSince1970: 3_000)
        let revivedAt = baseline.addingTimeInterval(400)
        let detector = AgentDetector(staleAfter: 300)
        let snapshot = [DetectedProcess(pid: 812, command: "aider")]
        detector.processSnapshotDidUpdate(
            snapshot,
            observation: stamp(
                baseline,
                uptime: 100,
                generation: 1,
                sequence: 1
            )
        )
        let session = try #require(detector.session(forPID: 812))
        detector.processSnapshotDidFail(
            observation: stamp(
                revivedAt,
                uptime: 500,
                generation: 1,
                sequence: 2
            )
        )
        #expect(session.liveness == .stale)

        detector.processSnapshotDidUpdate(
            snapshot,
            observation: stamp(
                revivedAt,
                uptime: 500,
                generation: 1,
                sequence: 3
            )
        )

        #expect(detector.session(forPID: 812) === session)
        #expect(session.liveness == .live)
        #expect(session.lastObservedAt == revivedAt)
        #expect(detector.activeSessions == [session])
    }

    @Test func successfulEmptySnapshotAuthoritativelyTerminatesSession() throws {
        let baseline = Date(timeIntervalSince1970: 4_000)
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 813, command: "pi")],
            observation: stamp(
                baseline,
                uptime: 100,
                generation: 1,
                sequence: 1
            )
        )
        let session = try #require(detector.session(forPID: 813))

        detector.processSnapshotDidUpdate(
            [],
            observation: stamp(
                baseline.addingTimeInterval(1),
                uptime: 101,
                generation: 1,
                sequence: 2
            )
        )

        #expect(detector.session(forPID: 813) == nil)
        #expect(session.state == .done)
        #expect(session.liveness == .terminated)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func trackedPidExecutingDifferentAgentStartsNewSession() throws {
        let baseline = Date(timeIntervalSince1970: 5_000)
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 814, command: "claude")],
            observation: stamp(
                baseline,
                uptime: 100,
                generation: 1,
                sequence: 1
            )
        )
        let oldSession = try #require(detector.session(forPID: 814))

        detector.processSnapshotDidUpdate(
            [DetectedProcess(pid: 814, command: "codex")],
            observation: stamp(
                baseline.addingTimeInterval(1),
                uptime: 101,
                generation: 1,
                sequence: 2
            )
        )

        let newSession = try #require(detector.session(forPID: 814))
        #expect(oldSession.state == .done)
        #expect(oldSession.liveness == .terminated)
        #expect(newSession !== oldSession)
        #expect(newSession.agentType == .codex)
        #expect(detector.detectedSessions == [oldSession, newSession])
    }

    @Test func trackedPidExecutingNonAgentTerminatesOldSession() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 815, command: "claude"),
        ])
        let session = try #require(detector.session(forPID: 815))

        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 815, command: "bash"),
        ])

        #expect(detector.session(forPID: 815) == nil)
        #expect(session.state == .done)
        #expect(session.liveness == .terminated)
    }

    // MARK: - extractExecutableName helper

    @Test func extractExecutableNameFromBareName() {
        #expect(AgentDetector.extractExecutableName(from: "claude") == "claude")
    }

    @Test func extractExecutableNameFromFullPath() {
        #expect(AgentDetector.extractExecutableName(from: "/usr/local/bin/claude") == "claude")
    }

    @Test func extractExecutableNameFromFullPathWithArgs() {
        #expect(AgentDetector.extractExecutableName(from: "/opt/homebrew/bin/codex --verbose") == "codex")
    }

    @Test func extractExecutableNameFromEmpty() {
        #expect(AgentDetector.extractExecutableName(from: "") == "")
        #expect(AgentDetector.extractExecutableName(from: "   ") == "")
    }

    @Test func extractExecutableNameFromNodeWrapper() {
        // Homebrew `pi` shape: `node /opt/homebrew/bin/pi` → `pi`.
        #expect(AgentDetector.extractExecutableName(from: "node /opt/homebrew/bin/pi") == "pi")
    }

    @Test func extractExecutableNameFromNodeWrapperFullPathWithArgs() {
        #expect(
            AgentDetector.extractExecutableName(from: "/opt/homebrew/opt/node/bin/node /opt/homebrew/bin/pi -p task") == "pi"
        )
    }

    @Test func extractExecutableNameFromNodeWrapperStripsScriptExtension() {
        #expect(AgentDetector.extractExecutableName(from: "node /usr/local/lib/.../claude.js") == "claude")
        #expect(AgentDetector.extractExecutableName(from: "bun /x/aider.ts") == "aider")
    }

    @Test func extractExecutableNameFromPythonWrapper() {
        #expect(AgentDetector.extractExecutableName(from: "python3 /usr/local/bin/aider") == "aider")
    }

    @Test func extractExecutableNamePreservesStemCase() {
        #expect(AgentDetector.extractExecutableName(from: "node /x/MyAgent.js") == "MyAgent")
    }

    @Test func extractExecutableNameBareInterpreter() {
        // No second token → resolves to the interpreter itself.
        #expect(AgentDetector.extractExecutableName(from: "node") == "node")
    }

    // MARK: - Multiple sequential updates

    @Test func sequentialUpdatesAccumulateAndReconcile() {
        let detector = AgentDetector()

        // 1. Only claude.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 900, command: "claude"),
        ])
        #expect(detector.activeCount == 1)

        // 2. Codex joins.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 900, command: "claude"),
            DetectedProcess(pid: 901, command: "codex"),
        ])
        #expect(detector.activeCount == 2)

        // 3. Claude leaves, aider joins.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 901, command: "codex"),
            DetectedProcess(pid: 902, command: "aider"),
        ])
        #expect(detector.activeCount == 2)
        let activeTypes = detector.activeSessions.map(\.agentType)
        #expect(activeTypes.contains(.codex))
        #expect(activeTypes.contains(.aider))
        #expect(!activeTypes.contains(.claudeCode))

        // History preserves all three.
        #expect(detector.detectedSessions.count == 3)
    }

    private func stamp(
        _ wallTime: Date,
        uptime: TimeInterval,
        generation: UInt64,
        sequence: UInt64
    ) -> AgentObservationStamp {
        AgentObservationStamp(
            wallTime: wallTime,
            uptime: uptime,
            generation: generation,
            sequence: sequence
        )
    }
}
