import Foundation
import Testing
@testable import Pine

struct ClaudeCodeHookReportTests {
    static let sessionID = "fixture-session"
    static let token = "pine-launch-token-0123456789"

    private func identity() throws -> ClaudeCodeHookLaunchIdentity {
        try ClaudeCodeHookLaunchIdentity(launchToken: Self.token, sessionID: Self.sessionID)
    }

    private func envelope(
        _ event: String,
        sessionID: String = Self.sessionID,
        token: String = Self.token,
        toolName: String? = nil,
        agentID: String? = nil
    ) -> String {
        var fields = [
            "\"hook_event_name\":\"\(event)\"",
            "\"session_id\":\"\(sessionID)\"",
            "\"launch_token\":\"\(token)\""
        ]
        if let toolName { fields.append("\"tool_name\":\"\(toolName)\"") }
        if let agentID { fields.append("\"agent_id\":\"\(agentID)\"") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test func allowlistedFieldsParseAndDropEverythingElse() throws {
        let secret = "HOOK-PAYLOAD-\(UUID().uuidString)"
        let line = """
        {"hook_event_name":"PreToolUse","session_id":"\(Self.sessionID)","launch_token":"\(Self.token)",\
        "tool_name":"Bash","cwd":"/Users/someone/secret","transcript_path":"/Users/someone/transcript.jsonl",\
        "prompt":"\(secret)","tool_input":{"command":"\(secret)"},"env":{"KEY":"\(secret)"}}
        """
        guard case .success(let report) = ClaudeCodeHookEnvelope.parse(data: Data(line.utf8)) else {
            throw ClaudeCodeHookError.invalidEvent
        }
        #expect(report.event == .preToolUse)
        #expect(report.sessionID == Self.sessionID)
        #expect(report.launchToken == Self.token)
        #expect(report.toolName == "Bash")
        #expect(!report.subagent)
        #expect(!report.historical)
        let rendered = String(describing: report)
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains("transcript"))
        #expect(!rendered.contains("secret"))
    }

    @Test func unauthenticatedAndUnsupportedEventsAreRejected() throws {
        #expect(ClaudeHookOutcome(ClaudeCodeHookEnvelope.parse(
            data: Data(#"{"hook_event_name":"Stop","session_id":"s","launch_token":""}"#.utf8)
        )) == .unauthenticated)
        #expect(ClaudeHookOutcome(ClaudeCodeHookEnvelope.parse(
            data: Data(#"{"session_id":"s","launch_token":"\(Self.token)"}"#.utf8)
        )) == .unsupportedEvent)
        #expect(ClaudeHookOutcome(ClaudeCodeHookEnvelope.parse(
            data: Data(#"{"hook_event_name":"FileChanged","session_id":"s","launch_token":"\(Self.token)"}"#.utf8)
        )) == .unsupportedEvent)
        #expect(ClaudeHookOutcome(ClaudeCodeHookEnvelope.parse(
            data: Data(#"not json"#.utf8)
        )) == .unsupportedEvent)
    }

    @Test func validatorRejectsForeignNestedAndStaleReports() throws {
        let identity = try identity()
        var validator = ClaudeCodeHookReportValidator(identity: identity)
        // Foreign launch token: cannot relabel another launch.
        let foreignLaunch = try ClaudeCodeHookReport(
            event: .stop, sessionID: Self.sessionID, launchToken: "other-token-0123456789",
            toolName: nil, subagent: false, historical: false
        )
        #expect(validator.validate(foreignLaunch) == .failure(.foreignLaunch))
        // Foreign session: cannot relabel another session.
        let foreignSession = try ClaudeCodeHookReport(
            event: .stop, sessionID: "other-session", launchToken: Self.token,
            toolName: nil, subagent: false, historical: false
        )
        #expect(validator.validate(foreignSession) == .failure(.foreignSession))
        // Nested: subagent reports are rejected for the main-session binding.
        let nested = try ClaudeCodeHookReport(
            event: .stop, sessionID: Self.sessionID, launchToken: Self.token,
            toolName: nil, subagent: true, historical: false
        )
        #expect(validator.validate(nested) == .failure(.nested))
        // Valid live report.
        let live = try ClaudeCodeHookReport(
            event: .sessionStart, sessionID: Self.sessionID, launchToken: Self.token,
            toolName: nil, subagent: false, historical: false
        )
        guard case .success = validator.validate(live) else {
            throw ClaudeCodeHookError.invalidIdentity
        }
        // After SessionEnd the session is over: everything else is stale.
        let ended = try ClaudeCodeHookReport(
            event: .sessionEnd, sessionID: Self.sessionID, launchToken: Self.token,
            toolName: nil, subagent: false, historical: false
        )
        guard case .success = validator.validate(ended) else {
            throw ClaudeCodeHookError.invalidIdentity
        }
        let stale = try ClaudeCodeHookReport(
            event: .stop, sessionID: Self.sessionID, launchToken: Self.token,
            toolName: nil, subagent: false, historical: false
        )
        #expect(validator.validate(stale) == .failure(.stale))
        // Tool events without a tool name are malformed for the allowlist.
        let noTool = try ClaudeCodeHookReport(
            event: .postToolUse, sessionID: Self.sessionID, launchToken: Self.token,
            toolName: nil, subagent: false, historical: false
        )
        #expect(validator.validate(noTool) == .failure(.missingToolName))
    }

    @Test func historicalReportsCannotCreateCurrentState() throws {
        // Spooled/replayed reports carry the historical flag and are accepted
        // as observations only; the model has no path from a historical
        // report to a lifecycle candidate, blocked, idle, or Ready state.
        let line = envelope("Stop")
        guard case .success(let report) = ClaudeCodeHookEnvelope.parse(data: Data(line.utf8), historical: true) else {
            throw ClaudeCodeHookError.invalidEvent
        }
        #expect(report.historical)
        let identity = try identity()
        var validator = ClaudeCodeHookReportValidator(identity: identity)
        guard case .success(let accepted) = validator.validate(report) else {
            throw ClaudeCodeHookError.invalidIdentity
        }
        #expect(accepted.historical)
    }

    @Test func installationPlanRefusesGlobalTargets() throws {
        let plan = try ClaudeCodeHookInstallationPlan(
            events: [.sessionStart, .sessionEnd, .stop, .preToolUse, .postToolUse]
        )
        #expect(plan.targetRelativePath == ".claude/settings.local.json")
        #expect(plan.events == [.postToolUse, .preToolUse, .sessionEnd, .sessionStart, .stop])
        #expect(plan.preview.contains(".claude/settings.local.json"))
        #expect(plan.preview.contains("SessionStart"))
        #expect(plan.preview.contains("reporting only"))
        for global in ["~/.claude/settings.json", ".claude/settings.json", "managed/settings.json"] {
            #expect(throws: ClaudeCodeHookInstallationPlan.TargetError.self) {
                _ = try ClaudeCodeHookInstallationPlan(
                    events: [.stop], targetRelativePath: global
                )
            }
        }
        #expect(throws: ClaudeCodeHookInstallationPlan.TargetError.self) {
            _ = try ClaudeCodeHookInstallationPlan(events: [])
        }
    }

    @Test func identityValidationIsStrict() {
        #expect(throws: ClaudeCodeHookError.invalidIdentity) {
            _ = try ClaudeCodeHookLaunchIdentity(launchToken: "short", sessionID: Self.sessionID)
        }
        #expect(throws: ClaudeCodeHookError.invalidIdentity) {
            _ = try ClaudeCodeHookLaunchIdentity(
                launchToken: String(repeating: "a", count: 257), sessionID: Self.sessionID
            )
        }
        #expect(throws: ClaudeCodeHookError.invalidSession) {
            _ = try ClaudeCodeHookLaunchIdentity(launchToken: Self.token, sessionID: "")
        }
        #expect(throws: ClaudeCodeHookError.invalidSession) {
            _ = try ClaudeCodeHookLaunchIdentity(
                launchToken: Self.token, sessionID: "bad" + "\n" + "session"
            )
        }
    }
}

private enum ClaudeHookOutcome: Equatable {
    case unauthenticated, unsupportedEvent, foreignLaunch, foreignSession, nested,
        stale, missingToolName, success

    init(_ result: Result<ClaudeCodeHookReport, ClaudeCodeHookReportRejection>) {
        switch result {
        case .success: self = .success
        case .failure(let rejection): self = rejection.outcome
        }
    }
}

private extension ClaudeCodeHookReportRejection {
    var outcome: ClaudeHookOutcome {
        switch self {
        case .unauthenticated: .unauthenticated
        case .unsupportedEvent: .unsupportedEvent
        case .foreignLaunch: .foreignLaunch
        case .foreignSession: .foreignSession
        case .nested: .nested
        case .stale: .stale
        case .missingToolName: .missingToolName
        }
    }
}
