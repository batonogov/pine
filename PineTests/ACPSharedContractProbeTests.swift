import Foundation
import Testing
@testable import Pine

/// #1846 shared contract probe: the same `AgentProviderContractSuite`
/// scenario table driven through BOTH ACP v1 transports — OpenCode
/// (merged #1843/#1811) and Kimi (merged #1732) — against their real wire
/// codec, connection bookkeeping, and session actors. Outcomes are recorded
/// as honest test expectations: a drive that diverges from the shared
/// contract is `.fail`, a documented transport capability difference is
/// `.unsupported(reason)`, never a silent skip.
///
/// This is the deterministic CI gate. Real-binary evidence stays with the
/// per-provider opt-in smokes (`KimiACPSmokeTests`,
/// `OpenCodeACPNativeSmokeTests`); the dated run results are recorded in
/// `docs/ade-acp-reuse-comparison-2026-11-23.md` section 7.
struct ACPSharedContractProbeTests {
    /// A drive reached a state the shared contract forbids.
    private enum Divergence: Error { case expected(String) }

    private func expectDivergenceFree(
        _ scenario: String, into table: inout [String: AgentProviderContractOutcome],
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            table[scenario] = .pass
        } catch {
            table[scenario] = .fail("\(scenario) drive diverged: \(type(of: error))")
        }
    }

    @Test func sharedContractRunsThroughBothACPTransports() async throws {
        var openCode: [String: AgentProviderContractOutcome] = [:]
        var kimi: [String: AgentProviderContractOutcome] = [:]

        await driveOpenCode(into: &openCode)
        await driveKimi(into: &kimi)

        expectProviderContractOutcomes(openCode, provider: "OpenCode")
        expectProviderContractOutcomes(kimi, provider: "Kimi")

        // Cross-transport parity: both ACP v1 transports classify every
        // scenario the same way (pass/unsupported). A divergence is a real
        // contract finding, not noise.
        for scenario in AgentProviderContractSuite.scenarios {
            let left = Self.classify(openCode[scenario.id])
            let right = Self.classify(kimi[scenario.id])
            #expect(left == right, Comment(rawValue:
                "Scenario '\(scenario.name)' classifies differently across transports: "
                + "OpenCode=\(left) Kimi=\(right)"))
        }
    }

    private static func classify(_ outcome: AgentProviderContractOutcome?) -> String {
        switch outcome {
        case .pass: "pass"
        case .unsupported: "unsupported"
        case .fail, nil: "fail"
        }
    }

    // MARK: - OpenCode drives

    private func driveOpenCode(into table: inout [String: AgentProviderContractOutcome]) async {
        await expectDivergenceFree("question", into: &table) {
            try await self.opencodeQuestion()
        }
        await expectDivergenceFree("approval", into: &table) {
            try await self.opencodeApproval()
        }
        await expectDivergenceFree("continuation", into: &table) {
            try await self.opencodeContinuation()
        }
        await expectDivergenceFree("cancellation", into: &table) {
            try await self.opencodeCancellation()
        }
        await expectDivergenceFree("malformed-duplicate-stale", into: &table) {
            try await self.opencodeMalformedDuplicateStale()
        }
        await expectDivergenceFree("reconnect", into: &table) {
            // The loss evidence must still fence unknown; the recovery half
            // (ordered replay after a gap) is what stays unsupported.
            try await self.opencodeLossFencesUnknown()
        }
        if table["reconnect"] == .pass {
            table["reconnect"] = .unsupported(
                "ACP v1 transport loss has no ordered replay; exact explicit load is a new "
                + "attempt and never restores pending delivery"
            )
        }
        await expectDivergenceFree("relaunch", into: &table) {
            try await self.opencodeRelaunch()
        }
        await expectDivergenceFree("evidence-fencing", into: &table) {
            try await self.opencodeEvidenceFencing()
        }
        await expectDivergenceFree("backpressure", into: &table) {
            try await self.opencodeBackpressure()
        }
        await expectDivergenceFree("secret-bearing-payloads", into: &table) {
            try await self.opencodeSecretBearingPayloads()
        }
    }

    private func opencodeQuestion() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        guard try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
                == .acknowledged else { throw Divergence.expected("submit not acknowledged") }
        fixture.transport.push(.request(.string("probe-ask"), method: "elicitation/create",
                                        params: opencodeForm()))
        let waiting = try await waitOpenCode(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        guard try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {}) == .acknowledged else { throw Divergence.expected("answer not acknowledged") }
        do {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["blue"]]
            ), beforeDispatch: {})
            throw Divergence.expected("duplicate answer accepted")
        } catch is OpenCodeACPError {}
        fixture.transport.push(opencodeToolCompletion("question-tool"))
        _ = try await waitOpenCode(fixture.concrete) { $0.answersAwaitingEvidence == 0 }
        fixture.transport.push(opencodeChunk("Probe result"))
        fixture.transport.push(opencodeEndTurn())
        let settled = try await waitOpenCode(fixture.concrete) { $0.state == .unverified }
        guard settled.result == "Probe result", !settled.ready, !settled.settlementKnown else {
            throw Divergence.expected("settlement drifted")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeApproval() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Write"), beforeDispatch: {})
        let permissionFrame = CodexAppServerMessage.request(
            .integer(20), method: "session/request_permission", params: opencodePermission()
        )
        fixture.transport.push(permissionFrame)
        let waiting = try await waitOpenCode(fixture.concrete) { !$0.questions.isEmpty }
        let question = try #require(waiting.questions.first)
        guard question.permission else { throw Divergence.expected("not a permission question") }
        guard try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .deny
        ), beforeDispatch: {}) == .acknowledged else { throw Divergence.expected("deny not acknowledged") }
        guard try fixture.transport.writes().contains(.response(.integer(20), result: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("reject")])
        ]))) else { throw Divergence.expected("deny response not written") }
        // One-shot: redelivery of an answered request fences, never re-answers.
        fixture.transport.push(permissionFrame)
        let fenced = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
        guard !fenced.ready, fenced.questions.isEmpty else {
            throw Divergence.expected("redelivery re-opened the ask")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeContinuation() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("First turn"), beforeDispatch: {})
        fixture.transport.push(opencodeChunk("First result"))
        fixture.transport.push(opencodeEndTurn())
        _ = try await waitOpenCode(fixture.concrete) { $0.state == .unverified }
        guard try await controls.dispatch(.submitInstruction("Continuation"), beforeDispatch: {})
                == .acknowledged else { throw Divergence.expected("continuation refused") }
        let prompts = try fixture.transport.writes().compactMap { message -> AgentEventJSON? in
            guard case .request(_, "session/prompt", let params) = message else { return nil }
            return params
        }
        guard prompts.count == 2, prompts.allSatisfy({
            (try? OpenCodeACPWire.object($0))?["sessionId"] == .string("ses_fixture")
        }) else { throw Divergence.expected("continuation did not reuse the exact session") }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeCancellation() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Wait"), beforeDispatch: {})
        let started = await fixture.concrete.snapshot()
        let context = try #require(started.context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        guard await fixture.concrete.snapshot().state == .cancelRequested else {
            throw Divergence.expected("cancellation not requested")
        }
        // Queued input is never auto-resent: the turn is still in flight.
        do {
            _ = try await controls.dispatch(.submitInstruction("Queued"), beforeDispatch: {})
            throw Divergence.expected("queued input sent while cancellation pending")
        } catch is OpenCodeACPError {}
        // Late completion after cancel is a race, never success.
        fixture.transport.push(opencodeEndTurn())
        let unknown = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
        guard !unknown.ready else { throw Divergence.expected("late completion claimed ready") }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeMalformedDuplicateStale() async throws {
        // Malformed: the shared ACP-strict framer fences ingress.
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        guard (try? framer.receive(Data("garbage-not-json\n".utf8)) { _ in }) == nil,
              framer.isClosed else { throw Divergence.expected("malformed frame not fenced") }
        // Duplicate: a second settlement response fences, never re-settles.
        do {
            let fixture = try await makeOpenCodeACPTestFixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
            fixture.transport.push(opencodeEndTurn())
            fixture.transport.push(opencodeEndTurn())
            let unknown = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
            guard !unknown.ready else { throw Divergence.expected("duplicate settlement accepted") }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        // Stale/foreign: traffic for another session never creates state.
        do {
            let fixture = try await makeOpenCodeACPTestFixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
            fixture.transport.push(.notification(method: "session/update", params: .object([
                "sessionId": .string("ses_foreign"), "update": .object(
                    ["sessionUpdate": .string("tool_call")])
            ])))
            let unknown = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
            guard !unknown.ready, unknown.result.isEmpty else {
                throw Divergence.expected("foreign traffic created state")
            }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
    }

    private func opencodeLossFencesUnknown() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
        fixture.transport.push(.request(.integer(21), method: "session/request_permission",
                                        params: opencodePermission()))
        _ = try await waitOpenCode(fixture.concrete) { $0.state == .waiting }
        fixture.transport.close()
        let lost = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
        // Never "no pending" as a clean state: the ask is fenced, not dropped
        // into a settled snapshot.
        guard !lost.ready, lost.cancellationRequested == false else {
            throw Divergence.expected("loss did not fence unknown")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeRelaunch() async throws {
        // Attempt 1: a full turn on the first attempt namespace.
        do {
            let fixture = try await makeOpenCodeACPTestFixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("First attempt"), beforeDispatch: {})
            fixture.transport.push(opencodeChunk("Done"))
            fixture.transport.push(opencodeEndTurn())
            _ = try await waitOpenCode(fixture.concrete) { $0.state == .unverified }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        // Attempt 2: a new process is a new attempt; nothing reattaches or
        // resumes the old session.
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let writes = try fixture.transport.writes()
        guard writes.count == 2,
              writes.allSatisfy({
                  switch $0 {
                  case .request(_, "initialize", _), .request(_, "session/new", _): true
                  default: false
                  }
              }) else {
            throw Divergence.expected("relaunch wrote load/resume or extra frames")
        }
        guard await fixture.concrete.snapshot().state == .idle else {
            throw Divergence.expected("relaunch did not start idle")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeEvidenceFencing() async throws {
        let marker = "PROBE_EVIDENCE_MARKER-\(UUID().uuidString)"
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Fence"), beforeDispatch: {})
        fixture.transport.push(opencodeChunk(marker))
        fixture.transport.push(opencodeEndTurn())
        _ = try await waitOpenCode(fixture.concrete) { $0.state == .unverified }
        let snapshot = await fixture.concrete.snapshot()
        // Foreign-session fencing is asserted in malformed-duplicate-stale;
        // here: provider payloads never surface through shared reflection.
        let reflection = String(reflecting: fixture.concrete)
            + String(reflecting: snapshot)
            + String(reflecting: fixture.transport)
        guard !reflection.contains(marker) else {
            throw Divergence.expected("payload leaked into reflection")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeBackpressure() async throws {
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
        for index in 0..<16 {
            fixture.transport.push(.request(.string("probe-q-\(index)"),
                                            method: "elicitation/create", params: opencodeForm()))
        }
        let pending = try await waitOpenCode(fixture.concrete) { $0.questions.count == 16 }
        guard pending.state == .waiting else {
            throw Divergence.expected("sixteen asks did not hold .waiting")
        }
        // The 17th pending ask exceeds the bound and fails closed.
        fixture.transport.push(.request(.string("probe-q-16"),
                                        method: "elicitation/create", params: opencodeForm()))
        let unknown = try await waitOpenCode(fixture.concrete) { $0.state == .unknown }
        guard !unknown.ready else { throw Divergence.expected("capacity fence not fail-closed") }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func opencodeSecretBearingPayloads() async throws {
        let marker = "PROBE_SECRET_MARKER-\(UUID().uuidString)"
        let fixture = try await makeOpenCodeACPTestFixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Secret turn"), beforeDispatch: {})
        fixture.transport.push(opencodeChunk(marker))
        fixture.transport.push(opencodeEndTurn())
        _ = try await waitOpenCode(fixture.concrete) { $0.state == .unverified }
        let snapshot = await fixture.concrete.snapshot()
        // Retention is bounded session presentation, never codec/mapper state.
        guard snapshot.result.utf8.count <= 65_536,
              !String(reflecting: fixture.concrete).contains(marker),
              !String(reflecting: snapshot).contains(marker),
              !String(reflecting: fixture.transport).contains(marker) else {
            throw Divergence.expected("secret retained unbounded or in shared state")
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func waitOpenCode(_ session: OpenCodeACPSession,
                              until predicate: @Sendable (OpenCodeACPSession.Snapshot) -> Bool) async throws
        -> OpenCodeACPSession.Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeACPError.unavailable
    }

    // MARK: - Kimi drives

    private func driveKimi(into table: inout [String: AgentProviderContractOutcome]) async {
        await expectDivergenceFree("question", into: &table) { try await self.kimiQuestion() }
        await expectDivergenceFree("approval", into: &table) { try await self.kimiApproval() }
        await expectDivergenceFree("continuation", into: &table) { try await self.kimiContinuation() }
        await expectDivergenceFree("cancellation", into: &table) { try await self.kimiCancellation() }
        await expectDivergenceFree("malformed-duplicate-stale", into: &table) {
            try await self.kimiMalformedDuplicateStale()
        }
        await expectDivergenceFree("reconnect", into: &table) { try await self.kimiLossFencesUnknown() }
        if table["reconnect"] == .pass {
            table["reconnect"] = .unsupported(
                "ACP v1 transport loss has no ordered replay; exact explicit load is a new "
                + "attempt and never restores pending delivery"
            )
        }
        await expectDivergenceFree("relaunch", into: &table) { try await self.kimiRelaunch() }
        await expectDivergenceFree("evidence-fencing", into: &table) { try await self.kimiEvidenceFencing() }
        await expectDivergenceFree("backpressure", into: &table) { try await self.kimiBackpressure() }
        await expectDivergenceFree("secret-bearing-payloads", into: &table) {
            try await self.kimiSecretBearingPayloads()
        }
    }

    private func kimiFixture() async throws -> KimiTestFixture {
        try await KimiTestFixture.make(options: .init()) { _ in .accepted }
    }

    private func kimiQuestion() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(kimiForm(id: 30))
        let waiting = try await waitKimi(fixture) { $0.state == .waiting && $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        guard question.kind == .question else { throw Divergence.expected("not a question") }
        guard try await fixture.concrete.answerQuestion(
            question.request, context: question.context, answers: ["choice": ["blue"]]
        ) == .acknowledged else { throw Divergence.expected("answer not acknowledged") }
        // One-shot: a second answer for the same reference must fail.
        guard (try? await fixture.concrete.answerQuestion(
            question.request, context: question.context, answers: ["choice": ["blue"]]
        )) == nil else { throw Divergence.expected("duplicate answer accepted") }
        fixture.transport.push(kimiChunk("probe-output"))
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        let settled = try await waitKimi(fixture) { $0.state == .unverified }
        guard settled.parentOutcome == .unverified, !settled.ready, !settled.settlementKnown else {
            throw Divergence.expected("settlement drifted")
        }
    }

    private func kimiApproval() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(kimiPermission(id: 41))
        let waiting = try await waitKimi(fixture) { $0.state == .waiting && $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        guard question.kind == .approval else { throw Divergence.expected("not an approval") }
        guard try await fixture.concrete.answerPermission(
            question.request, context: question.context, decision: .allowOnce
        ) == .acknowledged else { throw Divergence.expected("answer not acknowledged") }
        let answerWrite = try #require(try fixture.transport.lastWrite {
            if case .response(.integer(41), _) = $0 { return true }
            return false
        })
        // Redelivery replays the remembered answer byte-for-byte.
        fixture.transport.push(kimiPermission(id: 41))
        _ = try await waitKimi(fixture) { _ in
            ((try? fixture.transport.writes().filter { $0 == answerWrite }.count) ?? 0) >= 2
        }
        guard (try? await fixture.concrete.answerPermission(
            question.request, context: question.context, decision: .allowOnce
        )) == nil else { throw Divergence.expected("duplicate answer accepted") }
        fixture.transport.push(.response(promptID, result: .object(["stopReason": .string("end_turn")])))
        _ = try await waitKimi(fixture) { $0.state == .unverified }
    }

    private func kimiContinuation() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "First turn"))
        let firstPromptID = try #require(fixture.transport.promptRequestIDs.last)
        fixture.transport.push(kimiChunk("first-output"))
        fixture.transport.push(.response(firstPromptID, result: .object(
            ["stopReason": .string("end_turn")])))
        _ = try await waitKimi(fixture) { $0.state == .unverified }
        // After the main-turn end, a new authorized submission is a new turn
        // on the same session.
        guard try await fixture.concrete.submit(
            KimiACPPromptContent(text: "Continuation")
        ) == .acknowledged else { throw Divergence.expected("continuation refused") }
        let after = try await waitKimi(fixture) { $0.state == .submitted }
        guard after.nativeSession?.rawValue == "kimi_fixture_new",
              fixture.transport.promptRequestIDs.count == 2 else {
            throw Divergence.expected("continuation left the exact session")
        }
    }

    private func kimiCancellation() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        _ = try await fixture.concrete.cancel()
        guard await fixture.concrete.snapshot().state == .cancelRequested else {
            throw Divergence.expected("cancellation not requested")
        }
        // Queued input is never auto-resent while the turn is in flight.
        do {
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Queued"))
            throw Divergence.expected("queued input sent while cancellation pending")
        } catch is KimiACPWireError {}
        fixture.transport.push(.response(promptID, result: .object(
            ["stopReason": .string("cancelled")])))
        let confirmed = try await waitKimi(fixture) { $0.state == .cancelled }
        guard confirmed.parentOutcome == .cancelled, !confirmed.ready else {
            throw Divergence.expected("cancellation confirmation drifted")
        }
    }

    private func kimiMalformedDuplicateStale() async throws {
        // Malformed: the shared ACP-strict framer fences ingress.
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        guard (try? framer.receive(Data("garbage-not-json\n".utf8)) { _ in }) == nil,
              framer.isClosed else { throw Divergence.expected("malformed frame not fenced") }
        // Duplicate: an answered request redelivered replays byte-for-byte.
        do {
            let fixture = try await kimiFixture()
            defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
            try await fixture.session.start()
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
            let promptID = try #require(fixture.transport.promptRequestIDs.last)
            fixture.transport.push(kimiPermission(id: 41))
            let waiting = try await waitKimi(fixture) { $0.state == .waiting && $0.questions.count == 1 }
            let question = try #require(waiting.questions.first)
            _ = try await fixture.concrete.answerPermission(
                question.request, context: question.context, decision: .allowOnce
            )
            let answerWrite = try #require(try fixture.transport.lastWrite {
                if case .response(.integer(41), _) = $0 { return true }
                return false
            })
            fixture.transport.push(kimiPermission(id: 41))
            _ = try await waitKimi(fixture) { _ in
                ((try? fixture.transport.writes().filter { $0 == answerWrite }.count) ?? 0) >= 2
            }
            fixture.transport.push(.response(promptID, result: .object(
                ["stopReason": .string("end_turn")])))
            _ = try await waitKimi(fixture) { $0.state == .unverified }
        }
        // Stale: a request with no active prompt is rejected, not answered.
        do {
            let fixture = try await kimiFixture()
            defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
            try await fixture.session.start()
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
            let promptID = try #require(fixture.transport.promptRequestIDs.last)
            fixture.transport.push(.response(promptID, result: .object(
                ["stopReason": .string("end_turn")])))
            _ = try await waitKimi(fixture) { $0.state == .unverified }
            fixture.transport.push(kimiPermission(id: 42))
            guard try await waitKimiRejection(fixture, wireID: 42) else {
                throw Divergence.expected("stale request not rejected")
            }
            // Foreign reverse-RPC: fs is not owned by Pine.
            fixture.transport.push(.request(.integer(43), method: "fs/read_text_file",
                                            params: .object([
                "sessionId": .string("kimi_fixture_new"), "path": .string("/probe/file.txt")
            ])))
            guard try await waitKimiRejection(fixture, wireID: 43) else {
                throw Divergence.expected("foreign reverse-RPC not rejected")
            }
            guard await fixture.concrete.snapshot().state == .unverified else {
                throw Divergence.expected("stale traffic changed state")
            }
        }
    }

    private func kimiLossFencesUnknown() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        _ = try await waitKimi(fixture) { $0.state == .submitted || $0.state == .working }
        fixture.transport.close()
        let lost = try await waitKimi(fixture) { $0.state == .unknown || $0.state == .stopped }
        guard lost.state == .unknown, !lost.ready else {
            throw Divergence.expected("channel loss did not fence unknown")
        }
        // No clean re-open on a lost channel.
        do {
            _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Again"))
            throw Divergence.expected("submit accepted on a lost channel")
        } catch is AdapterSessionError {
            // Refused as expected on a lost channel.
        } catch is KimiACPWireError {
            // Refused as expected on a lost channel.
        } catch {
            throw Divergence.expected("unexpected error type on lost channel")
        }
    }

    private func kimiRelaunch() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        let writes = try fixture.transport.writes()
        // A fresh attempt bootstrap is initialize + session/new only: no
        // load, resume, or fork crosses the wire automatically.
        guard writes.count == 2,
              writes.allSatisfy({
                  switch $0 {
                  case .request(_, "initialize", _), .request(_, "session/new", _): true
                  default: false
                  }
              }) else {
            throw Divergence.expected("relaunch sent resume/load/fork")
        }
        guard await fixture.concrete.snapshot().state == .idle else {
            throw Divergence.expected("relaunch did not start idle")
        }
    }

    private func kimiEvidenceFencing() async throws {
        // Connection-local: foreign connection IDs never create state.
        var connection = KimiACPConnection()
        try connection.initialize { _ in }
        _ = try connection.receive(
            .response(.integer(0), result: .object(["protocolVersion": .number("1")])),
            connection: connection.identity, write: { _ in }
        )
        guard try connection.receive(
            .request(.integer(50), method: "session/request_permission",
                     params: .object(["sessionId": .string("kimi_fixture_new")])),
            connection: UUID(), write: { _ in }
        ) == .ignoredForeignConnection else {
            throw Divergence.expected("foreign connection traffic accepted")
        }
        // Session-local: payloads never surface through shared reflection.
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        let marker = "PROBE_EVIDENCE_MARKER-\(UUID().uuidString)"
        fixture.transport.push(kimiChunk(marker))
        fixture.transport.push(.response(promptID, result: .object(
            ["stopReason": .string("end_turn")])))
        _ = try await waitKimi(fixture) { $0.state == .unverified }
        let snapshot = await fixture.concrete.snapshot()
        let reflection = String(reflecting: fixture.concrete)
            + String(reflecting: snapshot)
            + snapshot.questions.map { String(reflecting: $0) }.joined()
        guard !reflection.contains(marker) else {
            throw Divergence.expected("payload leaked into reflection")
        }
    }

    private func kimiBackpressure() async throws {
        // Connection-local: bounded server-request table fails closed.
        var connection = KimiACPConnection()
        try connection.initialize { _ in }
        _ = try connection.receive(
            .response(.integer(0), result: .object(["protocolVersion": .number("1")])),
            connection: connection.identity, write: { _ in }
        )
        for index in 0..<KimiACPConnection.maximumServerRequests {
            _ = try connection.receive(
                .request(.integer(Int64(1000 + index)), method: "session/request_permission",
                         params: .object(["sessionId": .string("kimi_fixture_new"),
                                          "toolCallId": .string("probe-\(index)")])),
                connection: connection.identity, write: { _ in }
            )
        }
        do {
            _ = try connection.receive(
                .request(.integer(1000 + Int64(KimiACPConnection.maximumServerRequests)),
                         method: "session/request_permission",
                         params: .object(["sessionId": .string("kimi_fixture_new"),
                                          "toolCallId": .string("probe-overflow")])),
                connection: connection.identity, write: { _ in }
            )
            throw Divergence.expected("server-request bound not enforced")
        } catch KimiACPWireError.capacity {}
        guard connection.phase == .closed else {
            throw Divergence.expected("capacity fence did not close the connection")
        }
    }

    private func kimiSecretBearingPayloads() async throws {
        let fixture = try await kimiFixture()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        try await fixture.session.start()
        _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Probe instruction"))
        let promptID = try #require(fixture.transport.promptRequestIDs.last)
        let marker = "PROBE_SECRET_MARKER-\(UUID().uuidString)"
        fixture.transport.push(.request(.integer(45), method: "session/request_permission",
                                        params: .object([
            "sessionId": .string("kimi_fixture_new"),
            "toolCall": .object([
                "toolCallId": .string("tool_probe_s"), "title": .string("Probe secret"),
                "kind": .string("other"),
                "rawInput": .object(["token": .string(marker)])
            ]),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                         "kind": .string("reject_once")])
            ])
        ])))
        let waiting = try await waitKimi(fixture) { $0.state == .waiting }
        let reflection = String(reflecting: fixture.concrete)
            + String(reflecting: waiting)
            + waiting.questions.map { String(reflecting: $0) }.joined()
        guard !reflection.contains(marker), !reflection.contains("tool_probe_s") else {
            throw Divergence.expected("secret-bearing payload surfaced in shared state")
        }
        fixture.transport.push(.response(promptID, result: .object(
            ["stopReason": .string("end_turn")])))
        _ = try await waitKimi(fixture) { $0.state == .unknown || $0.state == .unverified }
    }

    private func waitKimi(_ fixture: KimiTestFixture,
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

    private func waitKimiRejection(_ fixture: KimiTestFixture, wireID: Int64) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let rejected = try? fixture.transport.lastWrite(matching: { message in
                if case .failure(let id, let code) = message {
                    return id == .integer(wireID) && code == -32601
                }
                return false
            })
            if rejected != nil { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - Frame builders (probe-local; the merged suites keep their own)

    private func opencodeForm(toolCallID: String = "question-tool") -> AgentEventJSON {
        var fields: [String: AgentEventJSON] = [
            "mode": .string("form"), "sessionId": .string("ses_fixture"),
            "message": .string("Probe color?"),
            "requestedSchema": .object([
                "type": .string("object"), "required": .array([.string("color")]),
                "properties": .object(["color": .object([
                    "type": .string("string"), "oneOf": .array([
                        .object(["const": .string("blue"), "title": .string("Blue")]),
                        .object(["const": .string("amber"), "title": .string("Amber")])
                    ])
                ])])
            ])
        ]
        if toolCallID != "none" { fields["toolCallId"] = .string(toolCallID) }
        return .object(fields)
    }

    private func opencodePermission() -> AgentEventJSON {
        .object([
            "sessionId": .string("ses_fixture"),
            "toolCall": .object([
                "toolCallId": .string("write-1"), "title": .string("Write probe.txt"),
                "kind": .string("edit")
            ]),
            "options": .array([
                .object(["optionId": .string("once"), "kind": .string("allow_once")]),
                .object(["optionId": .string("always"), "kind": .string("allow_always")]),
                .object(["optionId": .string("reject"), "kind": .string("reject_once")])
            ])
        ])
    }

    private func opencodeChunk(_ text: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string("ses_fixture"), "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])
            ])
        ]))
    }

    private func opencodeEndTurn() -> CodexAppServerMessage {
        .response(.integer(2), result: .object(["stopReason": .string("end_turn")]))
    }

    private func opencodeToolCompletion(_ id: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string("ses_fixture"), "update": .object([
                "sessionUpdate": .string("tool_call_update"), "toolCallId": .string(id),
                "status": .string("completed")
            ])
        ]))
    }

    private func kimiForm(id: Int64) -> CodexAppServerMessage {
        .request(.integer(id), method: "elicitation/create", params: .object([
            "sessionId": .string("kimi_fixture_new"), "mode": .string("form"),
            "message": .string("Probe question"),
            "requestedSchema": .object([
                "type": .string("object"), "required": .array([.string("choice")]),
                "properties": .object(["choice": .object([
                    "type": .string("string"), "oneOf": .array([
                        .object(["const": .string("blue"), "title": .string("Blue")]),
                        .object(["const": .string("amber"), "title": .string("Amber")])
                    ])
                ])])
            ])
        ]))
    }

    private func kimiPermission(id: Int64) -> CodexAppServerMessage {
        .request(.integer(id), method: "session/request_permission", params: .object([
            "sessionId": .string("kimi_fixture_new"),
            "toolCall": .object([
                "toolCallId": .string("tool_fixture_p"), "title": .string("Probe write"),
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

    private func kimiChunk(_ text: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string("kimi_fixture_new"), "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])
            ])
        ]))
    }
}
