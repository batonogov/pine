import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("Kimi ACP session state machine")
struct KimiACPSessionTests {
    private func makeFixture(
        options: KimiFixtureOptions = .init(),
        sessionID: String = "kimi_fixture_new"
    ) async throws -> (fixture: KimiTestFixture, events: KimiSinkCollector) {
        let events = KimiSinkCollector()
        let fixture = try await KimiTestFixture.make(
            options: options, sessionID: sessionID,
            ingest: { await events.ingest($0) }
        )
        return (fixture, events)
    }

    @Test func startBindsSessionAndRecordsEffectiveConfig() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let snapshot = await fixture.concrete.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.nativeSession?.rawValue == "kimi_fixture_new")
        #expect(snapshot.effectiveConfig.map(\.kind) == [.select, .unknown])
        #expect(snapshot.ready == false)
        #expect(snapshot.settlementKnown == false)
    }

    @Test func accountGateBlocksSessionCreationWithoutVerifiedAuth() async throws {
        let fixture = try await makeFixture(
            options: .init(accountGate: { false })
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        await #expect(throws: KimiACPWireError.authenticationRequired) {
            try await fixture.session.start()
        }
    }

    @Test func loadReplaysBoundedHistoryWithoutProjectingIt() async throws {
        let fixture = try await makeFixture(
            options: .init(action: .load(sessionID: "kimi_fixture_src"))
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let snapshot = await fixture.concrete.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.nativeSession?.rawValue == "kimi_fixture_src")
        #expect(snapshot.result.isEmpty)
    }

    @Test func loadRejectsForeignSessionReplay() async throws {
        // The scripted provider replays under its own sessionID; a load of a
        // different source must fail closed on the mismatch.
        let fixture = try await makeFixture(
            options: .init(action: .load(sessionID: "kimi_fixture_src"), foreignReplay: true),
            sessionID: "kimi_fixture_other"
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        await #expect(throws: KimiACPWireError.invalidProtocol) {
            try await fixture.session.start()
        }
    }

    @Test func loadFailureSurfacesAsProviderFailure() async throws {
        let fixture = try await makeFixture(
            options: .init(action: .load(sessionID: "kimi_fixture_src"), rejectLoad: true)
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        await #expect(throws: KimiACPWireError.providerFailure(-32602)) {
            try await fixture.session.start()
        }
    }

    @Test func resumeRejectsHistoryReplay() async throws {
        var options = KimiFixtureOptions(action: .resume(sessionID: "kimi_fixture_src"))
        options.replayOnResume = true
        let fixture = try await KimiTestFixture.make(
            options: options, sessionID: "kimi_fixture_new"
        ) { _ in .accepted }
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        await #expect(throws: KimiACPWireError.invalidProtocol) {
            try await fixture.session.start()
        }
    }

    @Test func forkSendsOnlyTheSourceSessionID() async throws {
        let fixture = try await makeFixture(
            options: .init(action: .fork(sessionID: "kimi_fixture_src")),
            sessionID: "kimi_fixture_src"
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let snapshot = await fixture.concrete.snapshot()
        #expect(snapshot.nativeSession?.rawValue == "kimi_fixture_src_forked")
        let fork = try #require(fixture.transport.writes().first(where: { message in
            if case .request(_, "session/fork", _) = message { return true }
            return false
        }))
        let params = try KimiACPWire.object(fork.params)
        #expect(params["sessionId"] == .string("kimi_fixture_src"))
        #expect(params["cwd"] == nil)
        #expect(params["mcpServers"] == nil)
        #expect(params["additionalDirectories"] == nil)
    }

    @Test func additionalDirectoriesAreSentOnlyOnNewSessions() async throws {
        let fixture = try await makeFixture(
            options: .init(action: .new(additionalDirectories: ["/fixture/shared"])),
            sessionID: "kimi_fixture_new"
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let creation = try #require(fixture.transport.writes().first(where: { message in
            if case .request(_, "session/new", _) = message { return true }
            return false
        }))
        let params = try KimiACPWire.object(creation.params)
        #expect(params["additionalDirectories"] == .array([.string("/fixture/shared")]))
    }

    @Test func promptFlowProjectsWorkingAndSettlesUnverified() async throws {
        let (fixture, events) = try await makeFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(
            KimiACPPromptContent(text: "Fixture instruction")
        )
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(.notification(method: "session/update", params: .object([
            "sessionId": .string("kimi_fixture_new"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("fixture-output")])
            ])
        ])))
        _ = try await wait(fixture) { $0.state == .working }
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        let settled = try await wait(fixture) { $0.state == .unverified }
        #expect(settled.result == "fixture-output")
        #expect(settled.parentOutcome == .unverified)
        #expect(settled.ready == false)
        let observed = events.value
        #expect(!observed.isEmpty)
        for event in observed {
            guard case .lifecycle(let lifecycle) = event.candidate.event else {
                Issue.record("Only working lifecycle candidates may be projected"); return
            }
            #expect(lifecycle.phase == .working)
        }
    }

    @Test func imageAndResourceContentRequireExplicitCapabilityAndUserSupply() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let dispatch = try await fixture.concrete.submit(
            KimiACPPromptContent(
                text: "Fixture instruction",
                images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))],
                resources: [.init(uri: "file:///fixture/doc.md", text: "Fixture doc")]
            )
        )
        #expect(dispatch == .acknowledged)
        let prompt = try #require(try fixture.transport.lastWrite {
            if case .request(_, "session/prompt", _) = $0 { return true }
            return false
        })
        let params = try KimiACPWire.object(prompt.params)
        guard case .array(let blocks)? = params["prompt"] else {
            Issue.record("Expected prompt content blocks"); return
        }
        #expect(blocks.count == 3)
        #expect(try KimiACPWire.object(blocks[1])["type"] == .string("image"))
        #expect(try KimiACPWire.object(blocks[2])["type"] == .string("resource"))
    }

    @Test func capabilityGatedContentIsRefusedBeforeSubmission() async throws {
        let fixture = try await makeFixture(
            options: .init(imageCapability: false, embeddedContextCapability: false)
        ).fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        await #expect(throws: KimiACPWireError.unsupportedCapability) {
            _ = try await fixture.concrete.submit(
                KimiACPPromptContent(
                    text: "Fixture instruction",
                    images: [.init(mimeType: "image/png", data: Data([1]))]
                )
            )
        }
        await #expect(throws: KimiACPWireError.unsupportedCapability) {
            _ = try await fixture.concrete.submit(
                KimiACPPromptContent(
                    text: "Fixture instruction",
                    resources: [.init(uri: "file:///fixture/doc.md", text: "Fixture doc")]
                )
            )
        }
        // No prompt crossed the wire for either refused submission.
        #expect(try fixture.transport.promptRequestIDs.isEmpty)
    }

    @Test func cancelIsRequestedUntilProviderConfirms() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        _ = try await fixture.concrete.cancel()
        let requested = await fixture.concrete.snapshot()
        #expect(requested.state == .cancelRequested)
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("cancelled")])))
        let confirmed = try await wait(fixture) { $0.state == .cancelled }
        #expect(confirmed.state == .cancelled)
        #expect(confirmed.parentOutcome == .cancelled)
    }

    @Test func cancelAnswersPendingRequestsWithCancelledOutcome() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(permission(wireID: 40))
        _ = try await wait(fixture) { $0.state == .waiting && $0.questions.count == 1 }
        _ = try await fixture.concrete.cancel()
        let cancelled = try await wait(fixture) { $0.state == .cancelRequested }
        #expect(cancelled.questions.isEmpty)
        #expect(try fixture.transport.lastWrite { message in
            guard case .response(.integer(40), let result) = message else { return false }
            let fields = (try? KimiACPWire.object(result)) ?? [:]
            return fields["outcome"] == .object(["outcome": .string("cancelled")])
        } != nil)
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("cancelled")])))
        _ = try await wait(fixture) { $0.state == .cancelled }
    }

    @Test func answeredRequestsAreOneShotAndReplayedIdempotently() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(permission(wireID: 41))
        let waiting = try await wait(fixture) { $0.state == .waiting && $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        let answer = try await fixture.concrete.answerPermission(
            question.request, context: question.context, decision: .allowOnce
        )
        #expect(answer == .acknowledged)
        let answerWrite = try #require(try fixture.transport.lastWrite {
            if case .response(.integer(41), _) = $0 { return true }
            return false
        })
        // Redelivery replays the exact cached bytes and does not re-open the ask.
        fixture.transport.push(permission(wireID: 41))
        _ = try await wait(fixture) { _ in
            ((try? fixture.transport.writes().filter { $0 == answerWrite }.count) ?? 0) >= 2
        }
        let replayed = try #require(try fixture.transport.lastWrite { $0 == answerWrite })
        #expect(replayed == answerWrite)
        // A second answer attempt must fail: one-shot.
        await #expect(throws: KimiACPWireError.self) {
            _ = try await fixture.concrete.answerPermission(
                question.request, context: question.context, decision: .allowOnce
            )
        }
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        _ = try await wait(fixture) { $0.state == .unverified }
    }

    @Test func staleAndUnsupportedRequestsAreRejectedNotAnswered() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        _ = try await wait(fixture) { $0.state == .unverified }
        // Stale: a permission request with no active prompt.
        fixture.transport.push(permission(wireID: 42))
        _ = try await wait(fixture) { _ in rejectsWrite(fixture, wireID: 42) }
        #expect(rejectsWrite(fixture, wireID: 42))
        // Unsupported reverse-RPC: fs is not owned by Pine.
        fixture.transport.push(.request(.integer(43), method: "fs/read_text_file", params: .object([
            "sessionId": .string("kimi_fixture_new"), "path": .string("/fixture/file.txt")
        ])))
        _ = try await wait(fixture) { _ in rejectsWrite(fixture, wireID: 43) }
        #expect(rejectsWrite(fixture, wireID: 43))
        #expect((await fixture.concrete.snapshot()).state == .unverified)
    }

    @Test func channelLossMidPromptIsUnknownNeverClean() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        _ = try await wait(fixture) { $0.state == .submitted || $0.state == .working }
        fixture.transport.close()
        let lost = try await wait(fixture) { $0.state == .unknown || $0.state == .stopped }
        #expect(lost.state == .unknown)
        #expect(lost.result == "fixture-output" || lost.result.isEmpty)
        // No clean re-open: input on a lost channel is refused.
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture again"))
        }
    }

    @Test func inFlightPromptRefusesASecondSubmit() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        _ = try await wait(fixture) { $0.state == .submitted }
        await #expect(throws: KimiACPWireError.self) {
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture duplicate"))
        }
    }

    @Test func urlModeElicitationIsRejectedSoProviderFallsBack() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(.request(.integer(44), method: "elicitation/create", params: .object([
            "sessionId": .string("kimi_fixture_new"), "mode": .string("url"),
            "elicitationId": .string("fixture-oauth"),
            "url": .string("https://fixture.example/authorize"),
            "message": .string("Fixture authorize")
        ])))
        _ = try await wait(fixture) { _ in rejectsWrite(fixture, wireID: 44) }
        #expect(rejectsWrite(fixture, wireID: 44))
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        _ = try await wait(fixture) { $0.state == .unverified }
    }

    @Test func secretBearingPayloadsNeverSurfaceInReflection() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(.request(.integer(45), method: "session/request_permission", params: .object([
            "sessionId": .string("kimi_fixture_new"),
            "toolCall": .object([
                "toolCallId": .string("tool_fixture_5"),
                "title": .string("Fixture secret"), "kind": .string("other"),
                "rawInput": .object(["token": .string("FIXTURE_SECRET_MARKER")])
            ]),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                         "kind": .string("reject_once")])
            ])
        ])))
        let waiting = try await wait(fixture) { $0.state == .waiting }
        let snapshot = waiting
        let reflection = String(reflecting: fixture.concrete)
            + String(reflecting: snapshot)
            + snapshot.questions.map { String(reflecting: $0) }.joined()
        #expect(!reflection.contains("FIXTURE_SECRET_MARKER"))
        #expect(!reflection.contains("tool_fixture_5"))
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        _ = try await wait(fixture) { $0.state == .unknown || $0.state == .waiting || $0.state == .unverified }
    }

    @Test func cancelledSettleAllowsResubmission() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        _ = try await fixture.concrete.cancel()
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("cancelled")])))
        _ = try await wait(fixture) { $0.state == .cancelled }
        // The confirmed cancellation is turn-scoped: a new prompt on the same
        // attempt is a new turn, never invalidState.
        let resubmit = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture again"))
        #expect(resubmit == .acknowledged)
        _ = try await wait(fixture) { $0.state == .submitted }
    }

    @Test func openAskAtTurnEndFencesUnknown() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(permission(wireID: 47))
        _ = try await wait(fixture) { $0.state == .waiting && $0.questions.count == 1 }
        // The turn settles while the ask is still open: with no active prompt
        // the ask is unanswerable, so the channel must fence unknown, not a
        // dead .waiting.
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        // Wait for the fence AND the completed teardown: settle sets
        // `.unknown` before `loseConnection()` finishes, so the closed
        // transport is the completion evidence.
        let settled = try await wait(fixture) {
            $0.state == .unknown && (try? fixture.transport.validate()) == nil
        }
        #expect(settled.state == .unknown)
        #expect(throws: KimiACPWireError.self) { try fixture.transport.validate() }
    }

    @Test func truncatedResultKeepsHeadAndFlags() async throws {
        let fixture = try await makeFixture().fixture
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        // 65 × 1 KB = 66 KB > the 64 KB presentation cap; the head survives.
        for _ in 0..<65 {
            fixture.transport.push(.notification(method: "session/update", params: .object([
                "sessionId": .string("kimi_fixture_new"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"),
                                        "text": .string(String(repeating: "a", count: 1_024))])
                ])
            ])))
        }
        let capped = try await wait(fixture) { $0.state == .working && $0.resultTruncated }
        #expect(capped.resultTruncated)
        #expect(capped.result.utf8.count <= KimiACPPromptContent.maximumTextBytes)
        #expect(capped.result.hasPrefix(String(repeating: "a", count: 1_024)))
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        let settled = try await wait(fixture) { $0.state == .unverified }
        #expect(settled.resultTruncated)
        #expect(settled.result.utf8.count <= KimiACPPromptContent.maximumTextBytes)
    }

    @Test func stopTearsDownTransportAndFencesQuestions() async throws {
        let fixture = try await makeFixture().fixture
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
        fixture.transport.push(permission(wireID: 46))
        _ = try await wait(fixture) { $0.state == .waiting }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        let stopped = await fixture.concrete.snapshot()
        #expect(stopped.state == .stopped)
        #expect(stopped.questions.isEmpty)
        #expect(throws: KimiACPWireError.self) { try fixture.transport.validate() }
    }

    nonisolated private func rejectsWrite(_ fixture: KimiTestFixture, wireID: Int64) -> Bool {
        guard let rejected = try? fixture.transport.lastWrite(matching: { message in
            if case .failure(let id, let code) = message {
                return id == .integer(wireID) && code == -32601
            }
            return false
        }) else { return false }
        return rejected != nil
    }

    private func permission(wireID: Int64) -> CodexAppServerMessage {
        .request(.integer(wireID), method: "session/request_permission", params: .object([
            "sessionId": .string("kimi_fixture_new"),
            "toolCall": .object([
                "toolCallId": .string("tool_fixture_p"), "title": .string("Fixture write"),
                "kind": .string("edit")
            ]),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                         "kind": .string("reject_once")])
            ])
        ]))
    }

    private func wait(_ fixture: KimiTestFixture,
                      until predicate: @Sendable (KimiACPSession.Snapshot) -> Bool) async throws
        -> KimiACPSession.Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let snapshot = await fixture.concrete.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw KimiACPWireError.unavailable
    }
}
