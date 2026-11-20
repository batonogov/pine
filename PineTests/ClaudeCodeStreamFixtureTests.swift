import Foundation
import Testing
@testable import Pine

/// Runs the sanitized owned-stream and hook-report fixtures (#1727) through
/// the real codec. Fixtures contain no prompts, tool inputs, assistant text,
/// transcripts, environment values, credentials, or repository paths; the
/// redaction assertions below prove the codec does not retain them either.
struct ClaudeCodeStreamFixtureTests {
    private let droppedMarkers = [
        "FIXTURE-TEXT", "FIXTURE-INPUT", "FIXTURE-RESULT", "FIXTURE-RESULT-TEXT",
        "FIXTURE-HOOK-OUTPUT"
    ]

    private func fixtureURL(_ name: String) throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AgentAdapters/\(name)")
    }

    @Test func ownedStreamFixtureCasesMatchExpectedKinds() throws {
        let data = try Data(contentsOf: try fixtureURL("claude-stream-control-v1.json"))
        let fixture = try JSONDecoder().decode(StreamFixture.self, from: data)
        #expect(!fixture.cases.isEmpty)
        for fixtureCase in fixture.cases {
            var framer = ClaudeCodeStreamFramer()
            do {
                var classified = "unparsed"
                try framer.receive(Data((fixtureCase.wire + "\n").utf8)) { message in
                    classified = Self.classify(message)
                }
                if fixtureCase.expect == "invalid" {
                    Issue.record("Fixture '\(fixtureCase.name)' parsed but expected invalid")
                } else if classified != fixtureCase.expect {
                    Issue.record("Fixture '\(fixtureCase.name)' classified \(classified), expected \(fixtureCase.expect)")
                }
            } catch {
                guard fixtureCase.expect == "invalid" else {
                    Issue.record("Fixture '\(fixtureCase.name)' threw unexpectedly")
                    continue
                }
                #expect(framer.isClosed)
            }
        }
    }

    @Test func parsedMessagesNeverRetainFixtureContent() throws {
        let data = try Data(contentsOf: try fixtureURL("claude-stream-control-v1.json"))
        let fixture = try JSONDecoder().decode(StreamFixture.self, from: data)
        for fixtureCase in fixture.cases {
            guard let message = try? ClaudeCodeStreamMessage.parse(data: Data(fixtureCase.wire.utf8)) else {
                continue
            }
            let rendered = String(describing: message)
            for marker in droppedMarkers {
                #expect(!rendered.contains(marker), "Codec retained fixture content in \(marker)")
            }
        }
    }

    @Test func hookReportFixtureCasesMatchExpectedOutcomes() throws {
        let data = try Data(contentsOf: try fixtureURL("claude-hook-reports-v1.json"))
        let fixture = try JSONDecoder().decode(HookFixture.self, from: data)
        #expect(!fixture.cases.isEmpty)
        let identity = try ClaudeCodeHookLaunchIdentity(
            launchToken: fixture.launchToken, sessionID: fixture.sessionID
        )
        for fixtureCase in fixture.cases {
            let validatorResult: Result<ClaudeCodeHookReport, ClaudeCodeHookReportRejection>
            switch ClaudeCodeHookEnvelope.parse(data: Data(fixtureCase.wire.utf8),
                                                 historical: fixtureCase.historical) {
            case .success(let report):
                var validator = ClaudeCodeHookReportValidator(identity: identity)
                validatorResult = validator.validate(report)
            case .failure(let rejection):
                validatorResult = .failure(rejection)
            }
            let outcome = Self.classifyHook(validatorResult)
            guard outcome == fixtureCase.expect else {
                Issue.record("Hook fixture '\(fixtureCase.name)' classified \(outcome), expected \(fixtureCase.expect)")
                continue
            }
            if case .success(let report) = validatorResult {
                for marker in droppedMarkers {
                    #expect(!String(describing: report).contains(marker))
                }
            }
        }
    }

    private static func classify(_ message: ClaudeCodeStreamMessage) -> String {
        switch message {
        case .systemInit: "systemInit"
        case .assistant: "assistant"
        case .userToolResults: "userToolResults"
        case .result(_, let subtype): subtype == .success ? "result-success" : "result-error"
        case .permissionRequest: "permissionRequest"
        case .controlResponseSuccess(_, _, _, _, _, interruptReceipt: let receipt):
            receipt == nil ? "controlResponseSuccess" : "interruptReceipt"
        case .controlResponseError: "controlResponseError"
        case .permissionDenied: "permissionDenied"
        case .unsupportedControlRequest, .dataOnly: "dataOnly"
        }
    }

    private static func classifyHook(
        _ result: Result<ClaudeCodeHookReport, ClaudeCodeHookReportRejection>
    ) -> String {
        switch result {
        case .success(let report): report.historical ? "historical" : "live"
        case .failure(.unauthenticated): "unauthenticated"
        case .failure(.foreignSession): "foreignSession"
        case .failure(.foreignLaunch): "foreignLaunch"
        case .failure(.nested): "nested"
        case .failure(.stale): "stale"
        case .failure(.unsupportedEvent): "unsupportedEvent"
        case .failure(.missingToolName): "missingToolName"
        }
    }
}

private struct StreamFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let wire: String
        let expect: String
    }
    let cases: [Case]
}

private struct HookFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let wire: String
        let historical: Bool
        let expect: String
    }
    let launchToken: String
    let sessionID: String
    let cases: [Case]
}
