import Foundation
import Synchronization
import Testing
@testable import Pine

/// #1846 opt-in ACP v2 probe (dual-stack v1/v2 preparation).
///
/// Spec basis, cited exactly: ACP Preview schema **v2.0.0-beta.3**
/// (release commit `94824f1`, 2026-11-21) and the official v2 protocol
/// documentation pages (overview, initialization, session-setup,
/// prompt-lifecycle) fetched 2026-11-24. v2 is Preview, not frozen; the
/// schema release is the pinned citation.
///
/// Deterministic part (always runs, no binary): proves the shared Pine
/// JSON-RPC envelope hosts the v2 wire — no batches, non-null string/integer
/// request IDs, required error codes — and carries the v2 surfaces the
/// decision record names: prompt acceptance (`messageId`), `state_update`
/// with the `stopReason` and `background` list, `replay_complete`, and the
/// `idempotencyKey` retry class. This confirms the section-3 hypothesis that
/// the shared framer and request-ID type host v2 with only strictness, not a
/// new wire.
///
/// Real-binary part (opt-in): ONE v2 `initialize` handshake against a local
/// v2-capable ACP agent. Pass `PINE_RUN_ACP_V2_SMOKE=1` (and optionally
/// `PINE_ACP_V2_BINARY=<path>`); without it the test skips — CI has no
/// binary and is intentionally not the gate. No session creation, no prompt,
/// no auth mutation, no paid calls; the child is terminated after the
/// handshake line. The probe launches the binary with no arguments (the
/// standalone `claude-agent-acp` v0.109.1 artifact shape); a different v2
/// peer should be wrapped in a script. The recorded first v2 peers are
/// `claude-agent-acp` v0.109.1 and `codex-acp` v2.9.0; unsupported peer
/// behavior (a v1-only or -32022 answer) stays explicit, never a silent skip.
struct ACPv2ProbeTests {
    nonisolated private enum Config {
        static let optInEnvironmentVariable = "PINE_RUN_ACP_V2_SMOKE"
        static let binaryOverride = "PINE_ACP_V2_BINARY"
        static let isOptedIn =
            ProcessInfo.processInfo.environment[optInEnvironmentVariable] == "1"
        static let searchPaths = [
            "/opt/homebrew/bin/claude-agent-acp",
            "/usr/local/bin/claude-agent-acp",
        ]
        static var skipReason: String {
            "Pass PINE_RUN_ACP_V2_SMOKE=1 to run the opt-in ACP v2 handshake probe "
            + "(v2 initialize only, no session, no prompt); CI is intentionally not the gate."
        }
    }

    /// Feeds one JSONL line through a fresh ACP-strict framer and returns
    /// the delivery outcome (nil when the frame fences the channel).
    private static func framedLine(_ line: String) -> CodexAppServerMessage? {
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        let delivered = Mutex<CodexAppServerMessage?>(nil)
        try? framer.receive(Data((line + "\n").utf8)) { message in
            delivered.withLock { $0 = message }
        }
        return delivered.withLock { $0 }
    }

    // MARK: - Deterministic v2 wire strictness (always runs)

    /// v2: "ACP does not use batches", IDs "MUST be a string or an integer,
    /// never null", errors carry `code` and `message` (overview, fetched
    /// 2026-11-24). All three rules fence on the shared ACP-strict framer.
    @Test func v2WireStrictnessIsHostedByTheSharedFramer() throws {
        // No batches: a top-level JSON array line is not an envelope.
        let batchLine = #"[{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}]"#
        #expect(Self.framedLine(batchLine) == nil)
        // Non-null IDs: an explicit null response ID is not an envelope.
        let nullResponseID = #"{"jsonrpc":"2.0","id":null,"result":{}}"#
        #expect(Self.framedLine(nullResponseID) == nil)
        // A method with an explicit null ID is rejected, not a notification.
        let nullRequestID = #"{"jsonrpc":"2.0","id":null,"method":"session/prompt","params":{}}"#
        #expect(Self.framedLine(nullRequestID) == nil)
        // Required error fields: a failure without a message is not an envelope.
        let bareError = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601}}"#
        #expect(Self.framedLine(bareError) == nil)
        // The v2 shapes that matter to Pine deliver: string-ID request,
        // integer-ID response, plain notification.
        let request = Self.framedLine(#"{"jsonrpc":"2.0","id":"req_probe","method":"session/prompt","params":{"sessionId":"sess_probe"}}"#)
        let response = Self.framedLine(#"{"jsonrpc":"2.0","id":2,"result":{"messageId":"msg_user_8f7a1"}}"#)
        let notification = Self.framedLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_probe"}}"#)
        guard case .request(.string("req_probe"), "session/prompt", _)? = request else {
            Issue.record("ACP v2 wire: string-ID request not delivered")
            return
        }
        guard case .response(.integer(2), _)? = response else {
            Issue.record("ACP v2 wire: integer-ID response not delivered")
            return
        }
        guard case .notification("session/update", _)? = notification else {
            Issue.record("ACP v2 wire: notification not delivered")
            return
        }
    }

    /// The v2 `initialize` exchange round-trips through the Pine envelope:
    /// the request Pine would send (protocolVersion 2, `capabilities`,
    /// `info`) and the response shape a v2 agent returns (`capabilities` and
    /// `info`, not the v1 `agentCapabilities`/`agentInfo`), plus the -32022
    /// unsupported-version failure the negotiation rules define.
    @Test func v2InitializeNegotiationFramesRoundTripThroughThePineCodec() throws {
        let request = CodexAppServerMessage.request(.integer(0), method: "initialize", params: .object([
            "protocolVersion": .number("2"),
            "capabilities": .object([
                "elicitation": .object(["form": .object([:])])
            ]),
            "info": .object([
                "name": .string("pine"), "title": .string("Pine"), "version": .string("3.0")
            ])
        ]))
        // The ACP channel seam re-serializes with mandatory jsonrpc 2.0.
        let egress = try KimiACPWire.encode(request)
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        let decoded = Mutex<CodexAppServerMessage?>(nil)
        try framer.receive(egress) { message in decoded.withLock { $0 = message } }
        guard case .request(.integer(0), "initialize", let params)? = decoded.withLock({ $0 }) else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        #expect((try? KimiACPWire.object(params))?["protocolVersion"] == .number("2"))

        // v2 success response shape (initialization page, fetched 2026-11-24).
        let responseLine =
            #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":2,"capabilities":{"session":{}},"info":"#
            + #"{"name":"probe-agent","title":"Probe Agent","version":"0.109.1"},"authMethods":[]}}"#
        let response = Self.framedLine(responseLine)
        guard case .response(.integer(0), let result)? = response else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        let fields = try KimiACPWire.object(result)
        #expect(fields["protocolVersion"] == .number("2"))
        #expect((try? KimiACPWire.object(fields["capabilities"] ?? .object([:])))?["session"] != nil)
        guard case .object(let info)? = fields["info"],
              info["name"] == .string("probe-agent"), info["version"] == .string("0.109.1") else {
            throw CodexAppServerWireError.invalidEnvelope
        }

        // -32022: the peer supports a version higher than the requested one
        // (the spec's own example: requested 1, supported [2]). No version at
        // or below the requested one exists, so there is no fallback to
        // negotiate; the spec says close the connection and inform the user.
        // Pine's envelope retains the error CODE; the `data` object with the
        // supported list is dropped by design.
        let rejectedLine =
            #"{"jsonrpc":"2.0","id":0,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"#
            + #""requested":1,"supported":[2]}}}"#
        let rejected = Self.framedLine(rejectedLine)
        #expect(rejected == .failure(.integer(0), code: -32022))
    }

    /// The v2 prompt-acceptance and lifecycle surfaces named by the decision
    /// record are carried by the shared envelope: `idempotencyKey` on
    /// `session/prompt` (keyed retry class), the `messageId` acceptance
    /// response, `state_update` with `stopReason` and the `background`
    /// snapshot list, `replay_complete` after a resume replay, and
    /// `session/resume` with a `replayFrom` cursor.
    @Test func v2PromptAcceptanceAndLifecycleSurfacesAreCarriedByTheEnvelope() throws {
        // session/prompt with the v2 keyed-retry parameter.
        let prompt = CodexAppServerMessage.request(.integer(2), method: "session/prompt", params: .object([
            "sessionId": .string("sess_probe"),
            "idempotencyKey": .string("0b6f3c1e-8d2a-4c57-9a41-5e2f7d90c3ab"),
            "prompt": .array([.object([
                "type": .string("text"), "text": .string("Probe prompt")
            ])])
        ]))
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        let decoded = Mutex<CodexAppServerMessage?>(nil)
        try framer.receive(try KimiACPWire.encode(prompt)) { message in
            decoded.withLock { $0 = message }
        }
        guard case .request(.integer(2), "session/prompt", let params)? = decoded.withLock({ $0 }) else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        let promptFields = try KimiACPWire.object(params)
        #expect(promptFields["idempotencyKey"] == .string("0b6f3c1e-8d2a-4c57-9a41-5e2f7d90c3ab"))

        // Acceptance: the response carries the inserted message's ID.
        // (response ⇒ inserted, error ⇒ not; a retry with the same key must
        // return the original messageId — enforced by the v2 agent, observed
        // here as an envelope-level round trip.)
        let acceptanceLine = #"{"jsonrpc":"2.0","id":2,"result":{"messageId":"msg_user_8f7a1"}}"#
        let acceptance = Self.framedLine(acceptanceLine)
        guard case .response(.integer(2), let result) = acceptance else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        #expect(try KimiACPWire.object(result)["messageId"] == .string("msg_user_8f7a1"))

        // state_update: idle with an error stop reason and a background list.
        let stateUpdate = CodexAppServerMessage.notification(method: "session/update", params: .object([
            "sessionId": .string("sess_probe"), "update": .object([
                "sessionUpdate": .string("state_update"), "state": .string("idle"),
                "stopReason": .string("error"),
                "background": .array([
                    .object(["type": .string("terminal"), "terminalId": .string("term_003")]),
                    .object(["type": .string("tool_call"), "toolCallId": .string("call_012")]),
                    .object(["type": .string("subagent"), "sessionId": .string("sess_child_4")])
                ])
            ])
        ]))
        let deliveredState = Mutex<CodexAppServerMessage?>(nil)
        framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        try framer.receive(try KimiACPWire.encode(stateUpdate)) { message in
            deliveredState.withLock { $0 = message }
        }
        guard case .notification("session/update", let stateParams)? = deliveredState.withLock({ $0 }) else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        guard case .object(let updateFields)? = try KimiACPWire.object(stateParams)["update"] else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        let update = updateFields
        #expect(update["state"] == .string("idle"))
        #expect(update["stopReason"] == .string("error"))
        guard case .array(let background)? = update["background"], background.count == 3 else {
            throw CodexAppServerWireError.invalidEnvelope
        }

        // replay_complete: the end-of-replay marker after session/resume.
        let replayLine =
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_probe","#
            + #""update":{"sessionUpdate":"replay_complete"}}}"#
        let replay = Self.framedLine(replayLine)
        guard case .notification("session/update", let replayParams)? = replay else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        guard case .object(let replayFields)? = try KimiACPWire.object(replayParams)["update"] else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        #expect(replayFields["sessionUpdate"] == .string("replay_complete"))

        // session/resume with a replayFrom cursor.
        let resume = CodexAppServerMessage.request(.integer(3), method: "session/resume", params: .object([
            "sessionId": .string("sess_probe"),
            "replayFrom": .object(["type": .string("start")])
        ]))
        framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        let resumed = Mutex<CodexAppServerMessage?>(nil)
        try framer.receive(try KimiACPWire.encode(resume)) { message in
            resumed.withLock { $0 = message }
        }
        guard case .request(.integer(3), "session/resume", let resumeParams)? = resumed.withLock({ $0 }) else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        guard case .object(let replayFrom)? = try KimiACPWire.object(resumeParams)["replayFrom"] else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        #expect(replayFrom["type"] == .string("start"))
    }

    // MARK: - Opt-in real-binary v2 handshake

    @Test(.enabled(if: Config.isOptedIn, Comment(rawValue: Config.skipReason)))
    func realV2PeerInitializeHandshake() async throws {
        // Opted in: the probe must run, so a missing binary is a hard
        // failure with the exact requirement, never a silent skip.
        guard let binary = Self.findBinary() else {
            var message = "ACP v2 probe: no v2-capable ACP agent binary found. Searched "
            message += "PINE_ACP_V2_BINARY and " + Config.searchPaths.joined(separator: ", ") + "."
            message += " Requires the standalone claude-agent-acp v0.109.1 artifact (or an "
            message += "equivalent maintained v2 agent); see "
            message += "docs/ade-acp-reuse-comparison-2026-11-23.md section 7."
            Issue.record(Comment(rawValue: message))
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        // Isolation: fresh cwd + minimal env so the child never reads the
        // test host's provider state or configuration.
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "pine-acp-v2-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"] {
            let directory = sandbox.appending(path: key)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            environment[key] = directory.path
        }

        // The standalone claude-agent-acp artifact serves ACP on stdio
        // without a subcommand (its pinned launch identity, #1852).
        let process = Process()
        process.executableURL = binary
        process.arguments = []
        process.currentDirectoryURL = sandbox
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        // Drain and discard stderr: it may carry provider diagnostics and
        // secrets; retention is the regression the fixtures guard against.
        let stderrDrain = Task.detached {
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer { stderrDrain.cancel() }

        // ONE v2 initialize: the latest version Pine would request. No
        // session/new, no prompt, no auth — the child is terminated after
        // the handshake line, so nothing is billed.
        let message = CodexAppServerMessage.request(.integer(0), method: "initialize", params: .object([
            "protocolVersion": .number("2"),
            "capabilities": .object([
                "elicitation": .object(["form": .object([:])])
            ]),
            "info": .object([
                "name": .string("pine"), "title": .string("Pine"), "version": .string("3.0")
            ])
        ]))
        let bytes = try KimiACPWire.encode(message)
        await runOnBackground {
            inputPipe.fileHandleForWriting.write(bytes)
        }

        let line = try await readACPSmokeHandshakeLine(
            outputPipe.fileHandleForReading, deadline: deadline,
            forceClose: { process.terminate() }
        )
        _ = Task.detached { process.waitUntilExit() }
        let response = try CodexAppServerMessage(data: Data(line.utf8), requireJSONRPCVersion: true)
        switch response {
        case .response(let id, let result):
            guard id == .integer(0) else {
                Issue.record("ACP v2 probe: initialize produced an uncorrelated response")
                return
            }
            let fields = try KimiACPWire.object(result)
            guard case .number(let version)? = fields["protocolVersion"] else {
                Issue.record("ACP v2 probe: initialize result has no protocolVersion")
                return
            }
            // Fail closed: the request asked for 2, so any other version is a
            // downgraded v1 answer — an unsupported-peer result, never a pass.
            guard version == "2" else {
                Issue.record(Comment(rawValue: "ACP v2 probe: peer negotiated protocolVersion \(version), not 2"
                    + " (unsupported peer: this is not a v2 handshake)"))
                return
            }
            // Bounded observation: version, name, version string, and the
            // session capability flag. Capability payloads are not retained.
            guard case .object(let info)? = fields["info"],
                  case .string(let nameValue)? = info["name"],
                  case .string(let versionValue)? = info["version"] else {
                Issue.record("ACP v2 probe: initialize result has no v2 `info` identity")
                return
            }
            // v2 negotiated: the identity must be non-empty, so the success
            // print below can never log an empty identity. The observed
            // identity is bounded (name/version only) and reported to the run
            // log for the dated record; nothing is retained.
            guard !nameValue.isEmpty && !versionValue.isEmpty else {
                Issue.record(Comment(rawValue: "ACP v2 probe: peer negotiated protocolVersion \(version)"
                    + " with an empty `info` identity (name and version must be non-empty)"))
                return
            }
            let hasSession = (try? KimiACPWire.object(fields["capabilities"] ?? .object([:])))?["session"] != nil
            print("ACP v2 probe: negotiated protocolVersion \(version) with \(nameValue) "
                + "\(versionValue); session capability \(hasSession ? "present" : "absent"). "
                + "Handshake only — no session created, no prompt sent.")
        case .failure(let id, let code):
            guard id == .integer(0) else {
                Issue.record("ACP v2 probe: failure did not correlate to initialize")
                return
            }
            // Unsupported peer behavior stays explicit: -32022 means the
            // peer supports no version at or below the requested 2 (the data
            // object with its supported list is not retained by the Pine
            // envelope); the spec says close and inform the user.
            Issue.record(Comment(rawValue: "ACP v2 probe: peer rejected initialize with code \(code)"
                + (code == -32022 ? " (unsupported protocol version: peer supports no version at or below 2)" : "")))
        case .request, .notification:
            Issue.record("ACP v2 probe: initialize was answered by a non-response frame")
        }
    }

    private static func findBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment[Config.binaryOverride],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for candidate in Config.searchPaths {
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
