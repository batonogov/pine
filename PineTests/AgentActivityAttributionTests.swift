//
//  AgentActivityAttributionTests.swift
//  PineTests
//
//  Fail-closed model and presentation tests for multi-agent Activity
//  attribution (epic #933).
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Activity Attribution")
@MainActor
struct AgentActivityAttributionTests {
    private let sessionA = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let sessionB = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

    @Test("Legacy session link exposes one unambiguous candidate")
    func legacySessionAssociation() {
        let candidate = AgentActionCandidate(
            sessionID: sessionA,
            agentType: .claudeCode
        )
        let attribution = AgentActionAttribution.session(candidate)

        #expect(attribution.candidates == [candidate])
        #expect(attribution.unambiguousCandidate == candidate)
        #expect(attribution.contains(sessionID: sessionA))
        #expect(!attribution.contains(sessionID: sessionB))
    }

    @Test("Inferred session remains distinguishable from a legacy session link")
    func inferredSessionAssociation() {
        let candidate = AgentActionCandidate(
            sessionID: sessionA,
            agentType: .codex
        )

        #expect(
            AgentActionAttribution.inferred(candidate)
                != .session(candidate)
        )
        #expect(
            AgentActionAttribution.inferred(candidate).unambiguousCandidate
                == candidate
        )
    }

    @Test("Ambiguous association exposes candidates but selects no owner")
    func ambiguousAssociationHasNoOwner() {
        let first = AgentActionCandidate(
            sessionID: sessionA,
            agentType: .claudeCode
        )
        let second = AgentActionCandidate(
            sessionID: sessionB,
            agentType: .codex
        )
        let attribution = AgentActionAttribution.ambiguous(
            candidates: [first, second]
        )

        #expect(attribution.candidates == [first, second])
        #expect(attribution.unambiguousCandidate == nil)
        #expect(attribution.contains(sessionID: sessionA))
        #expect(attribution.contains(sessionID: sessionB))
    }

    @Test("Legacy action accessors fail closed for ambiguous candidates")
    func ambiguousActionAccessors() {
        let action = AgentAction(
            attribution: .ambiguous(candidates: [
                AgentActionCandidate(sessionID: sessionA, agentType: .claudeCode),
                AgentActionCandidate(sessionID: sessionB, agentType: .codex)
            ]),
            kind: .fileWrite,
            summary: "File changed: a.swift"
        )

        #expect(action.sessionID == nil)
        #expect(action.agentType == nil)
        #expect(AgentActivityRow(action).attribution == action.attribution)
    }

    @Test("Session-linked presentation explicitly avoids a verified trust claim")
    func sessionLinkedPresentation() {
        let presentation = AgentActionAttribution.session(
            AgentActionCandidate(sessionID: sessionA, agentType: .claudeCode)
        ).activityPresentation

        #expect(
            presentation.badgeLabel
                == Strings.agentActivityAttributionSessionLinked
        )
        #expect(presentation.detail == AgentType.claudeCode.displayName)
        #expect(
            presentation.accessibilityHint
                == Strings.agentActivitySessionLinkedHint
        )
        #expect(presentation.markerAgentType == .claudeCode)
        #expect(!presentation.isAmbiguous)
        #expect(
            presentation.accessibilityValue.contains(
                Strings.agentActivityAttributionSessionLinked
            )
        )
    }

    @Test("Inferred presentation identifies the heuristic without hiding the candidate")
    func inferredPresentation() {
        let presentation = AgentActionAttribution.inferred(
            AgentActionCandidate(sessionID: sessionA, agentType: .codex)
        ).activityPresentation

        #expect(presentation.badgeLabel == Strings.agentActivityAttributionInferred)
        #expect(presentation.detail == AgentType.codex.displayName)
        #expect(presentation.accessibilityHint == Strings.agentActivityInferredHint)
        #expect(presentation.markerAgentType == .codex)
        #expect(!presentation.isAmbiguous)
        #expect(
            presentation.accessibilityValue.contains(
                Strings.agentActivityAttributionInferred
            )
        )
    }

    @Test("Ambiguous presentation is neutral and announces candidate count")
    func ambiguousPresentation() {
        let presentation = AgentActionAttribution.ambiguous(candidates: [
            AgentActionCandidate(sessionID: sessionA, agentType: .claudeCode),
            AgentActionCandidate(sessionID: sessionB, agentType: .codex)
        ]).activityPresentation

        #expect(presentation.badgeLabel == Strings.agentActivityAttributionAmbiguous)
        #expect(presentation.detail == Strings.agentActivityPossibleSessions(2))
        #expect(presentation.accessibilityHint == Strings.agentActivityAmbiguousHint)
        #expect(presentation.markerAgentType == nil)
        #expect(presentation.isAmbiguous)
        #expect(
            presentation.accessibilityValue.contains(
                Strings.agentActivityAttributionAmbiguous
            )
        )
    }

    @Test("Localized file observation preserves an arbitrary file name")
    func localizedFileObservation() {
        let fileName = "100% 日本語.swift"
        let summary = Strings.agentActivityFileChanged(fileName)

        #expect(summary.contains(fileName))
        #expect(Strings.agentActivityPossibleSessions(37).contains("37"))
    }
}
