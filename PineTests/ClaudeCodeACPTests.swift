import Foundation
import Observation
import Synchronization
import Testing
@testable import Pine

@Suite("ClaudeCode pinned ACP first loop")
struct ClaudeCodeACPTests {
    @Test func unicodeRPCQuestionsAreDistinctAndResponsesRetainExactIDs() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Ask twice"), beforeDispatch: {})
        let identifiers = ["Café", "Cafe\u{301}"]
        for identifier in identifiers {
            fixture.transport.push(.request(.string(identifier), method: "elicitation/create",
                                            params: form(toolCallID: nil)))
        }
        fixture.transport.push(chunk("Both requests processed"))
        let waiting = try await wait(fixture.concrete) { $0.result == "Both requests processed" }
        #expect(waiting.questions.count == 2)
        #expect(Set(waiting.questions.map(\.id)).count == 2)
        for question in waiting.questions {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["blue"]]
            ), beforeDispatch: {})
        }
        let responseIDs = try fixture.transport.writes().compactMap { message -> Data? in
            guard case .response(.string(let identifier), _) = message else { return nil }
            return Data(identifier.utf8)
        }
        #expect(responseIDs.count == 2)
        #expect(Set(responseIDs) == Set(identifiers.map { Data($0.utf8) }))
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    /// #1765: the session setup `configOptions` observation fills the
    /// read-only discovery report. The fixture factory supplies the
    /// launch-boundary input, so the report attributes the resolved
    /// executable, the pinned version, and the confirmed effective values
    /// from the observed `currentValue`s.
    @Test func sessionSetupConfigOptionsFillTheDiscoveryReport() async throws {
        let fixture = try await fixture(sessionNewResult: .object([
            "sessionId": .string("ses_fixture"),
            "configOptions": .array([
                .object([
                    "id": .string("model"), "name": .string("Model"),
                    "category": .string("model"), "type": .string("select"),
                    "currentValue": .string("default"),
                    "options": .array([
                        .object(["value": .string("default"), "name": .string("Default")])
                    ]),
                ]),
                .object([
                    "id": .string("effort"), "name": .string("Effort"),
                    "category": .string("thought_level"), "type": .string("select"),
                    "currentValue": .string("default"),
                    "options": .array([
                        .object(["value": .string("default"), "name": .string("Default")])
                    ]),
                ]),
                .object([
                    "id": .string("mode"), "name": .string("Mode"),
                    "category": .string("mode"), "type": .string("select"),
                    "currentValue": .string("auto"),
                    "options": .array([
                        .object(["value": .string("auto"), "name": .string("Auto")])
                    ]),
                ]),
            ]),
        ]))
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let report = await fixture.concrete.discoveryReport
        #expect(report != nil)
        #expect(report?.sessionStart == .started)
        #expect(report?.executableIdentity == .resolved(
            URL(fileURLWithPath: "/opt/homebrew/bin/claude-agent-acp", isDirectory: false)))
        #expect(report?.executableVersion == .supported(
            try DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion)))
        #expect(report?.effectiveModel == .confirmed("default"))
        #expect(report?.effectivePermissions == .confirmed("auto"))
        #expect(report?.configurationCapabilities.model.state == .probed)
        #expect(report?.configurationCapabilities.reasoningEffort.state == .probed)
        #expect(report?.configurationCapabilities.permissions.state == .probed)
        // The report belongs to the live session: stopping clears it so a
        // future view wiring cannot render a stale observation.
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        #expect(await fixture.concrete.discoveryReport == nil)
    }

    /// #1765 review: a shape-malformed `configOptions` payload (not an array)
    /// is a throwing observation — the session stays healthy but produces no
    /// report at all, never a floor report from a half-observed peer.
    @Test func malformedConfigOptionsKeepTheSessionButDropTheReport() async throws {
        let fixture = try await fixture(sessionNewResult: .object([
            "sessionId": .string("ses_fixture"),
            "configOptions": .object(["id": .string("model")]),
        ]))
        defer { fixture.transport.close() }
        try await fixture.session.start()
        // The session itself is healthy and bound despite the malformed
        // observation: only the report is dropped.
        #expect(await fixture.concrete.snapshot().nativeSession != nil)
        #expect(await fixture.concrete.discoveryReport == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test(arguments: [false, true])
    func owningToolCompletionRequiresExactBytesForPendingAndSubmittedAsks(submitted: Bool) async throws {
        let events = Mutex<[ValidatedAgentEvent]>([])
        let fixture = try await fixture(ingest: { event in
            events.withLock { $0.append(event) }
            return .accepted
        })
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Write"), beforeDispatch: {})
        fixture.transport.push(.request(.integer(92), method: "session/request_permission",
                                        params: permission(toolCallID: "Café")))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        if submitted {
            _ = try await controls.dispatch(.answerPermission(
                request: question.request, context: question.context, decision: .deny
            ), beforeDispatch: {})
        }
        fixture.transport.push(toolCompletion("Cafe\u{301}"))
        fixture.transport.push(chunk("Different completion processed"))
        let different = try await wait(fixture.concrete) { $0.result == "Different completion processed" }
        #expect((submitted ? different.submittedQuestions : different.questions).contains { $0.id == question.id })
        #expect(!events.withLock { $0 }.contains {
            if case .requestResolved(let resolution) = $0.candidate.event {
                return resolution.request == question.request
            }
            return false
        })
        fixture.transport.push(toolCompletion("Café"))
        fixture.transport.push(chunk("Exact completion processed"))
        let exact = try await wait(fixture.concrete) { $0.result.hasSuffix("Exact completion processed") }
        #expect(exact.questions.isEmpty && exact.submittedQuestions.isEmpty)
        #expect(events.withLock { $0 }.filter {
            if case .requestResolved(let resolution) = $0.candidate.event {
                return resolution.request == question.request
            }
            return false
        }.count == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func launchIsDeferredAndIngressUsesRealConversationWithoutProviderTurnID() async throws {
        let events = Mutex<[ValidatedAgentEvent]>([])
        let fixture = try await fixture(ingest: { event in
            events.withLock { $0.append(event) }
            return .accepted
        })
        defer { fixture.transport.close() }
        #expect(fixture.transport.launchCount == 0)
        _ = try fixture.registry.sourceIdentity(for: fixture.session)
        try await fixture.session.start()
        #expect(fixture.transport.launchCount == 1)
        let bootstrap = try fixture.transport.writes()
        guard bootstrap.count == 2,
              case .request(_, "initialize", let initializeParams) = bootstrap[0] else {
            Issue.record("Expected the pinned ACP initialize request")
            return
        }
        let initializeFields = try ClaudeCodeACPWire.object(initializeParams)
        #expect(initializeFields["protocolVersion"] == .number("1"))
        let clientCapabilities = try ClaudeCodeACPWire.object(initializeFields["clientCapabilities"] ?? .null)
        #expect(Set(clientCapabilities.keys) == ["elicitation"])
        #expect(clientCapabilities["_meta"] == nil)
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
        #expect(await fixture.concrete.snapshot().context?.role == .request)
        fixture.transport.push(chunk("Observed output"))
        fixture.transport.push(endTurn())
        _ = try await wait(fixture.concrete) { $0.parentOutcome == .unverified }
        let observed = events.withLock { $0 }
        #expect(!observed.isEmpty)
        for event in observed {
            if case .lifecycle(let lifecycle) = event.candidate.event {
                #expect(lifecycle.scope == .session)
                #expect(lifecycle.reference?.role == .conversation)
                #expect(lifecycle.reference?.rawValue == "ses_fixture")
            }
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func authStatusNotificationsBetweenInitializeAndSessionNewAreIgnored() async throws {
        let fixture = try await fixture(authNotificationsBetweenBootstrap: true)
        defer { fixture.transport.close() }
        try await fixture.session.start()
        #expect(await fixture.concrete.snapshot().state == .idle)
        #expect(fixture.transport.launchCount == 1)
        let methods = try fixture.transport.writes().compactMap { message -> String? in
            guard case .request(_, let method, _) = message else { return nil }
            return method
        }
        #expect(methods == ["initialize", "session/new"])
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func initializeRejectsProtocolTwoWrongAgentNameAndWrongVersionBeforeSessionNew() async throws {
        func response(_ protocolVersion: String, _ name: String, _ version: String) -> AgentEventJSON {
            .object([
                "protocolVersion": .number(protocolVersion),
                "agentInfo": .object(["name": .string(name), "version": .string(version)]),
                "agentCapabilities": .object(["loadSession": .bool(true)])
            ])
        }
        let cases: [(AgentEventJSON, ClaudeCodeACPError)] = [
            (response("2", ClaudeCodeACPSession.pinnedAgentName, ClaudeCodeACPSession.pinnedVersion), .invalidProtocol),
            (response("1", "wrong-agent", ClaudeCodeACPSession.pinnedVersion), .unavailable),
            (response("1", ClaudeCodeACPSession.pinnedAgentName, "0.109.2"), .unavailable)
        ]
        for (initialization, expected) in cases {
            let fixture = try await fixture(initializeResult: initialization)
            defer { fixture.transport.close() }
            await #expect(throws: expected) { try await fixture.session.start() }
            #expect(fixture.transport.launchCount == 1)
            #expect(try fixture.transport.writes().count == 1)
            #expect(try !fixture.transport.writes().contains {
                if case .request(_, "session/new", _) = $0 { true } else { false }
            })
        }
    }

    @Test func fencedLateResponseCannotEnableFeedbackOrKillOwnedChildQuestions() async throws {
        let fixture = try await fixture(fenceResponse: true)
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
        fixture.transport.push(endTurn())
        let result = try await wait(fixture.concrete) { $0.inputFenced }
        #expect(result.parentOutcome == .unverified && !result.ready)
        await #expect(throws: ClaudeCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Do not reopen"), beforeDispatch: {})
        }
        fixture.transport.push(.request(.string("late-owned-question"), method: "elicitation/create",
                                        params: form(toolCallID: nil)))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        #expect(try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {}) == .acknowledged)
        #expect(throws: Never.self) { try fixture.transport.validate() }
        #expect(try fixture.transport.writes().filter {
            if case .request(_, "session/prompt", _) = $0 { true } else { false }
        }.count == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @MainActor
    @Test func observableTaskRuntimeConnectsControlsQuestionsFeedbackAndCancellation() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let gateWasOnMain = Mutex(false)
        let runtime = try ClaudeCodeACPTaskRuntime(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            registry: fixture.registry, owner: fixture.session, provider: fixture.concrete,
            taskIsCurrent: { true }, prepareControl: { _ in }, beforeDispatch: { _ in
                if Thread.isMainThread { gateWasOnMain.withLock { $0 = true } }
            }
        )
        #expect(runtime.snapshot == nil)
        try await runtime.start()
        #expect(runtime.isActive)
        _ = try await runtime.submit("First request")
        let changed = Mutex(false)
        withObservationTracking {
            _ = runtime.snapshot
        } onChange: { changed.withLock { $0 = true } }
        fixture.transport.push(.request(.string("runtime-ask"), method: "elicitation/create", params: form()))
        try #require(await waitUntilMainActor { runtime.snapshot?.questions.count == 1 })
        #expect(changed.withLock { $0 })
        let question = try #require(runtime.snapshot?.questions.first)
        _ = try await runtime.answerQuestion(question, answers: ["color": ["blue"]])
        fixture.transport.push(toolCompletion("question-tool"))
        fixture.transport.push(chunk("Unverified result"))
        fixture.transport.push(endTurn())
        try #require(await waitUntilMainActor { runtime.snapshot?.state == .unverified })
        #expect(runtime.snapshot?.result == "Unverified result")
        #expect(runtime.snapshot?.ready == false)
        _ = try await runtime.submit("Explicit same-session feedback")
        _ = try await runtime.cancel()
        #expect(runtime.snapshot?.state == .cancelRequested)
        fixture.transport.push(.response(.integer(3), result: .object(["stopReason": .string("cancelled")])))
        try #require(await waitUntilMainActor { runtime.snapshot?.state == .cancelled })
        #expect(!gateWasOnMain.withLock { $0 })
        #expect(!String(reflecting: runtime).contains("Unverified result"))
        #expect(!String(reflecting: fixture.concrete).contains("Unverified result"))
        await runtime.stop(deadline: .now.advanced(by: .seconds(1)))
        #expect(runtime.snapshot == nil && !runtime.isActive)
    }

    @MainActor
    @Test func observableRuntimeFencesPermissionOptionsAndRetiredDurableAttempt() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let current = Mutex(true)
        let runtime = try ClaudeCodeACPTaskRuntime(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            registry: fixture.registry, owner: fixture.session, provider: fixture.concrete,
            taskIsCurrent: { current.withLock { $0 } }, prepareControl: { _ in }, beforeDispatch: { _ in
                try current.withLock { if !$0 { throw ClaudeCodeACPError.unavailable } }
            }
        )
        try await runtime.start()
        _ = try await runtime.submit("Ask")
        fixture.transport.push(.request(.integer(55), method: "session/request_permission", params: permission()))
        try #require(await waitUntilMainActor { runtime.snapshot?.questions.count == 1 })
        let approval = try #require(runtime.snapshot?.questions.first)
        #expect(approval.allowOnceOptionID == "once" && approval.denyOptionID == "reject")
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await runtime.answerPermission(approval, optionID: "always", decision: .allowOnce)
        }
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await runtime.answerPermission(approval, optionID: "reject", decision: .allowOnce)
        }
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await runtime.answerQuestion(approval, answers: ["text": ["yes"]])
        }
        _ = try await runtime.answerPermission(approval, optionID: "reject", decision: .deny)
        let count = try fixture.transport.writes().count
        current.withLock { $0 = false }
        await #expect(throws: ClaudeCodeACPError.unavailable) { _ = try await runtime.submit("Do not send") }
        #expect(try fixture.transport.writes().count == count)
        fixture.transport.push(chunk("Late output from retired source"))
        try #require(await waitUntilMainActor { runtime.snapshot == nil })
        await runtime.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @MainActor
    @Test func unsupportedQuestionRetainsExplicitCleanupWithoutClaimingConfirmedCancellation() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let runtime = try ClaudeCodeACPTaskRuntime(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            registry: fixture.registry, owner: fixture.session, provider: fixture.concrete,
            taskIsCurrent: { true }, prepareControl: { _ in }, beforeDispatch: { _ in }
        )
        try await runtime.start()
        _ = try await runtime.submit("Ask")
        var fields = try ClaudeCodeACPWire.object(form())
        fields["mode"] = .string("url")
        fixture.transport.push(.request(.integer(70), method: "elicitation/create", params: .object(fields)))
        try #require(await waitUntilMainActor { runtime.snapshot?.state == .blocked })
        #expect(!runtime.isActive)
        #expect(try await runtime.cancel() == .acknowledged)
        #expect(runtime.snapshot?.state == .stopped)
        #expect(runtime.snapshot?.state != .cancelled)
        #expect(try fixture.transport.writes().count == 3)
        await runtime.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func requestQuestionResultAndExplicitFeedbackKeepExactSession() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        #expect(try await controls.dispatch(.submitInstruction("First request"), beforeDispatch: {}) == .acknowledged)
        let initial = await fixture.concrete.snapshot()
        #expect(initial.state == .submitted)
        #expect(!initial.ready)
        await #expect(throws: ClaudeCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Not feedback before a response"), beforeDispatch: {})
        }
        fixture.transport.push(.request(.string("ask-1"), method: "elicitation/create", params: form()))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        #expect(question.form?.fields["color"]?.choices == ["blue", "amber"])
        #expect(try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {}) == .acknowledged)
        #expect(await fixture.concrete.snapshot().answersAwaitingEvidence == 1)
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["blue"]]
            ), beforeDispatch: {})
        }
        fixture.transport.push(.notification(method: "session/update", params: .object([
            "sessionId": .string("ses_fixture"), "update": .object([
                "sessionUpdate": .string("tool_call_update"), "toolCallId": .string("question-tool"),
                "status": .string("completed")
            ])
        ])))
        _ = try await wait(fixture.concrete) { $0.answersAwaitingEvidence == 0 }
        fixture.transport.push(chunk("First result"))
        fixture.transport.push(.response(.integer(2), result: .object(["stopReason": .string("end_turn")])))
        let result = try await wait(fixture.concrete) { $0.state == .unverified }
        #expect(result.result == "First result")
        #expect(!result.ready && !result.settlementKnown)
        #expect(try await controls.dispatch(.submitInstruction("Explicit feedback"), beforeDispatch: {}) == .acknowledged)
        let prompts = try fixture.transport.writes().compactMap { message -> AgentEventJSON? in
            guard case .request(_, "session/prompt", let params) = message else { return nil }
            return params
        }
        #expect(prompts.count == 2)
        for prompt in prompts {
            #expect(try ClaudeCodeACPWire.object(prompt)["sessionId"] == .string("ses_fixture"))
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func cancellationRequiresProviderEvidenceAndLateCompletionIsUnknown() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Wait"), beforeDispatch: {})
        let started = await fixture.concrete.snapshot()
        let context = try #require(started.context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        #expect(await fixture.concrete.snapshot().state == .cancelRequested)
        fixture.transport.push(endTurn())
        let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
        #expect(!unknown.ready)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func permissionAnswerIsOneShotAndIdenticalRedeliveryReplaysOnlyRememberedAllow() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Write"), beforeDispatch: {})
        let request = CodexAppServerMessage.request(
            .integer(20), method: "session/request_permission", params: permission()
        )
        fixture.transport.push(request)
        let waiting = try await wait(fixture.concrete) { !$0.questions.isEmpty }
        let question = try #require(waiting.questions.first)
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .allowOnce
        ), beforeDispatch: {})
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerPermission(
                request: question.request, context: question.context, decision: .allowOnce
            ), beforeDispatch: {})
        }
        fixture.transport.push(request)
        fixture.transport.push(chunk("permission-replay-complete"))
        _ = try await wait(fixture.concrete) { $0.result == "permission-replay-complete" }
        let expected = CodexAppServerMessage.response(.integer(20), result: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("once")])
        ]))
        #expect(try fixture.transport.writes().filter { $0 == expected }.count == 2)
        fixture.transport.push(.response(.integer(2), result: .object(["stopReason": .string("cancelled")])))
        let cancelled = try await wait(fixture.concrete) { $0.state == .cancelled }
        #expect(!cancelled.ready)
        fixture.transport.push(request)
        fixture.transport.push(chunk("post-cancel-redelivery"))
        _ = try await wait(fixture.concrete) { $0.inputFenced }
        #expect(try fixture.transport.writes().filter { $0 == expected }.count == 2)
        #expect(try fixture.transport.writes().contains(.response(.integer(20), result: .object([
            "outcome": .object(["outcome": .string("cancelled")])
        ]))))
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func uncertainWriteNeverReplaysAndRevokedGateCannotWrite() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        fixture.transport.failNextWrite()
        #expect(try await controls.dispatch(.submitInstruction("Only once"), beforeDispatch: {}) == .uncertain)
        #expect(await fixture.concrete.snapshot().state == .unknown)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("Only once"), beforeDispatch: {})
        }
        #expect(try fixture.transport.writes().count == 3)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func transportLossDoesNotRelaunchOrResendPrompt() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Only once"), beforeDispatch: {})
        fixture.transport.close()
        _ = try await wait(fixture.concrete) { $0.state == .unknown }
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("Never resent"), beforeDispatch: {})
        }
        #expect(fixture.transport.launchCount == 1)
        #expect(try fixture.transport.writes().filter {
            if case .request(_, "session/prompt", _) = $0 { true } else { false }
        }.count == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func unsupportedQuestionBlocksInsteadOfReturningFallbackError() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Question"), beforeDispatch: {})
        var fields = try ClaudeCodeACPWire.object(form())
        fields["mode"] = .string("url")
        fixture.transport.push(.request(.string("unsupported"), method: "elicitation/create", params: .object(fields)))
        let blocked = try await wait(fixture.concrete) { $0.state == .blocked }
        #expect(!blocked.ready)
        #expect(try fixture.transport.writes().count == 3)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func foreignSessionAndDuplicateParentResponseFenceOwner() async throws {
        for negative in 0..<2 {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
            if negative == 0 {
                fixture.transport.push(.notification(method: "session/update", params: .object([
                    "sessionId": .string("ses_foreign"), "update": .object(["sessionUpdate": .string("tool_call")])
                ])))
            } else {
                fixture.transport.push(endTurn())
                fixture.transport.push(endTurn())
            }
            let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
            #expect(!unknown.ready && unknown.questions.isEmpty)
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
    }

    @Test func redeliveredAnsweredRequestReplaysExactResponseWithoutAnotherDecision() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
        let questionMessage = CodexAppServerMessage.request(
            .integer(22), method: "elicitation/create", params: form()
        )
        fixture.transport.push(questionMessage)
        let waiting = try await wait(fixture.concrete) { !$0.questions.isEmpty }
        let question = try #require(waiting.questions.first)
        _ = try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        fixture.transport.push(questionMessage)
        fixture.transport.push(chunk("replay-complete"))
        let alive = try await wait(fixture.concrete) { $0.result == "replay-complete" }
        let expected = CodexAppServerMessage.response(.integer(22), result: .object([
            "action": .string("accept"), "content": .object(["color": .string("blue")])
        ]))
        #expect(try fixture.transport.writes().filter { $0 == expected }.count == 2)
        #expect(alive.questions.isEmpty && alive.submittedQuestions.count == 1 && !alive.ready)
        #expect(throws: Never.self) { try fixture.transport.validate() }
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["amber"]]
            ), beforeDispatch: {})
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func withdrawnPermissionResolvesOnceRejectsStaleAnswerAndUnblocksLaterPrompt() async throws {
        let events = Mutex<[ValidatedAgentEvent]>([])
        let fixture = try await fixture(ingest: { event in
            events.withLock { $0.append(event) }
            return .accepted
        })
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
        fixture.transport.push(.request(.integer(90), method: "session/request_permission", params: permission()))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        fixture.transport.push(.notification(method: "$/cancel_request", params: .object([
            "requestId": .number("90")
        ])))
        let withdrawn = try await wait(fixture.concrete) { $0.questions.isEmpty && $0.state == .submitted }
        #expect(withdrawn.answersAwaitingEvidence == 0 && !withdrawn.ready)
        #expect(events.withLock { $0 }.filter {
            if case .requestResolved(let resolution) = $0.candidate.event {
                return resolution.request == question.request
            }
            return false
        }.count == 1)
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerPermission(
                request: question.request, context: question.context, decision: .allowOnce
            ), beforeDispatch: {})
        }
        fixture.transport.push(endTurn())
        _ = try await wait(fixture.concrete) { $0.parentOutcome == .unverified }
        _ = try await controls.dispatch(.submitInstruction("Later prompt"), beforeDispatch: {})
        #expect(try !fixture.transport.writes().contains {
            if case .response(.integer(90), _) = $0 { true } else { false }
        })
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func explicitLoadUsesExactIDAndCwdWithoutPromptOrAutomaticRestart() async throws {
        let reference = try VendorReference(role: .conversation, value: "ses_exact")
        let fixture = try await fixture(loadSession: reference)
        defer { fixture.transport.close() }
        #expect(try fixture.transport.writes().isEmpty)
        try await fixture.session.start()
        let messages = try fixture.transport.writes()
        #expect(messages.count == 2)
        guard case .request(_, "session/load", let params) = messages[1] else {
            Issue.record("Expected exact session/load")
            return
        }
        let fields = try ClaudeCodeACPWire.object(params)
        #expect(fields["sessionId"] == .string("ses_exact"))
        #expect(fields["cwd"] == .string("/fixture/task"))
        #expect(await fixture.concrete.snapshot().state == .idle)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func nonNilCheckpointIsRejectedWithoutLaunch() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let evidence = try await makeResumeCheckpointForClaudeTests()
        await #expect(throws: AdapterSessionError.checkpointNotSupported) {
            _ = try await fixture.registry.makeSession(
                contract: fixture.contract, resumeFrom: evidence.checkpoint
            ) { _ in .accepted }
        }
        #expect(fixture.transport.launchCount == 0)
        #expect(try fixture.transport.writes().isEmpty)
    }

    @Test func missingSessionOrWrongCwdLoadFailureDoesNotFallBackToNewSession() async throws {
        let reference = try VendorReference(role: .conversation, value: "ses_missing")
        let fixture = try await fixture(loadSession: reference, rejectLoad: true)
        defer { fixture.transport.close() }
        await #expect(throws: ClaudeCodeACPError.providerFailure(-32602)) {
            try await fixture.session.start()
        }
        let messages = try fixture.transport.writes()
        #expect(messages.count == 2)
        #expect(!messages.contains {
            if case .request(_, "session/new", _) = $0 { true } else { false }
        })
    }

    @Test func rejectedPhysicalGatePropagatesWithoutWritingOrRetry() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        await #expect(throws: ClaudeCodeACPError.unavailable) {
            _ = try await controls.dispatch(.submitInstruction("Do not send"), beforeDispatch: {
                throw ClaudeCodeACPError.unavailable
            })
        }
        #expect(try fixture.transport.writes().count == 2)
        #expect(await fixture.concrete.snapshot().state == .idle)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func lateQuestionAfterCancelledRootRemainsAnswerableInSessionContext() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate"), beforeDispatch: {})
        let context = try #require(await fixture.concrete.snapshot().context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        fixture.transport.push(.response(.integer(2), result: .object(["stopReason": .string("cancelled")])))
        _ = try await wait(fixture.concrete) { $0.state == .cancelled }
        fixture.transport.push(.request(.integer(40), method: "elicitation/create", params: form(toolCallID: nil)))
        let waiting = try await wait(fixture.concrete) { !$0.questions.isEmpty }
        let question = try #require(waiting.questions.first)
        #expect(question.context.role == .conversation)
        #expect(try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {}) == .acknowledged)
        #expect(!waiting.ready)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func answeredButUnresolvedRequestFencesContinuationAndRetainsResult() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("First"), beforeDispatch: {})
        fixture.transport.push(.request(.integer(94), method: "elicitation/create", params: form()))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        _ = try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        fixture.transport.push(chunk("retained result"))
        fixture.transport.push(endTurn())
        _ = try await wait(fixture.concrete) { $0.parentOutcome == .unverified }
        await #expect(throws: ClaudeCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Ambiguous continuation"), beforeDispatch: {})
        }
        #expect(await fixture.concrete.snapshot().result == "retained result")
        #expect(try fixture.transport.writes().filter {
            if case .request(_, "session/prompt", _) = $0 { true } else { false }
        }.count == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func sharedProviderContractOutcomesAreExplicit() {
        expectProviderContractOutcomes([
            "question": .pass,
            "approval": .pass,
            "continuation": .pass,
            "cancellation": .pass,
            "malformed-duplicate-stale": .pass,
            "reconnect": .unsupported("ACP transport loss has no ordered replay; exact explicit load never restores pending delivery"),
            "relaunch": .pass,
            "evidence-fencing": .pass,
            "backpressure": .pass,
            "secret-bearing-payloads": .pass
        ], provider: "Claude Code")
    }

    // MARK: - Pinned real-pipe codec + spawn coverage

    /// The version-pinned turn fixture replays through the REAL channel: a
    /// supervised `cat` child feeds the raw frames over real pipes through the
    /// JSONL framer with the ACP version requirement.
    @Test func pinnedTurnFixtureReplaysOverRealChannel() async throws {
        let lines = try Self.fixtureLines("acp-claude-v0.109.1-turn.jsonl")
        #expect(lines.count == 6)
        let work = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "turn.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: file.path, atomically: true, encoding: .utf8)
        let child = try await Self.spawnFixtureFile(at: file, workingDirectory: work)
        defer { _ = Task.detached { await child.stop(.now.advanced(by: .seconds(10))) } }
        let first = try await child.channel.readNext(deadline: .now.advanced(by: .seconds(10)))
        guard case .response(let id, let result) = first else {
            Issue.record("Expected pinned initialize response, got \(String(describing: first))")
            return
        }
        #expect(id == .integer(0))
        #expect(try ClaudeCodeACPWire.object(result)["agentInfo"] == .object([
            "name": .string(ClaudeCodeACPSession.pinnedAgentName), "version": .string(ClaudeCodeACPSession.pinnedVersion)
        ]))
        for _ in 1..<6 {
            _ = try await child.channel.readNext(deadline: .now.advanced(by: .seconds(10)))
        }
        #expect(try await child.channel.readNext(deadline: .now.advanced(by: .seconds(10))) == nil)
        await child.stop(.now.advanced(by: .seconds(10)))
    }

    /// Each sanitized fault frame through the real channel: codec-level
    /// fences (versionless frame, corrupt JSON) close the framer; valid frames
    /// parse and the secret-bearing payload never reaches diagnostics.
    @Test func faultFramesFenceThroughRealChannelCodec() async throws {
        let lines = try Self.fixtureLines("acp-claude-v0.109.1-faults.jsonl")
        #expect(lines.count == 8)
        for index in lines.indices {
            let work = try Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let file = work.appending(path: "line-\(index).jsonl")
            try (lines[index] + "\n").write(toFile: file.path, atomically: true, encoding: .utf8)
            let child = try await Self.spawnFixtureFile(at: file, workingDirectory: work)
            defer { _ = Task.detached { await child.stop(.now.advanced(by: .seconds(10))) } }
            let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10))
            switch index {
            case 0:
                await #expect(throws: CodexAppServerWireError.invalidEnvelope) {
                    _ = try await child.channel.readNext(deadline: deadline)
                }
            case 1:
                await #expect(throws: AgentEventJSON.Failure.invalidJSON) {
                    _ = try await child.channel.readNext(deadline: deadline)
                }
            default:
                guard let message = try await child.channel.readNext(deadline: deadline) else {
                    Issue.record("Expected a parsed frame at line \(index)")
                    return
                }
                if index == 7 {
                    #expect(!String(reflecting: message).contains("sk-fake-SECRET"))
                }
                #expect(try await child.channel.readNext(deadline: deadline) == nil)
            }
            await child.stop(.now.advanced(by: .seconds(10)))
        }
    }

    /// Session-level fence outcomes for the same fault frames, plus the
    /// secret redaction assertion on every reflected state.
    @Test func sanitizedFaultFramesFenceWithoutLeakingSecrets() async throws {
        let lines = try Self.fixtureLines("acp-claude-v0.109.1-faults.jsonl")
        #expect(lines.count == 8)
        do {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            fixture.transport.push(try CodexAppServerMessage(data: Data(lines[2].utf8), requireJSONRPCVersion: true))
            let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
            #expect(!unknown.ready)
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        do {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
            let questionFrame = lines[3]
            fixture.transport.push(try CodexAppServerMessage(data: Data(questionFrame.utf8), requireJSONRPCVersion: true))
            _ = try await wait(fixture.concrete) { $0.questions.count == 1 }
            // The identical duplicate is fenced silently while pending. The
            // marker proves the reader consumed it without erroring.
            fixture.transport.push(try CodexAppServerMessage(data: Data(questionFrame.utf8), requireJSONRPCVersion: true))
            fixture.transport.push(chunk("duplicate-fenced"))
            let alive = try await wait(fixture.concrete) { $0.result == "duplicate-fenced" }
            // The open question keeps the session .waiting; chunks do not force .working.
            #expect(alive.questions.count == 1 && alive.state == .waiting && !alive.ready)
            #expect(throws: Never.self) { try fixture.transport.validate() }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        do {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
            // Unknown notification method: ignored, connection stays alive.
            fixture.transport.push(try CodexAppServerMessage(data: Data(lines[4].utf8), requireJSONRPCVersion: true))
            fixture.transport.push(chunk("stale-fenced"))
            let alive = try await wait(fixture.concrete) { $0.result == "stale-fenced" }
            #expect(alive.state == .working && !alive.ready)
            #expect(throws: Never.self) { try fixture.transport.validate() }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        for lineIndex in [5, 6] {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
            fixture.transport.push(try CodexAppServerMessage(data: Data(lines[lineIndex].utf8), requireJSONRPCVersion: true))
            let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
            #expect(!unknown.ready)
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        do {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Ask"), beforeDispatch: {})
            fixture.transport.push(try CodexAppServerMessage(data: Data(lines[7].utf8), requireJSONRPCVersion: true))
            _ = try await wait(fixture.concrete) { $0.state == .working }
            #expect(!String(reflecting: fixture.concrete).contains("sk-fake-SECRET"))
            #expect(!String(reflecting: fixture.transport).contains("sk-fake-SECRET"))
            let snapshot = await fixture.concrete.snapshot()
            #expect(!String(reflecting: snapshot).contains("sk-fake-SECRET"))
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
    }

    /// Real-process evidence through the full stdio stack (spawn + transport
    /// + framer + close observer + child supervision): the pinned handshake
    /// completes and a fenced stop tears the child down. No model quota: every
    /// reply is canned by the fixture agent.
    @Test func ownedSpawnSpeaksPinnedACPHandshakeOverRealPipes() async throws {
        let script = Self.fakeAcPAgentURL()
        try #require(FileManager.default.isExecutableFile(atPath: script.path))
        for (scenario, expectedStop) in [("turn", "end_turn"), ("cancel", "cancelled")] {
            let work = try Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let child = try await ClaudeCodeACPLaunch.spawn(
                executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectory: work,
                deadline: .now.advanced(by: .seconds(30)), drainUntil: .now.advanced(by: .seconds(300)),
                arguments: [script.path, scenario]
            )
            let transport = try ClaudeCodeACPStdioTransport(channel: child.channel, child: child)
            defer { _ = Task.detached { await transport.stop(deadline: .now.advanced(by: .seconds(10))) } }
            let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10))
            try await transport.write(ClaudeCodeACPWire.encode(
                .request(.integer(0), method: "initialize", params: .object([
                    "protocolVersion": .number("1"),
                    "clientInfo": .object(["name": .string("pine"), "version": .string("3.0")]),
                    "clientCapabilities": .object([
                        "elicitation": .object(["form": .object([:])])
                    ])
                ]))), deadline: deadline, beforeWrite: {})
            let initialization = try await transport.read(deadline: deadline)
            guard case .response(let id, let result) = initialization else {
                Issue.record("Expected initialize response, got \(String(describing: initialization))")
                return
            }
            #expect(id == .integer(0))
            #expect(try ClaudeCodeACPWire.object(result)["agentInfo"] == .object([
                "name": .string(ClaudeCodeACPSession.pinnedAgentName), "version": .string(ClaudeCodeACPSession.pinnedVersion)
            ]))
            try await transport.write(ClaudeCodeACPWire.encode(.request(.integer(1), method: "session/new",
                                                                       params: .object([
                "cwd": .string(work.path), "mcpServers": .array([])
            ]))), deadline: deadline, beforeWrite: {})
            _ = try await transport.read(deadline: deadline)
            _ = try await transport.read(deadline: deadline)
            try await transport.write(ClaudeCodeACPWire.encode(.request(.integer(2), method: "session/prompt",
                                                                       params: .object([
                "sessionId": .string("ses_fake"),
                "prompt": .array([.object(["type": .string("text"), "text": .string("Fixture prompt")])])
            ]))), deadline: deadline, beforeWrite: {})
            if scenario == "cancel" {
                try await transport.write(ClaudeCodeACPWire.encode(.notification(method: "session/cancel",
                                                                               params: .object([
                    "sessionId": .string("ses_fake")
                ]))), deadline: deadline, beforeWrite: {})
            }
            var gotFinal = false
            for _ in 0..<2 {
                let message = try await transport.read(deadline: deadline)
                if case .response(_, let result) = message {
                    gotFinal = true
                    #expect(try ClaudeCodeACPWire.object(result)["stopReason"] == .string(expectedStop))
                }
            }
            #expect(gotFinal)
            #expect(throws: Never.self) { try transport.validate() }
            await transport.stop(deadline: .now.advanced(by: .seconds(10)))
            if let identity = child.processIdentity {
                // Identity-qualified: the observed incarnation is gone.
                let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
                #expect(remaining == nil || remaining != identity)
            }
        }
    }

    @Test func spawnedFakeRunsQuestionPermissionFeedbackAndCancellation() async throws {
        let work = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let child = try await ClaudeCodeACPLaunch.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectory: work,
            deadline: .now.advanced(by: .seconds(30)), drainUntil: .now.advanced(by: .seconds(300)),
            arguments: [Self.fakeAcPAgentURL().path, "full"]
        )
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "claudeCode"))
        let profile = try ClaudeCodeACPSession.profile()
        let versions = PineAdapterContractVersionRange(
            minimum: .init(major: 1, minor: 1), maximum: .init(major: 1, minor: 1)
        )
        let recorder = ACPSessionRecorder()
        let factoryID = try AdapterFactoryID(validating: "test.claude-code.spawned")
        let observation = try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion),
            detectedSchema: nil, offeredProfiles: [profile], offeredContractVersions: versions
        )
        let factory = ClaudeCodeACPFactory(id: factoryID, observation: observation) { request in
            ClaudeCodeACPAdmission(
                launch: { _ in
                    try ClaudeCodeACPStdioTransport(
                        channel: child.channel, authority: request.controlAuthority,
                        revokeOwnership: {}, child: child
                    )
                }, cwd: work.path, deadline: .now.advanced(by: .seconds(30)), loadSession: nil,
                beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                promptResponded: { _ in .recorded }, sessionCreated: { recorder.set($0) }
            )
        }
        let adapterID = try AdapterID(validating: "claude-code:spawned")
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation], compiledAdapters: [(AdapterDescriptor(
                adapterID: adapterID, agentID: presentation.agentID, factoryID: factoryID,
                contractVersions: versions, maximumProfiles: [profile]
            ), factory)]
        )
        let offer = try await registry.probe(adapterID: adapterID)
        let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO],
            acceptedAuthentication: [.ownedChildPipe]
        ))
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        let concrete = try #require(recorder.value)
        try await session.start()
        let controls = try registry.controls(for: session)
        _ = try await controls.dispatch(.submitInstruction("Full fixture"), beforeDispatch: {})
        let waiting = try await wait(concrete) { $0.questions.count == 2 }
        let form = try #require(waiting.questions.first { !$0.permission })
        let permission = try #require(waiting.questions.first { $0.permission })
        #expect(permission.childOwner == nil)
        _ = try await controls.dispatch(.answerQuestion(
            request: form.request, context: form.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        _ = try await controls.dispatch(.answerPermission(
            request: permission.request, context: permission.context, decision: .allowOnce
        ), beforeDispatch: {})
        let result = try await wait(concrete) {
            $0.parentOutcome == .unverified && $0.answersAwaitingEvidence == 0
        }
        #expect(result.result == "Fake complete." && result.children.isEmpty)
        #expect(!result.ready && !result.settlementKnown)
        _ = try await controls.dispatch(.submitInstruction("Same session"), beforeDispatch: {})
        let context = try #require(await concrete.snapshot().context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        let cancelled = try await wait(concrete) { $0.parentOutcome == .cancelled }
        #expect(cancelled.nativeSession?.rawValue == "ses_fake" && !cancelled.ready)
        await session.stop(deadline: .now.advanced(by: .seconds(10)))
        if let identity = child.processIdentity {
            let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
            #expect(remaining == nil || remaining != identity)
        }
    }

    /// The stderr drain is owned by the session lifetime (drainUntil), not
    /// the launch window: a healthy child outlives the spawn deadline without
    /// the channel being fenced.
    @Test func drainOutlivesLaunchWindowWithoutFencingHealthyChild() async throws {
        let script = Self.fakeAcPAgentURL()
        try #require(FileManager.default.isExecutableFile(atPath: script.path))
        let work = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let child = try await ClaudeCodeACPLaunch.spawn(
            executableURL: script, workingDirectory: work,
            deadline: .now.advanced(by: .seconds(5)), drainUntil: .now.advanced(by: .seconds(300)),
            arguments: ["turn"]
        )
        defer { _ = Task.detached { await child.stop(.now.advanced(by: .seconds(10))) } }
        // Past the launch window the child is blocked on stdin (a live,
        // healthy agent); the drain must still own it.
        try await Task.sleep(for: .seconds(7))
        #expect(throws: Never.self) { try child.channel.validateOpen() }
        if let identity = child.processIdentity {
            let alive = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
            #expect(alive == identity)
        }
        await child.stop(.now.advanced(by: .seconds(10)))
    }

    /// Drain loss (deadline expiry with a live child) tears down the whole
    /// owner: the channel closes and the child is terminated, never orphaned.
    @Test func drainLossTearsDownChildInsteadOfOrphaning() async throws {
        let script = Self.fakeAcPAgentURL()
        try #require(FileManager.default.isExecutableFile(atPath: script.path))
        let work = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let child = try await ClaudeCodeACPLaunch.spawn(
            executableURL: script, workingDirectory: work,
            deadline: .now.advanced(by: .seconds(5)), drainUntil: .now.advanced(by: .seconds(7)),
            arguments: ["turn"]
        )
        try await Task.sleep(for: .seconds(9))
        #expect(throws: CodexAppServerWireError.self) { try child.channel.validateOpen() }
        if let identity = child.processIdentity {
            let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
            #expect(remaining == nil || remaining != identity)
        }
        await child.stop(.now.advanced(by: .seconds(10)))
    }

    /// The launch window bounds launch/bootstrap only: session reads run until
    /// transport loss/stop and writes keep a fresh per-operation bound, so a
    /// healthy long turn is never fenced by the fixed instant.
    @Test func sessionIOLongOutlivesTheLaunchWindow() async throws {
        let sessionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        let fixture = try await fixture(deadline: sessionDeadline)
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Long turn"), beforeDispatch: {})
        for _ in 0..<100 where fixture.transport.lastReadDeadline == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The read must not be fenced by the launch window; it outlives it.
        let readDeadline = try #require(fixture.transport.lastReadDeadline)
        #expect(readDeadline > sessionDeadline)
        let writeDeadline = try #require(fixture.transport.lastWriteDeadline)
        #expect(writeDeadline > sessionDeadline)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    // MARK: - Capacity fences

    @Test func oversizedFrameFencesEncode() throws {
        // One byte over the frame cap is the minimal deterministic trigger.
        let big = String(repeating: "x", count: CodexAppServerFramer.maximumFrameBytes + 1)
        let message = CodexAppServerMessage.request(.integer(2), method: "session/prompt", params: .object([
            "sessionId": .string("ses_fixture"),
            "prompt": .array([.object(["type": .string("text"), "text": .string(big)])])
        ]))
        #expect(throws: ClaudeCodeACPError.capacity) { _ = try ClaudeCodeACPWire.encode(message) }
    }

    /// Retained result is bounded at 65 536 bytes; overflow fences the
    /// connection to unknown instead of growing unbounded.
    @Test func resultCapFencesSession() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Fill"), beforeDispatch: {})
        fixture.transport.push(chunk(String(repeating: "a", count: 30_000)))
        fixture.transport.push(chunk(String(repeating: "b", count: 30_000)))
        fixture.transport.push(chunk(String(repeating: "c", count: 30_000)))
        let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
        #expect(unknown.result.utf8.count == 60_000)
        #expect(!unknown.ready)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    private func fixture(
        loadSession: VendorReference? = nil, rejectLoad: Bool = false, fenceResponse: Bool = false,
        initializeResult: AgentEventJSON? = nil, authNotificationsBetweenBootstrap: Bool = false,
        sessionNewResult: AgentEventJSON? = nil,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
        ingest: @escaping AgentAdapterRegistry.Downstream = { _ in .accepted }
    ) async throws -> ACPFixture {
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "claudeCode"))
        let agent = presentation.agentID
        let adapter = try AdapterID(validating: "claude-code:acp")
        let factoryID = try AdapterFactoryID(validating: "test.claude-code.acp")
        let profile = try ClaudeCodeACPSession.profile()
        let versions = PineAdapterContractVersionRange(minimum: .init(major: 1, minor: 1),
                                                       maximum: .init(major: 1, minor: 1))
        let transport = ACPFakeTransport(
            rejectLoad: rejectLoad, initializeResult: initializeResult,
            authNotificationsBetweenBootstrap: authNotificationsBetweenBootstrap,
            sessionNewResult: sessionNewResult
        )
        let recorder = ACPSessionRecorder()
        let factory = ACPFixtureFactory(id: factoryID, transport: transport, recorder: recorder,
                                        profile: profile, versions: versions, loadSession: loadSession,
                                        fenceResponse: fenceResponse, deadline: deadline)
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(AdapterDescriptor(
                adapterID: adapter, agentID: agent, factoryID: factoryID,
                contractVersions: versions, maximumProfiles: [profile]
            ), factory)]
        )
        let offer = try await registry.probe(adapterID: adapter)
        let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil, downstream: ingest)
        let concrete = try #require(recorder.value)
        return ACPFixture(registry: registry, contract: contract, session: session, concrete: concrete, transport: transport)
    }

    private func wait(_ session: ClaudeCodeACPSession,
                      until predicate: @Sendable (ClaudeCodeACPSession.Snapshot) -> Bool) async throws
        -> ClaudeCodeACPSession.Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeCodeACPError.unavailable
    }

    static func fixtureLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/\(name)")
        let data = try Data(contentsOf: url)
        let lines = try data.split(separator: 10).map { bytes in
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                throw ClaudeCodeACPError.invalidProtocol
            }
            return line
        }
        guard !lines.isEmpty else { throw ClaudeCodeACPError.invalidProtocol }
        return lines
    }

    static func fakeAcPAgentURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/fake-claude-agent-acp.sh")
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pine-1727-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Supervised `cat` child that feeds one fixture file over real pipes.
    /// The caller owns the file and its directory (and their cleanup).
    static func spawnFixtureFile(at file: URL, workingDirectory: URL) async throws -> ClaudeCodeACPOwnedChild {
        try await ClaudeCodeACPLaunch.spawn(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            workingDirectory: workingDirectory,
            deadline: .now.advanced(by: .seconds(10)), drainUntil: .now.advanced(by: .seconds(60)),
            arguments: [file.path]
        )
    }
}

// Sanitized ACP v1 source-shaped fixtures, not captured provider transcripts.
private func form(toolCallID: String? = "question-tool") -> AgentEventJSON {
    var fields: [String: AgentEventJSON] = [
        "mode": .string("form"), "sessionId": .string("ses_fixture"), "message": .string("Which color?"),
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
    if let toolCallID { fields["toolCallId"] = .string(toolCallID) }
    return .object(fields)
}

private func permission(toolCallID: String = "write-1") -> AgentEventJSON {
    let tool: [String: AgentEventJSON] = [
        "toolCallId": .string(toolCallID), "title": .string("Write fixture.txt"), "kind": .string("edit")
    ]
    return .object([
        "sessionId": .string("ses_fixture"), "toolCall": .object(tool),
        "options": .array([
            .object(["optionId": .string("once"), "kind": .string("allow_once")]),
            .object(["optionId": .string("always"), "kind": .string("allow_always")]),
            .object(["optionId": .string("reject"), "kind": .string("reject_once")])
        ])
    ])
}

private func toolCompletion(_ id: String) -> CodexAppServerMessage {
    .notification(method: "session/update", params: .object([
        "sessionId": .string("ses_fixture"), "update": .object([
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string(id), "status": .string("completed")
        ])
    ]))
}

private func chunk(_ text: String) -> CodexAppServerMessage {
    .notification(method: "session/update", params: .object([
        "sessionId": .string("ses_fixture"), "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)])
        ])
    ]))
}

private func endTurn() -> CodexAppServerMessage {
    .response(.integer(2), result: .object(["stopReason": .string("end_turn")]))
}

nonisolated struct ACPCheckpointEvidence: Sendable {
    let checkpoint: AdapterResumeCheckpoint
    let request: AgentAdapterSessionRequest
}

nonisolated final class ACPCheckpointRequestRecorder: Sendable {
    private let value = Mutex<AgentAdapterSessionRequest?>(nil)
    var request: AgentAdapterSessionRequest? { value.withLock { $0 } }
    func set(_ request: AgentAdapterSessionRequest) { value.withLock { $0 = request } }
}

func makeResumeCheckpointForClaudeTests() async throws -> ACPCheckpointEvidence {
    let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "codex"))
    let profile = try AdapterCapabilityProfile(
        transport: .ownedStandardIO,
        lifecycle: AdapterLifecycleCapabilities(signals: [.init(scope: .session, phase: .started)], evidence: []),
        delivery: AdapterDeliverySemantics(
            replay: .sourceCursor, ordering: .ordered, minimumAuthentication: .ownedChildPipe
        )
    )
    let versions = PineAdapterContractVersionRange(
        minimum: .init(major: 1, minor: 0), maximum: .init(major: 1, minor: 0)
    )
    let factoryID = try AdapterFactoryID(validating: "test.claude.checkpoint.factory")
    let adapterID = try AdapterID(validating: "test:claude:checkpoint")
    let recorder = ACPCheckpointRequestRecorder()
    let factory = ACPCheckpointFactory(
        id: factoryID, profile: profile, versions: versions, recorder: recorder
    )
    let registry = try AgentAdapterRegistry(
        compiledPresentations: [presentation],
        compiledAdapters: [(AdapterDescriptor(
            adapterID: adapterID, agentID: presentation.agentID, factoryID: factoryID,
            contractVersions: versions, maximumProfiles: [profile]
        ), factory)]
    )
    let offer = try await registry.probe(adapterID: adapterID)
    let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
        allowedVersions: versions, transportPreference: [.ownedStandardIO],
        acceptedAuthentication: [.ownedChildPipe]
    ))
    let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
    try await session.start()
    let checkpoint = try await registry.makeCheckpoint(for: session)
    _ = try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { _ in .accepted }
    return ACPCheckpointEvidence(checkpoint: checkpoint, request: try #require(recorder.request))
}

nonisolated struct ACPCheckpointFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let profile: AdapterCapabilityProfile
    let versions: PineAdapterContractVersionRange
    let recorder: ACPCheckpointRequestRecorder
    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion("checkpoint-fixture"), detectedSchema: nil,
            offeredProfiles: [profile], offeredContractVersions: versions
        )
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        recorder.set(request)
        return ACPCheckpointSession(contract: request.contract, sink: request.sink)
    }
}

nonisolated struct ACPCheckpointSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let sink: any AgentEventSink
    func start() async throws {
        let position = try AdapterSourcePosition(
            sourceEvent: VendorReference(role: .event, value: "checkpoint-event"),
            resumePosition: AdapterResumePosition("cursor-1"), sourceSequence: 1
        )
        let lifecycle = try CandidateLifecycleEvent(
            scope: .session, phase: .started,
            reference: VendorReference(role: .conversation, value: "checkpoint-session")
        )
        let outcome = await sink.ingest(AdapterCandidate(
            event: .lifecycle(lifecycle), sourcePosition: position
        ))
        guard outcome == .accepted || outcome == .bufferedUntilActivation else {
            throw ClaudeCodeACPError.unavailable
        }
    }
    func stop(deadline: ContinuousClock.Instant) async { }
}

nonisolated private struct ACPFixture: Sendable {
    let registry: AgentAdapterRegistry
    let contract: NegotiatedAdapterContract
    let session: any AgentAdapterSession
    let concrete: ClaudeCodeACPSession
    let transport: ACPFakeTransport
}

nonisolated private final class ACPSessionRecorder: Sendable {
    private let session = Mutex<ClaudeCodeACPSession?>(nil)
    var value: ClaudeCodeACPSession? { session.withLock { $0 } }
    func set(_ value: ClaudeCodeACPSession) { session.withLock { $0 = value } }
}

nonisolated private struct ACPFixtureFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let transport: ACPFakeTransport
    let recorder: ACPSessionRecorder
    let profile: AdapterCapabilityProfile
    let versions: PineAdapterContractVersionRange
    let loadSession: VendorReference?
    let fenceResponse: Bool
    let deadline: ContinuousClock.Instant
    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(detectedVendorVersion: DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion), detectedSchema: nil,
                               offeredProfiles: [profile], offeredContractVersions: versions)
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        let factory = ClaudeCodeACPFactory(
            id: id, observation: try await probe(),
            discovery: ClaudeCodeACPConfigurationDiscovery.Input(
                selectedExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/claude-agent-acp", isDirectory: false),
                environmentProvenance: .inheritedPineProcess
            )
        ) { _ in
            ClaudeCodeACPAdmission(launch: { _ in
                transport.markLaunched()
                return transport
            }, cwd: "/fixture/task",
                                 deadline: deadline, loadSession: loadSession,
                                 beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                                 promptResponded: { _ in fenceResponse ? .fenced : .recorded },
                                 sessionCreated: { _ in })
        }
        let session = try await factory.makeSession(request)
        guard let concrete = session as? ClaudeCodeACPSession else { throw ClaudeCodeACPError.invalidState }
        recorder.set(concrete)
        return session
    }
}

nonisolated private final class ACPFakeTransport: ClaudeCodeACPTransport, Sendable {
    private struct State {
        var queue: [CodexAppServerMessage] = []
        var waiter: CheckedContinuation<CodexAppServerMessage?, any Error>?
        var writes: [Data] = []
        var closed = false
        var failWrite = false
        var launches = 0
        var lastReadDeadline: ContinuousClock.Instant?
        var lastWriteDeadline: ContinuousClock.Instant?
    }
    private let state = Mutex(State())
    private let rejectLoad: Bool
    private let initializeResult: AgentEventJSON?
    private let authNotificationsBetweenBootstrap: Bool
    private let sessionNewResult: AgentEventJSON?
    init(
        rejectLoad: Bool = false,
        initializeResult: AgentEventJSON? = nil,
        authNotificationsBetweenBootstrap: Bool = false,
        sessionNewResult: AgentEventJSON? = nil
    ) {
        self.rejectLoad = rejectLoad
        self.initializeResult = initializeResult
        self.authNotificationsBetweenBootstrap = authNotificationsBetweenBootstrap
        self.sessionNewResult = sessionNewResult
    }
    var launchCount: Int { state.withLock { $0.launches } }
    var lastReadDeadline: ContinuousClock.Instant? { state.withLock { $0.lastReadDeadline } }
    var lastWriteDeadline: ContinuousClock.Instant? { state.withLock { $0.lastWriteDeadline } }
    func markLaunched() { state.withLock { $0.launches += 1 } }
    func validate() throws {
        try state.withLock { if $0.closed { throw ClaudeCodeACPError.unavailable } }
    }
    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
        state.withLock { $0.lastReadDeadline = deadline }
        let timeout = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                self.close()
            } catch { /* The read settled before its deadline. */ }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if state.closed {
                        continuation.resume(returning: nil)
                    } else if !state.queue.isEmpty {
                        continuation.resume(returning: state.queue.removeFirst())
                    } else if state.waiter != nil {
                        continuation.resume(throwing: ClaudeCodeACPError.invalidState)
                    } else {
                        state.waiter = continuation
                    }
                }
            }
        } onCancel: { self.close() }
    }
    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws {
        try beforeWrite()
        let message = try CodexAppServerMessage(data: bytes)
        try state.withLock { state in
            state.lastWriteDeadline = deadline
            guard !state.closed else { throw ClaudeCodeACPError.unavailable }
            state.writes.append(bytes)
            if state.failWrite { throw ClaudeCodeACPError.unavailable }
        }
        if case .request(let id, let method, _) = message {
            if method == "initialize" {
                let result = initializeResult ?? .object([
                    "protocolVersion": .number("1"),
                    "agentInfo": .object([
                        "name": .string(ClaudeCodeACPSession.pinnedAgentName),
                        "version": .string(ClaudeCodeACPSession.pinnedVersion)
                    ]),
                    "agentCapabilities": .object(["loadSession": .bool(true)])
                ])
                push(.response(id, result: result))
                if authNotificationsBetweenBootstrap {
                    push(.notification(method: "_auth/status_update", params: .object([
                        "status": .string("unknown")
                    ])))
                    push(.notification(method: "auth/status_update", params: .object([
                        "status": .string("unknown")
                    ])))
                }
            } else if method == "session/new" {
                push(.response(id, result: sessionNewResult ?? .object([
                    "sessionId": .string("ses_fixture")
                ])))
            } else if method == "session/load" {
                if rejectLoad {
                    push(.failure(id, code: -32602))
                } else {
                    push(.response(id, result: .object([:])))
                }
            }
        }
    }
    func push(_ message: CodexAppServerMessage) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexAppServerMessage?, any Error>? in
            guard !state.closed else { return nil }
            if let waiter = state.waiter { state.waiter = nil; return waiter }
            state.queue.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }
    func writes() throws -> [CodexAppServerMessage] {
        try state.withLock { try $0.writes.map { try CodexAppServerMessage(data: $0, requireJSONRPCVersion: true) } }
    }
    func failNextWrite() { state.withLock { $0.failWrite = true } }
    func close() {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
    func stop(deadline: ContinuousClock.Instant) async { close() }
}
