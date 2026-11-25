import Foundation
import Observation
import Synchronization
import Testing
@testable import Pine

@Suite("OpenCode pinned ACP first loop")
struct OpenCodeACPTests {
    @Test(arguments: [false, true])
    func pendingUnknownOrChildAskReceivesOneCancelledOutcome(knownChild: Bool) async throws {
        let events = Mutex<[ValidatedAgentEvent]>([])
        let fixture = try await fixture(ingest: { event in
            events.withLock { $0.append(event) }
            return .accepted
        })
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate and ask"), beforeDispatch: {})
        if knownChild {
            fixture.transport.push(childToolUpdate("tool_call", id: "ses_child:write-1", status: "pending"))
            fixture.transport.push(.request(.integer(90), method: "session/request_permission",
                                            params: permission(toolCallID: "ses_child:write-1", child: true)))
        } else {
            fixture.transport.push(.request(.integer(90), method: "elicitation/create", params: form(toolCallID: nil)))
        }
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        if knownChild {
            #expect(question.childOwner?.rawValue == "ses_child")
        } else {
            #expect(question.childOwner == nil)
        }
        let context = try #require(waiting.context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        #expect(await fixture.concrete.snapshot().cancellationRequested)
        fixture.transport.push(.response(.integer(2), result: .object(["stopReason": .string("cancelled")])))
        let cancelled = try await wait(fixture.concrete) {
            $0.parentOutcome == .cancelled && !$0.cancellationRequested
        }
        #expect(cancelled.questions.isEmpty)
        #expect(cancelled.submittedQuestions.contains { $0.id == question.id })
        #expect(!events.withLock { $0 }.contains {
            if case .requestResolved(let resolution) = $0.candidate.event {
                return resolution.request == question.request
            }
            return false
        })
        if knownChild {
            await #expect(throws: OpenCodeACPError.invalidAnswer) {
                _ = try await controls.dispatch(.answerPermission(
                    request: question.request, context: question.context, decision: .deny
                ), beforeDispatch: {})
            }
        } else {
            await #expect(throws: OpenCodeACPError.invalidAnswer) {
                _ = try await controls.dispatch(.answerQuestion(
                    request: question.request, context: question.context, answers: ["color": ["blue"]]
                ), beforeDispatch: {})
            }
        }
        let cancelledReplies = try fixture.transport.writes().filter { $0 == .response(
            .integer(90), result: knownChild
                ? .object(["outcome": .object(["outcome": .string("cancelled")])])
                : .object(["action": .string("cancel")])
        ) }
        #expect(cancelledReplies.count == 1)
        #expect(!cancelled.ready && !cancelled.settlementKnown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func projectedChildPermissionResolvesExactlyOnceWithOriginalWireToolID() async throws {
        let events = Mutex<[ValidatedAgentEvent]>([])
        let fixture = try await fixture(ingest: { event in
            events.withLock { $0.append(event) }
            return .accepted
        })
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate write"), beforeDispatch: {})
        fixture.transport.push(childToolUpdate("tool_call", id: "ses_child:write-1", status: "pending"))
        fixture.transport.push(.request(.integer(91), method: "session/request_permission",
                                        params: permission(toolCallID: "ses_child:write-1", child: true)))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        let question = try #require(waiting.questions.first)
        #expect(question.childOwner?.rawValue == "ses_child")
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .allowOnce
        ), beforeDispatch: {})
        #expect(await fixture.concrete.snapshot().submittedQuestions.count == 1)
        fixture.transport.push(childToolUpdate("tool_call_update", id: "ses_child:write-1", status: "completed"))
        fixture.transport.push(child("completed"))
        let complete = try await wait(fixture.concrete) { $0.children.values.contains("completed") }
        #expect(complete.submittedQuestions.isEmpty && complete.questions.isEmpty)
        #expect(events.withLock { $0 }.filter {
            if case .requestResolved(let resolution) = $0.candidate.event {
                return resolution.request == question.request
            }
            return false
        }.count == 1)
        #expect(!complete.ready && !complete.settlementKnown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func childOwnershipRequiresObservedToolIDBytesNotDisplayEquivalence() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate write"), beforeDispatch: {})
        fixture.transport.push(childToolUpdate("tool_call", id: "ses_child:Café", status: "pending"))
        for (index, identifier) in ["ses_child:Cafe\u{301}", "ses_child:Café"].enumerated() {
            fixture.transport.push(.request(.integer(Int64(98 + index)), method: "session/request_permission",
                                            params: permission(toolCallID: identifier)))
        }
        fixture.transport.push(chunk("Both tool ownership lookups processed"))
        let waiting = try await wait(fixture.concrete) { $0.result == "Both tool ownership lookups processed" }
        try #require(waiting.questions.count == 2)
        #expect(waiting.questions[0].childOwner == nil)
        #expect(waiting.questions[1].childOwner?.rawValue == "ses_child")
        #expect(!waiting.ready && !waiting.settlementKnown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

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

    @Test func fencedLateResponseCannotEnableFeedbackOrKillOwnedChildQuestions() async throws {
        let fixture = try await fixture(fenceResponse: true)
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
        fixture.transport.push(endTurn())
        let result = try await wait(fixture.concrete) { $0.inputFenced }
        #expect(result.parentOutcome == .unverified && !result.ready)
        await #expect(throws: OpenCodeACPError.invalidState) {
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
        let taskID = UUID()
        let runID = UUID()
        let runtime = try OpenCodeACPTaskRuntime(
            taskID: taskID, runID: runID, bindingID: UUID(),
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
        func decision(runID: UUID) -> AgentTaskReviewDecision {
            AgentTaskReviewDecision(
                cycleID: UUID(), taskID: taskID, runID: runID, blocker: .checksFailed,
                round: 1, unresolvedFindingReference: nil,
                candidateCodeState: ADEContractFixtures.codeState("a"),
                candidateEnvironment: ADEContractFixtures.environment
            )
        }
        let writeCount = try fixture.transport.writes().count
        #expect(await runtime.submitResultDecisionReply(
            "Wrong attempt", decision: decision(runID: UUID())
        ) == false)
        #expect(try fixture.transport.writes().count == writeCount)
        #expect(await runtime.submitResultDecisionReply(
            "Explicit same-session feedback", decision: decision(runID: runID)
        ))
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
        let runtime = try OpenCodeACPTaskRuntime(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            registry: fixture.registry, owner: fixture.session, provider: fixture.concrete,
            taskIsCurrent: { current.withLock { $0 } }, prepareControl: { _ in }, beforeDispatch: { _ in
                try current.withLock { if !$0 { throw OpenCodeACPError.unavailable } }
            }
        )
        try await runtime.start()
        _ = try await runtime.submit("Ask")
        fixture.transport.push(.request(.integer(55), method: "session/request_permission", params: permission()))
        try #require(await waitUntilMainActor { runtime.snapshot?.questions.count == 1 })
        let approval = try #require(runtime.snapshot?.questions.first)
        #expect(approval.allowOnceOptionID == "once" && approval.denyOptionID == "reject")
        await #expect(throws: OpenCodeACPError.invalidAnswer) {
            _ = try await runtime.answerPermission(approval, optionID: "always", decision: .allowOnce)
        }
        await #expect(throws: OpenCodeACPError.invalidAnswer) {
            _ = try await runtime.answerPermission(approval, optionID: "reject", decision: .allowOnce)
        }
        await #expect(throws: OpenCodeACPError.invalidAnswer) {
            _ = try await runtime.answerQuestion(approval, answers: ["text": ["yes"]])
        }
        _ = try await runtime.answerPermission(approval, optionID: "reject", decision: .deny)
        let count = try fixture.transport.writes().count
        current.withLock { $0 = false }
        await #expect(throws: OpenCodeACPError.unavailable) { _ = try await runtime.submit("Do not send") }
        #expect(try fixture.transport.writes().count == count)
        fixture.transport.push(chunk("Late output from retired source"))
        try #require(await waitUntilMainActor { runtime.snapshot == nil })
        await runtime.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @MainActor
    @Test func unsupportedQuestionRetainsExplicitCleanupWithoutClaimingConfirmedCancellation() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let runtime = try OpenCodeACPTaskRuntime(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            registry: fixture.registry, owner: fixture.session, provider: fixture.concrete,
            taskIsCurrent: { true }, prepareControl: { _ in }, beforeDispatch: { _ in }
        )
        try await runtime.start()
        _ = try await runtime.submit("Ask")
        var fields = try OpenCodeACPWire.object(form())
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

    @Test func sessionStartProducesDiscoveryReportFromObservedOptions() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        let beforeStart = await fixture.concrete.discoveryReport
        #expect(beforeStart == nil)
        try await fixture.session.start()
        let afterStart = await fixture.concrete.discoveryReport
        let report = try #require(afterStart)
        #expect(report.executableIdentity == .resolved(URL(fileURLWithPath: "/fixture/opencode")))
        #expect(report.sessionStart == .started)
        #expect(report.configurationCapabilities.model.state == .probed)
        #expect(report.configurationCapabilities.model.enumeratedOptions.map(\.nativeValue) == [
            "fixture/model",
        ])
        #expect(report.configurationCapabilities.permissions.state == .unknown)
        #expect(report.effectiveModel == .unknown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
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
        await #expect(throws: OpenCodeACPError.invalidState) {
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
        await #expect(throws: OpenCodeACPError.invalidAnswer) {
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
            #expect(try OpenCodeACPWire.object(prompt)["sessionId"] == .string("ses_fixture"))
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    /// Child output after the answer but before the parent response belongs to
    /// the active turn and stays attributed to it.
    @Test func childQuestionBeforeParentEndKeepsInFlightOutputAndAllowsFeedback() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate"), beforeDispatch: {})
        fixture.transport.push(child("created"))
        fixture.transport.push(child("running"))
        fixture.transport.push(.request(.string("child-ask"), method: "elicitation/create",
                                        params: form(toolCallID: "question-tool")))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 && $0.state == .waiting }
        let question = try #require(waiting.questions.first)
        #expect(question.childOwner == nil) // Pinned child forms can omit ownership metadata.
        _ = try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        fixture.transport.push(toolCompletion("question-tool"))
        fixture.transport.push(child("completed"))
        fixture.transport.push(chunk("CHILD_ACK_BLUE"))
        fixture.transport.push(endTurn())
        let result = try await wait(fixture.concrete) {
            $0.parentOutcome == .unverified && $0.result == "CHILD_ACK_BLUE"
        }
        #expect(result.children.values.contains("completed"))
        #expect(result.state == .unverified)
        #expect(!result.ready && !result.settlementKnown)
        #expect(try await controls.dispatch(
            .submitInstruction("Explicit feedback after child output"), beforeDispatch: {}
        ) == .acknowledged)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    /// Child/root activity after the parent response has no turn to belong to.
    /// ACP 2.4.0 supplies no root-final boundary, so the late text can never
    /// start a result and later input stays fenced.
    @Test func lateChildAndRootOutputAfterParentEndFencesFeedbackWithoutResult() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate"), beforeDispatch: {})
        fixture.transport.push(child("created"))
        fixture.transport.push(child("running"))
        fixture.transport.push(endTurn())
        fixture.transport.push(.request(.string("child-ask"), method: "elicitation/create",
                                        params: form(toolCallID: "question-tool")))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 && $0.state == .waiting }
        let question = try #require(waiting.questions.first)
        _ = try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        fixture.transport.push(toolCompletion("question-tool"))
        fixture.transport.push(child("completed"))
        fixture.transport.push(chunk("CHILD_ACK_BLUE"))
        let fenced = try await wait(fixture.concrete) { $0.inputFenced }
        #expect(fenced.result == "" && !fenced.result.contains("CHILD_ACK_BLUE"))
        #expect(fenced.children.values.contains("completed"))
        #expect(fenced.parentOutcome == .unverified)
        #expect(!fenced.ready && !fenced.settlementKnown)
        #expect(try fixture.transport.writes().filter {
            if case .request(_, "session/prompt", _) = $0 { true } else { false }
        }.count == 1)
        await #expect(throws: OpenCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Fenced after late output"), beforeDispatch: {})
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

    @Test func denialIsOneShotAndCancelledResponseIsNotSuccess() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Write"), beforeDispatch: {})
        fixture.transport.push(.request(.integer(20), method: "session/request_permission", params: permission()))
        let waiting = try await wait(fixture.concrete) { !$0.questions.isEmpty }
        let question = try #require(waiting.questions.first)
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .deny
        ), beforeDispatch: {})
        let responses = try fixture.transport.writes()
        #expect(responses.contains(.response(.integer(20), result: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("reject")])
        ]))))
        fixture.transport.push(.response(.integer(2), result: .object(["stopReason": .string("cancelled")])))
        let cancelled = try await wait(fixture.concrete) { $0.state == .cancelled }
        #expect(!cancelled.ready)
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

    @Test func unsupportedQuestionBlocksInsteadOfReturningFallbackError() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Question"), beforeDispatch: {})
        var fields = try OpenCodeACPWire.object(form())
        fields["mode"] = .string("url")
        fixture.transport.push(.request(.string("unsupported"), method: "elicitation/create", params: .object(fields)))
        let blocked = try await wait(fixture.concrete) { $0.state == .blocked }
        #expect(!blocked.ready)
        #expect(try fixture.transport.writes().count == 3)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func foreignSessionDuplicateResponseAndDuplicateAnsweredRequestFenceOwner() async throws {
        for negative in 0..<3 {
            let fixture = try await fixture()
            defer { fixture.transport.close() }
            try await fixture.session.start()
            let controls = try fixture.registry.controls(for: fixture.session)
            _ = try await controls.dispatch(.submitInstruction("Request"), beforeDispatch: {})
            switch negative {
            case 0:
                fixture.transport.push(.notification(method: "session/update", params: .object([
                    "sessionId": .string("ses_foreign"), "update": .object(["sessionUpdate": .string("tool_call")])
                ])))
            case 1:
                fixture.transport.push(endTurn())
                fixture.transport.push(endTurn())
            default:
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
            }
            let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
            #expect(!unknown.ready && unknown.questions.isEmpty)
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
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
        let fields = try OpenCodeACPWire.object(params)
        #expect(fields["sessionId"] == .string("ses_exact"))
        #expect(fields["cwd"] == .string("/fixture/task"))
        #expect(await fixture.concrete.snapshot().state == .idle)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func missingSessionOrWrongCwdLoadFailureDoesNotFallBackToNewSession() async throws {
        let reference = try VendorReference(role: .conversation, value: "ses_missing")
        let fixture = try await fixture(loadSession: reference, rejectLoad: true)
        defer { fixture.transport.close() }
        await #expect(throws: OpenCodeACPError.providerFailure(-32602)) {
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
        await #expect(throws: OpenCodeACPError.unavailable) {
            _ = try await controls.dispatch(.submitInstruction("Do not send"), beforeDispatch: {
                throw OpenCodeACPError.unavailable
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

    @Test func documentedChildMetadataOwnsUpdatesAndDirectPermissions() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate"), beforeDispatch: {})
        fixture.transport.push(.notification(method: "session/update", params: .object([
            "sessionId": .string("ses_fixture"), "update": .object([
                "sessionUpdate": .string("agent_message_chunk"), "_meta": .null,
                "content": .object(["type": .string("text"), "text": .string("nullable metadata")])
            ])
        ])))
        _ = try await wait(fixture.concrete) { $0.result == "nullable metadata" }
        fixture.transport.push(.notification(method: "session/update", params: .object([
            "sessionId": .string("ses_fixture"), "update": .object([
                "sessionUpdate": .string("tool_call"), "toolCallId": .string("ses_child:write-1"),
                "status": .string("pending"),
                "_meta": .object(["opencode/child-session": .object([
                    "id": .string("ses_child"), "parentID": .string("ses_fixture"), "depth": .number("1")
                ])])
            ])
        ])))
        fixture.transport.push(.request(.integer(93), method: "session/request_permission",
                                        params: permission(toolCallID: "ses_child:write-1", child: true)))
        let waiting = try await wait(fixture.concrete) { $0.questions.count == 1 }
        #expect(waiting.questions.first?.childOwner?.rawValue == "ses_child")
        #expect(waiting.children[try VendorReference(role: .conversation, value: "ses_child")] == "observed")
        fixture.transport.push(endTurn())
        let result = try await wait(fixture.concrete) { $0.parentOutcome == .unverified }
        #expect(result.questions.count == 1 && !result.ready && !result.settlementKnown)
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
        await #expect(throws: OpenCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Ambiguous continuation"), beforeDispatch: {})
        }
        #expect(await fixture.concrete.snapshot().result == "retained result")
        #expect(try fixture.transport.writes().filter {
            if case .request(_, "session/prompt", _) = $0 { true } else { false }
        }.count == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func oldChildChunkAfterSecondPromptIsFencedWithoutClearingPriorResult() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("First"), beforeDispatch: {})
        fixture.transport.push(child("running"))
        fixture.transport.push(child("completed"))
        fixture.transport.push(chunk("first result"))
        fixture.transport.push(endTurn())
        _ = try await wait(fixture.concrete) { $0.parentOutcome == .unverified }
        _ = try await controls.dispatch(.submitInstruction("Second"), beforeDispatch: {})
        #expect(await fixture.concrete.snapshot().result == "first result")
        fixture.transport.push(childText("STALE_OLD_CHILD"))
        let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
        #expect(unknown.result == "first result")
        #expect(!unknown.result.contains("STALE_OLD_CHILD") && !unknown.ready)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func allObservedChildMetadataConsumesTheSixtyFourChildBound() async throws {
        let fixture = try await fixture()
        defer { fixture.transport.close() }
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("Delegate broadly"), beforeDispatch: {})
        for index in 0..<65 {
            fixture.transport.push(documentedChildChunk(index))
        }
        let unknown = try await wait(fixture.concrete) { $0.state == .unknown }
        #expect(unknown.children.count == 64 && !unknown.ready)
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
        ], provider: "OpenCode")
    }

    // MARK: - Pinned real-pipe codec + spawn coverage

    /// The version-pinned turn fixture replays through the REAL channel: a
    /// supervised `cat` child feeds the raw frames over real pipes through the
    /// JSONL framer with the ACP version requirement.
    @Test func pinnedTurnFixtureReplaysOverRealChannel() async throws {
        let lines = try Self.fixtureLines("acp-opencode-v2.4.0-turn.jsonl")
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
        #expect(try OpenCodeACPWire.object(result)["agentInfo"] == .object([
            "name": .string("OpenCode"), "version": .string(OpenCodeACPSession.pinnedVersion)
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
        let lines = try Self.fixtureLines("acp-opencode-v2.4.0-faults.jsonl")
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
        let lines = try Self.fixtureLines("acp-opencode-v2.4.0-faults.jsonl")
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
            let child = try await OpenCodeACPLaunch.spawn(
                executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectory: work,
                deadline: .now.advanced(by: .seconds(30)), drainUntil: .now.advanced(by: .seconds(300)),
                arguments: [script.path, scenario]
            )
            let transport = try OpenCodeACPStdioTransport(channel: child.channel, child: child)
            defer { _ = Task.detached { await transport.stop(deadline: .now.advanced(by: .seconds(10))) } }
            let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10))
            try await transport.write(OpenCodeACPWire.encode(
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
            #expect(try OpenCodeACPWire.object(result)["agentInfo"] == .object([
                "name": .string("OpenCode"), "version": .string(OpenCodeACPSession.pinnedVersion)
            ]))
            try await transport.write(OpenCodeACPWire.encode(.request(.integer(1), method: "session/new",
                                                                       params: .object([
                "cwd": .string(work.path), "mcpServers": .array([])
            ]))), deadline: deadline, beforeWrite: {})
            _ = try await transport.read(deadline: deadline)
            _ = try await transport.read(deadline: deadline)
            try await transport.write(OpenCodeACPWire.encode(.request(.integer(2), method: "session/prompt",
                                                                       params: .object([
                "sessionId": .string("ses_fake"),
                "prompt": .array([.object(["type": .string("text"), "text": .string("Fixture prompt")])])
            ]))), deadline: deadline, beforeWrite: {})
            if scenario == "cancel" {
                try await transport.write(OpenCodeACPWire.encode(.notification(method: "session/cancel",
                                                                               params: .object([
                    "sessionId": .string("ses_fake")
                ]))), deadline: deadline, beforeWrite: {})
            }
            var gotFinal = false
            for _ in 0..<2 {
                let message = try await transport.read(deadline: deadline)
                if case .response(_, let result) = message {
                    gotFinal = true
                    #expect(try OpenCodeACPWire.object(result)["stopReason"] == .string(expectedStop))
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

    @Test func spawnedFakeRunsQuestionPermissionChildFeedbackAndCancellation() async throws {
        let work = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let child = try await OpenCodeACPLaunch.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectory: work,
            deadline: .now.advanced(by: .seconds(30)), drainUntil: .now.advanced(by: .seconds(300)),
            arguments: [Self.fakeAcPAgentURL().path, "full"]
        )
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))
        let profile = try OpenCodeACPSession.profile()
        let versions = PineAdapterContractVersionRange(
            minimum: .init(major: 1, minor: 1), maximum: .init(major: 1, minor: 1)
        )
        let recorder = ACPSessionRecorder()
        let factoryID = try AdapterFactoryID(validating: "test.opencode.spawned")
        let observation = try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(OpenCodeACPSession.pinnedVersion),
            detectedSchema: nil, offeredProfiles: [profile], offeredContractVersions: versions
        )
        let factory = OpenCodeACPFactory(id: factoryID, observation: observation) { request in
            OpenCodeACPAdmission(
                launch: { _ in
                    try OpenCodeACPStdioTransport(
                        channel: child.channel, authority: request.controlAuthority,
                        revokeOwnership: {}, child: child
                    )
                }, cwd: work.path, selectedExecutable: URL(fileURLWithPath: "/bin/sh"),
                environmentProvenance: .inheritedPineProcess,
                deadline: .now.advanced(by: .seconds(30)), loadSession: nil,
                beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                promptResponded: { _ in .recorded }, sessionCreated: { recorder.set($0) }
            )
        }
        let adapterID = try AdapterID(validating: "opencode:spawned")
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
        #expect(permission.childOwner?.rawValue == "ses_child")
        _ = try await controls.dispatch(.answerQuestion(
            request: form.request, context: form.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        _ = try await controls.dispatch(.answerPermission(
            request: permission.request, context: permission.context, decision: .allowOnce
        ), beforeDispatch: {})
        let result = try await wait(concrete) {
            $0.parentOutcome == .unverified && $0.answersAwaitingEvidence == 0
        }
        #expect(result.result == "Fake complete." && result.children.values.contains("completed"))
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
        let child = try await OpenCodeACPLaunch.spawn(
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
        let child = try await OpenCodeACPLaunch.spawn(
            executableURL: script, workingDirectory: work,
            deadline: .now.advanced(by: .seconds(5)), drainUntil: .now.advanced(by: .seconds(7)),
            arguments: ["turn"]
        )
        try await Task.sleep(for: .seconds(9))
        await #expect(throws: CodexAppServerWireError.self) { try child.channel.validateOpen() }
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
        #expect(throws: OpenCodeACPError.capacity) { _ = try OpenCodeACPWire.encode(message) }
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
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
        ingest: @escaping AgentAdapterRegistry.Downstream = { _ in .accepted }
    ) async throws -> ACPFixture {
        try await makeOpenCodeACPTestFixture(
            loadSession: loadSession, rejectLoad: rejectLoad, fenceResponse: fenceResponse,
            deadline: deadline, ingest: ingest
        )
    }

    private func wait(_ session: OpenCodeACPSession,
                      until predicate: @Sendable (OpenCodeACPSession.Snapshot) -> Bool) async throws
        -> OpenCodeACPSession.Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenCodeACPError.unavailable
    }

    static func fixtureLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/\(name)")
        let data = try Data(contentsOf: url)
        let lines = try data.split(separator: 10).map { bytes in
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                throw OpenCodeACPError.invalidProtocol
            }
            return line
        }
        guard !lines.isEmpty else { throw OpenCodeACPError.invalidProtocol }
        return lines
    }

    static func fakeAcPAgentURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/fake-acp-agent.sh")
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pine-1811-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Supervised `cat` child that feeds one fixture file over real pipes.
    /// The caller owns the file and its directory (and their cleanup).
    static func spawnFixtureFile(at file: URL, workingDirectory: URL) async throws -> OpenCodeACPOwnedChild {
        try await OpenCodeACPLaunch.spawn(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            workingDirectory: workingDirectory,
            deadline: .now.advanced(by: .seconds(10)), drainUntil: .now.advanced(by: .seconds(60)),
            arguments: [file.path]
        )
    }
}

// Sanitized source-shaped fixtures, not captured native transcripts. Ordering
// follows maintainer probe R3; result hashes/probe limitations are recorded in the handoff.
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

private func permission(toolCallID: String = "write-1", child: Bool = false) -> AgentEventJSON {
    var tool: [String: AgentEventJSON] = [
        "toolCallId": .string(toolCallID), "title": .string("Write fixture.txt"), "kind": .string("edit")
    ]
    if child {
        tool["_meta"] = .object(["opencode/child-session": .object([
            "id": .string("ses_child"), "parentID": .string("ses_fixture"), "depth": .number("1")
        ])])
    }
    return .object([
        "sessionId": .string("ses_fixture"), "toolCall": .object(tool),
        "options": .array([
            .object(["optionId": .string("once"), "kind": .string("allow_once")]),
            .object(["optionId": .string("always"), "kind": .string("allow_always")]),
            .object(["optionId": .string("reject"), "kind": .string("reject_once")])
        ])
    ])
}

private func childToolUpdate(_ kind: String, id: String, status: String) -> CodexAppServerMessage {
    .notification(method: "opencode/session/child_update", params: .object([
        "rootSessionId": .string("ses_fixture"), "childSessionId": .string("ses_child"),
        "parentSessionId": .string("ses_fixture"), "depth": .number("1"), "type": .string("update"),
        "update": .object([
            "sessionUpdate": .string(kind), "toolCallId": .string(id),
            "title": .string("Write fixture.txt"), "kind": .string("edit"), "status": .string(status)
        ])
    ]))
}

private func childText(_ text: String) -> CodexAppServerMessage {
    .notification(method: "opencode/session/child_update", params: .object([
        "rootSessionId": .string("ses_fixture"), "childSessionId": .string("ses_child"),
        "parentSessionId": .string("ses_fixture"), "depth": .number("1"), "type": .string("update"),
        "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)])
        ])
    ]))
}

private func documentedChildChunk(_ index: Int) -> CodexAppServerMessage {
    .notification(method: "session/update", params: .object([
        "sessionId": .string("ses_fixture"), "update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("x")]),
            "_meta": .object(["opencode/child-session": .object([
                "id": .string("ses_\(index)"), "parentID": .string("ses_fixture"), "depth": .number("1")
            ])])
        ])
    ]))
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

private func child(_ status: String) -> CodexAppServerMessage {
    .notification(method: "opencode/session/child_update", params: .object([
        "rootSessionId": .string("ses_fixture"), "childSessionId": .string("ses_child"),
        "parentSessionId": .string("ses_fixture"), "depth": .number("1"),
        "type": .string("status"), "status": .string(status)
    ]))
}

// The fixture machinery is shared with the #1846 contract probe via
// OpenCodeACPTestSupport; these aliases keep this suite's call sites intact.
private typealias ACPFixture = OpenCodeACPTestFixture
private typealias ACPSessionRecorder = OpenCodeACPSessionRecorder
private typealias ACPFixtureFactory = OpenCodeACPTestFixtureFactory
private typealias ACPFakeTransport = OpenCodeACPFakeTransport
