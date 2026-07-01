//
//  AgentDetectorTests.swift
//  PineTests
//
//  Tests for AgentDetector (vision #933, Phase 1 — process-name detection).
//

import Testing
@testable import Pine

@MainActor
struct AgentDetectorTests {

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
}
