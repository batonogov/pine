import Foundation
import Testing
@testable import Pine

nonisolated private struct ContractTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    func probe() async throws -> AdapterProbeResult { probeResult }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw AdapterSessionError.launchFailed(.permanent)
    }
}

@Suite("Agent adapter core contract")
struct AgentAdapterContractTests {
    @Test func identifiersRequireValidation() throws {
        #expect(throws: AdapterValueError.self) { _ = try AgentID(validating: "CODEX") }
        #expect(throws: AdapterValueError.self) { _ = try AgentID(validating: "cоdex") } // Cyrillic o
        #expect(throws: AdapterValueError.self) { _ = try AgentID(validating: "claudeCode") }
        #expect(throws: AdapterValueError.self) { _ = try AgentID(validating: String(repeating: "a", count: 97)) }
        #expect(try AgentID(validating: "codex").value == "codex")
    }

    @Test func textAndAliasesRejectSpoofs() throws {
        #expect(throws: AdapterValueError.self) { _ = try ExecutableAlias(validating: "../codex") }
        #expect(throws: AdapterValueError.self) { _ = try ExecutableAlias(validating: "Codex") }
        #expect(throws: AdapterValueError.self) {
            _ = try AgentPresentationDescriptor(
                agentID: AgentID(validating: "user:x"), displayName: "safe\u{202E}txt",
                executableAliases: [], style: .generic
            )
        }
    }

    @Test func userRegistrationIsNamespaced() throws {
        let registration = try UserAgentPresentationRegistration(
            identifier: "local", displayName: "Local", executableAliases: ["local-agent"]
        )
        let presentation = try registration.normalized()
        #expect(presentation.agentID.value == "user:local")
        let keys = Set(Mirror(reflecting: registration).children.compactMap(\.label))
        #expect(keys == ["identifier", "displayName", "executableAliases"])
    }

    @Test func legacyCatalogRoundTripsAndCollisions() throws {
        let values = ["claudeCode", "codex", "aider", "copilot", "pi", "generic:Local Tool"]
        let catalog = try LegacyAgentMigrationCatalog(stableIdentifiers: values)
        for value in values {
            let migration = try #require(catalog.lookup(stableIdentifier: value))
            #expect(migration.originalStableIdentifier == value)
            #expect(catalog.lookup(agentID: migration.canonicalAgentID)?.originalStableIdentifier == value)
        }
        #expect(catalog.lookup(stableIdentifier: "codex")?.canonicalAgentID.value == "codex")
        #expect(try LegacyAgentMigrationCatalog(stableIdentifiers: values)
            .lookup(stableIdentifier: "generic:Local Tool")?.canonicalAgentID
            == catalog.lookup(stableIdentifier: "generic:Local Tool")?.canonicalAgentID)
        for malformed in ["", "unknown", "generic:", "generic:\u{202E}bad", String(repeating: "x", count: 257)] {
            #expect(throws: LegacyMigrationError.self) {
                _ = try LegacyAgentMigrationCatalog(stableIdentifiers: [malformed])
            }
        }
        for malformedGeneric in ["generic:", "generic:\u{202E}bad", "generic:bad\u{200B}"] {
            #expect(throws: LegacyMigrationError.malformedIdentifier) {
                _ = try LegacyAgentMigrationCatalog(stableIdentifiers: [malformedGeneric])
            }
        }
        #expect(throws: LegacyMigrationError.duplicateOriginalIdentifier) {
            _ = try LegacyAgentMigrationCatalog(stableIdentifiers: ["codex", "codex"])
        }
        #expect(throws: LegacyMigrationError.canonicalCollision) {
            let duplicate = try AgentID(validating: "generic:duplicate")
            try LegacyAgentMigrationCatalog.validateCanonicalUniqueness([duplicate, duplicate])
        }
    }

    @Test func profilesValidateDependencies() throws {
        let profile = try fixtureProfile()
        #expect(profile.deterministicWireValues == profile.deterministicWireValues.sorted())
        #expect(throws: AdapterProfileError.missingDependency) {
            _ = try fixtureProfile(signals: [.init(scope: .item, phase: .started)])
        }
        #expect(throws: AdapterProfileError.replayRequiresOrdering) {
            _ = try fixtureProfile(replay: .sourceCursor, ordering: .unordered)
        }
        #expect(throws: AdapterProfileError.transportAuthenticationMismatch) {
            _ = try AdapterCapabilityProfile(
                transport: .ownedStandardIO,
                lifecycle: AdapterLifecycleCapabilities(
                    signals: [.init(scope: .session, phase: .started)], evidence: []
                ),
                delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .authenticatedPeer)
            )
        }
        #expect(throws: AdapterProfileError.missingDependency) {
            _ = try fixtureProfile(evidence: [.fileChange])
        }
    }

    @Test func piAndCodexLifecyclePairsDoNotCross() async throws {
        let pi = try await fixtureContract(profile: fixtureProfile(signals: [
            .init(scope: .run, phase: .succeeded), .init(scope: .session, phase: .settled)
        ]))
        let codex = try await fixtureContract(profile: fixtureProfile(signals: [
            .init(scope: .session, phase: .started), .init(scope: .turn, phase: .succeeded),
            .init(scope: .item, phase: .started)
        ]))
        for (contract, accepted, rejected) in [
            (pi, (AdapterLifecycleScope.run, AdapterLifecyclePhase.succeeded),
             (AdapterLifecycleScope.session, AdapterLifecyclePhase.succeeded)),
            (pi, (.session, .settled), (.run, .settled)),
            (codex, (.turn, .succeeded), (.session, .succeeded)),
            (codex, (.item, .started), (.item, .succeeded))
        ] {
            let valid = try CandidateLifecycleEvent(scope: accepted.0, phase: accepted.1, reference: nil)
            try AdapterCandidateEvent.lifecycle(valid).validate(against: contract)
            let invalid = try CandidateLifecycleEvent(scope: rejected.0, phase: rejected.1, reference: nil)
            #expect(throws: AdapterCandidateError.capabilityOverreach) {
                try AdapterCandidateEvent.lifecycle(invalid).validate(against: contract)
            }
        }
    }

    @Test func candidatesAreCapabilityBound() async throws {
        let contract = try await fixtureContract(profile: fixtureProfile(signals: [
            .init(scope: .session, phase: .started),
            .init(scope: .turn, phase: .waitingForQuestion)
        ]))
        let question = try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForQuestion,
            request: VendorReference(role: .request, value: "r1"),
            context: VendorReference(role: .turn, value: "turn-1")
        )
        try AdapterCandidateEvent.question(question).validate(against: contract)
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            let approval = try CandidateAttentionEvent(
                scope: .turn, phase: .waitingForApproval,
                request: VendorReference(role: .request, value: "r2")
            )
            try AdapterCandidateEvent.approval(approval).validate(against: contract)
        }
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            let tool = try CandidateToolEvent(
                phase: .started, category: .read,
                toolCall: VendorReference(role: .toolCall, value: "t1"), fileChanges: []
            )
            try AdapterCandidateEvent.tool(tool).validate(against: contract)
        }
        try AdapterCandidateEvent.processExited(status: 0).validate(against: contract)
        let completed = try CandidateLifecycleEvent(scope: .turn, phase: .succeeded, reference: nil)
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.lifecycle(completed).validate(against: contract)
        }
    }

    @Test func attentionRequiresExactScopePhaseAndRoles() async throws {
        let contract = try await fixtureContract(profile: fixtureProfile(signals: [
            .init(scope: .session, phase: .waitingForQuestion),
            .init(scope: .turn, phase: .waitingForQuestion),
            .init(scope: .turn, phase: .waitingForApproval)
        ]))
        let request = try VendorReference(role: .request, value: "request")
        let turn = try VendorReference(role: .turn, value: "turn")
        let validQuestion = try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForQuestion, request: request, context: turn
        )
        try AdapterCandidateEvent.question(validQuestion).validate(against: contract)
        let wrongScope = try CandidateAttentionEvent(scope: .item, phase: .waitingForQuestion, request: request)
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.question(wrongScope).validate(against: contract)
        }
        let approval = try CandidateAttentionEvent(scope: .turn, phase: .waitingForApproval, request: request)
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.question(approval).validate(against: contract)
        }
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.approval(validQuestion).validate(against: contract)
        }
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            _ = try CandidateAttentionEvent(
                scope: .turn, phase: .waitingForQuestion, request: request,
                context: VendorReference(role: .conversation, value: "wrong-context")
            )
        }
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            _ = try CandidateAttentionEvent(
                scope: .turn, phase: .started,
                request: request
            )
        }
        for phase in [AdapterLifecyclePhase.waitingForQuestion, .waitingForApproval] {
            #expect(throws: AdapterCandidateError.contradictoryEvent) {
                _ = try CandidateLifecycleEvent(scope: .turn, phase: phase, reference: turn)
            }
        }
    }

    @Test func candidateValuesAreBounded() throws {
        for path in ["", ".", "..", "/tmp/x", "a//b", "a/./b", "a/../b", "a\0b"] {
            #expect(throws: AdapterCandidateError.invalidRelativePath) {
                _ = try CandidateFileChange(operation: .modify, relativePath: path)
            }
        }
        for path in ["safe/evil\u{202E}txt", "safe/zero\u{200B}width"] {
            #expect(throws: AdapterCandidateError.invalidRelativePath) {
                _ = try CandidateFileChange(operation: .modify, relativePath: path)
            }
        }
        let hash = String(repeating: "a", count: 64)
        let identity = try ClaimedContentIdentity(sha256: hash, byteCount: 42)
        #expect(identity.byteCount == 42)
        #expect(throws: AdapterCandidateError.invalidContentIdentity) {
            _ = try ClaimedContentIdentity(sha256: "sha256:\(hash)", byteCount: 1)
        }
        #expect(throws: AdapterCandidateError.invalidContentIdentity) {
            _ = try ClaimedContentIdentity(sha256: hash, byteCount: 1_099_511_627_777)
        }
        let reference = try VendorReference(role: .event, value: "secret-value")
        #expect(reference.description == "<redacted:event>")
        #expect(reference.rawValue == "secret-value")
        let resume = try AdapterResumePosition("opaque-cursor")
        #expect(resume.description == "<redacted:resume-position>")
        #expect(resume.rawValue == "opaque-cursor")
        #expect(throws: AdapterValueError.self) {
            _ = try AdapterResumePosition(String(repeating: "x", count: 257))
        }
        #expect(try DetectedVendorVersion("1.2.3").value == "1.2.3")
        #expect(throws: AdapterValueError.self) {
            _ = try VendorReference(role: .event, value: String(repeating: "x", count: 257))
        }
        for hostile in [" 1.2.3", "1.2.3 ", "1\u{202E}.2", "1\u{200B}.2"] {
            #expect(throws: AdapterValueError.self) { _ = try DetectedVendorVersion(hostile) }
        }
        #expect(try DetectedVendorVersion("e\u{301}").value == "é")
    }

    @Test func fileChangeBatchesAreCoherent() async throws {
        let call = try VendorReference(role: .toolCall, value: "call")
        let change = try CandidateFileChange(operation: .modify, relativePath: "Sources/File.swift")
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            _ = try CandidateToolEvent(phase: .succeeded, category: .fileChange, toolCall: call, fileChanges: [])
        }
        let alias = try CandidateFileChange(operation: .modify, relativePath: "sources/file.swift")
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            _ = try CandidateToolEvent(
                phase: .succeeded, category: .fileChange, toolCall: call, fileChanges: [change, alias]
            )
        }
        for path in ["Sources/Fíle.swift", "Sources/Ｆile.swift"] {
            let first = try CandidateFileChange(operation: .modify, relativePath: "Sources/File.swift")
            let folded = try CandidateFileChange(operation: .modify, relativePath: path)
            #expect(throws: AdapterCandidateError.contradictoryEvent) {
                _ = try CandidateToolEvent(
                    phase: .succeeded, category: .fileChange,
                    toolCall: call, fileChanges: [first, folded]
                )
            }
        }
        let rename = try CandidateFileChange(
            operation: .rename, relativePath: "old.swift", destinationRelativePath: "OLD.swift"
        )
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            _ = try CandidateToolEvent(
                phase: .succeeded, category: .fileChange, toolCall: call, fileChanges: [rename]
            )
        }
        for pair in [
            ("dir", "dir/file"), ("dir/file", "dir"),
            ("Dir", "dir/file"), ("dír", "dir/file"), ("dir", "DÍR/file"), ("ｄｉｒ", "dir/file")
        ] {
            let first = try CandidateFileChange(operation: .modify, relativePath: pair.0)
            let second = try CandidateFileChange(operation: .modify, relativePath: pair.1)
            #expect(throws: AdapterCandidateError.contradictoryEvent) {
                _ = try CandidateToolEvent(
                    phase: .succeeded, category: .fileChange, toolCall: call,
                    fileChanges: [first, second]
                )
            }
        }
        let tool = try CandidateToolEvent(
            phase: .succeeded, category: .read, toolCall: call, fileChanges: [change]
        )
        let toolOnly = try await fixtureContract(profile: fixtureProfile(evidence: [.tool]))
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.tool(tool).validate(against: toolOnly)
        }
        let categoryEvent = try CandidateToolEvent(
            phase: .succeeded, category: .fileChange, toolCall: call, fileChanges: [change]
        )
        #expect(throws: AdapterCandidateError.capabilityOverreach) {
            try AdapterCandidateEvent.tool(categoryEvent).validate(against: toolOnly)
        }
        let both = try await fixtureContract(profile: fixtureProfile(evidence: [.tool, .fileChange]))
        try AdapterCandidateEvent.tool(tool).validate(against: both)
    }

    @Test func sourcePositionFollowsProfile() async throws {
        let ordered = try await fixtureContract(profile: fixtureProfile())
        let sequence = try AdapterSourcePosition(sourceSequence: 1)
        try AdapterCandidate(event: .processExited(status: nil), sourcePosition: sequence).validate(against: ordered)
        #expect(throws: AdapterCandidateError.missingSourceSequence) {
            try AdapterCandidate(event: .processExited(status: nil)).validate(against: ordered)
        }
        let replay = try await fixtureContract(profile: fixtureProfile(replay: .sourceCursor))
        #expect(throws: AdapterCandidateError.incompleteReplayPosition) {
            try AdapterCandidate(event: .processExited(status: nil), sourcePosition: sequence).validate(against: replay)
        }
        for incomplete in [
            try AdapterSourcePosition(resumePosition: AdapterResumePosition("cursor-1"), sourceSequence: 1),
            try AdapterSourcePosition(
                sourceEvent: VendorReference(role: .event, value: "event-1"), sourceSequence: 1
            ),
            try AdapterSourcePosition(
                sourceEvent: VendorReference(role: .event, value: "event-1"),
                resumePosition: AdapterResumePosition("cursor-1")
            )
        ] {
            #expect(throws: AdapterCandidateError.incompleteReplayPosition) {
                try AdapterCandidate(event: .processExited(status: nil), sourcePosition: incomplete)
                    .validate(against: replay)
            }
        }
        let cursor = try AdapterSourcePosition(
            sourceEvent: VendorReference(role: .event, value: "event-1"),
            resumePosition: AdapterResumePosition("cursor-1"), sourceSequence: 1
        )
        try AdapterCandidate(event: .processExited(status: nil), sourcePosition: cursor).validate(against: replay)
        #expect(throws: AdapterCandidateError.forbiddenReplayPosition) {
            try AdapterCandidate(event: .processExited(status: nil), sourcePosition: cursor).validate(against: ordered)
        }
        #expect(throws: AdapterCandidateError.invalidSourcePosition) {
            _ = try AdapterSourcePosition(sourceEvent: VendorReference(role: .request, value: "wrong"))
        }
        #expect(throws: AdapterCandidateError.invalidSourcePosition) {
            _ = try AdapterSourcePosition(sourceSequence: 0)
        }
        let unordered = try await fixtureContract(profile: fixtureProfile(ordering: .unordered))
        #expect(throws: AdapterCandidateError.forbiddenSourceSequence) {
            try AdapterCandidate(event: .processExited(status: nil), sourcePosition: sequence)
                .validate(against: unordered)
        }
    }

    @Test func opaqueValuesRedactAllDiagnostics() throws {
        let reference = try VendorReference(role: .event, value: "reference-canary")
        let resume = try AdapterResumePosition("resume-canary")
        let nested = try AdapterSourcePosition(
            sourceEvent: reference, resumePosition: resume, sourceSequence: 1
        )
        for output in [
            String(reflecting: reference), dumped(reference), String(reflecting: resume), dumped(resume),
            String(reflecting: nested), dumped(nested)
        ] {
            #expect(!output.contains("reference-canary"))
            #expect(!output.contains("resume-canary"))
        }
    }

    @Test func probeResultsAreConstructivelyBounded() throws {
        let version = try DetectedVendorVersion("1.0")
        let profile = try fixtureProfile()
        _ = try AdapterProbeResult(
            detectedVendorVersion: version,
            detectedSchema: nil,
            offeredProfiles: [profile],
            offeredContractVersions: PineAdapterContractVersionRange(
                minimum: PineAdapterContractVersion(major: 1, minor: 0),
                maximum: PineAdapterContractVersion(major: 1, minor: 1)
            )
        )
        #expect(throws: AdapterProbeError.malformedResponse) {
            _ = try AdapterProbeResult(
                detectedVendorVersion: version,
                detectedSchema: nil,
                offeredProfiles: [profile, profile],
                offeredContractVersions: PineAdapterContractVersionRange(
                    minimum: PineAdapterContractVersion(major: 1, minor: 0),
                    maximum: PineAdapterContractVersion(major: 1, minor: 1)
                )
            )
        }
        #expect(throws: AdapterProbeError.malformedResponse) {
            _ = try AdapterProbeResult(
                detectedVendorVersion: version, detectedSchema: nil,
                offeredProfiles: Array(repeating: profile, count: 17),
                offeredContractVersions: PineAdapterContractVersionRange(
                    minimum: PineAdapterContractVersion(major: 1, minor: 0),
                    maximum: PineAdapterContractVersion(major: 1, minor: 1)
                )
            )
        }
        #expect(throws: AdapterProbeError.malformedResponse) {
            _ = try AdapterProbeResult(
                detectedVendorVersion: version,
                detectedSchema: nil,
                offeredProfiles: [profile],
                offeredContractVersions: PineAdapterContractVersionRange(
                    minimum: PineAdapterContractVersion(major: 2, minor: 0),
                    maximum: PineAdapterContractVersion(major: 1, minor: 0)
                )
            )
        }
    }

    @Test func candidatesHaveNoAuthorityContext() throws {
        let source = try AdapterSourcePosition(
            sourceEvent: VendorReference(role: .event, value: "event"),
            resumePosition: AdapterResumePosition("cursor"), sourceSequence: 1
        )
        let timestamp = try TimestampHint(secondsSince1970: 1, durationMilliseconds: 2)
        let lifecycle = try CandidateLifecycleEvent(
            scope: .turn, phase: .working, reference: VendorReference(role: .turn, value: "turn")
        )
        let attention = try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForQuestion,
            request: VendorReference(role: .request, value: "request"),
            context: VendorReference(role: .turn, value: "turn")
        )
        let identity = try ClaimedContentIdentity(sha256: String(repeating: "a", count: 64), byteCount: 1)
        let change = try CandidateFileChange(
            operation: .rename, relativePath: "old.swift", destinationRelativePath: "new.swift",
            before: identity, after: identity
        )
        let tool = try CandidateToolEvent(
            phase: .succeeded, category: .fileChange,
            toolCall: VendorReference(role: .toolCall, value: "tool"), fileChanges: [change]
        )
        let candidates = [
            AdapterCandidate(event: .lifecycle(lifecycle), timestampHint: timestamp, sourcePosition: source),
            AdapterCandidate(event: .question(attention), timestampHint: timestamp, sourcePosition: source),
            AdapterCandidate(event: .approval(try CandidateAttentionEvent(
                scope: .turn, phase: .waitingForApproval,
                request: VendorReference(role: .request, value: "approval"), context: attention.context
            )), timestampHint: timestamp, sourcePosition: source),
            AdapterCandidate(event: .tool(tool), timestampHint: timestamp, sourcePosition: source),
            AdapterCandidate(event: .processExited(status: 1), timestampHint: timestamp, sourcePosition: source)
        ]
        for candidate in candidates { assertNoForbiddenAuthority(candidate) }
    }

    private func fixtureProfile(
        signals: Set<AdapterLifecycleCapabilities.Signal> = [
            .init(scope: .session, phase: .settled), .init(scope: .turn, phase: .started)
        ],
        evidence: Set<AdapterEvidence> = [],
        replay: AdapterReplay = .none,
        ordering: AdapterOrdering = .ordered
    ) throws -> AdapterCapabilityProfile {
        try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: signals, evidence: evidence),
            delivery: AdapterDeliverySemantics(
                replay: replay, ordering: ordering, minimumAuthentication: .ownedChildPipe
            )
        )
    }

    private func fixtureContract(profile: AdapterCapabilityProfile) async throws -> NegotiatedAdapterContract {
        let agentID = try AgentID(validating: "codex")
        let adapterID = try AdapterID(validating: "pine:codex")
        let factoryID = try AdapterFactoryID(validating: "pine.codex.factory")
        let presentation = try AgentPresentationDescriptor(
            agentID: agentID, displayName: "Codex",
            executableAliases: [ExecutableAlias(validating: "codex")], style: .codex
        )
        let version = PineAdapterContractVersion(major: 1, minor: 0)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let probeResult = try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion("test-vendor-1.0"),
            detectedSchema: nil,
            offeredProfiles: [profile],
            offeredContractVersions: versions
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(AdapterDescriptor(
                adapterID: adapterID, agentID: agentID, factoryID: factoryID,
                contractVersions: versions,
                maximumProfiles: [profile]
            ), ContractTestFactory(id: factoryID, probeResult: probeResult))]
        )
        let offer = try await registry.probe(adapterID: adapterID)
        return try registry.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: versions,
                transportPreference: [profile.transport], acceptedAuthentication: [profile.minimumAuthentication]
            )
        )
    }

    private func dumped<T>(_ value: T) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }

    private func assertNoForbiddenAuthority(_ value: Any) {
        let forbidden = [
            "credential", "authenticationcontext", "task", "project", "worktree", "pane", "tab", "terminal",
            "pid", "processgeneration", "route", "trust", "provenance", "command", "args", "environment",
            "env", "output", "transcript", "filecontent", "contents"
        ]
        func inspect(_ value: Any) {
            let mirror = Mirror(reflecting: value)
            let typeName = String(reflecting: type(of: value)).lowercased()
            let forbiddenTypes = [
                "credential", "authenticationcontext", "taskid", "projectid", "worktreeid", "paneid", "tabid",
                "terminal", "processgeneration", "routeauthority", "trustauthority", "provenanceauthority",
                "pid", "command", "arguments", "environment", "output", "transcript", "filecontents"
            ]
            #expect(!forbiddenTypes.contains { typeName.contains($0) })
            for child in mirror.children {
                let label = (child.label ?? "").lowercased()
                if label == "$defaultactor" { continue }
                #expect(!forbidden.contains { label.contains($0) })
                inspect(child.value)
            }
        }
        inspect(value)
    }
}
