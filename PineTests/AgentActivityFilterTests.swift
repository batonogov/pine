//
//  AgentActivityFilterTests.swift
//  PineTests
//
//  Attribution-evidence and conjunctive filtering tests for the Agent
//  Activity Panel (epic #933).
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Activity Filters")
@MainActor
struct AgentActivityFilterTests {
    private let sessionA = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )
    private let sessionB = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
    )

    private var sessionCandidate: AgentActionCandidate {
        AgentActionCandidate(sessionID: sessionA, agentType: .claudeCode)
    }

    private var otherCandidate: AgentActionCandidate {
        AgentActionCandidate(sessionID: sessionB, agentType: .codex)
    }

    private var attributions: [AgentActionAttribution] {
        [
            .session(sessionCandidate),
            .inferred(sessionCandidate),
            .ambiguous(candidates: [sessionCandidate, otherCandidate])
        ]
    }

    @Test("Evidence categories have a stable, non-authoritative order")
    func categoryOrder() {
        #expect(
            ActivityAttributionFilter.allCases
                == [.sessionLinked, .inferred, .ambiguous]
        )
    }

    @Test(
        "Each evidence category matches exactly its corresponding attribution",
        arguments: ActivityAttributionFilter.allCases
    )
    func categoryMatchesExactly(_ category: ActivityAttributionFilter) {
        let matchedIndices = attributions.indices.filter {
            category.matches(attributions[$0])
        }

        switch category {
        case .sessionLinked:
            #expect(matchedIndices == [0])
        case .inferred:
            #expect(matchedIndices == [1])
        case .ambiguous:
            #expect(matchedIndices == [2])
        }
    }

    @Test("Only represented evidence categories are offered")
    func availableCategories() {
        let available = ActivityAttributionFilter.available(
            in: [
                .ambiguous(candidates: [sessionCandidate, otherCandidate]),
                .inferred(sessionCandidate),
                .inferred(sessionCandidate)
            ]
        )

        #expect(available == [.inferred, .ambiguous])
        #expect(ActivityAttributionFilter.available(in: []).isEmpty)
    }

    @Test("A selected category remains available after its rows disappear")
    func selectedCategoryRemainsClearable() {
        let available = ActivityAttributionFilter.available(
            in: [.inferred(sessionCandidate)],
            retaining: .sessionLinked
        )

        #expect(available == [.sessionLinked, .inferred])
    }

    @Test("An empty filter accepts every evidence, kind, and status")
    func emptyFilterMatchesEverything() {
        let filter = AgentActivityFilter()

        #expect(!filter.isActive)
        for attribution in attributions {
            #expect(
                filter.matches(
                    kind: .toolCall,
                    status: .failed,
                    attribution: attribution
                )
            )
        }
    }

    @Test("Kind, status, and evidence conditions are conjunctive")
    func dimensionsAreConjunctive() {
        let filter = AgentActivityFilter(
            kind: .fileWrite,
            status: .completed,
            attribution: .inferred
        )

        #expect(filter.isActive)
        #expect(
            filter.matches(
                kind: .fileWrite,
                status: .completed,
                attribution: .inferred(sessionCandidate)
            )
        )
        #expect(
            !filter.matches(
                kind: .command,
                status: .completed,
                attribution: .inferred(sessionCandidate)
            )
        )
        #expect(
            !filter.matches(
                kind: .fileWrite,
                status: .failed,
                attribution: .inferred(sessionCandidate)
            )
        )
        #expect(
            !filter.matches(
                kind: .fileWrite,
                status: .completed,
                attribution: .session(sessionCandidate)
            )
        )
    }

    @Test("Store queries and row projections use identical semantics")
    func storeAndRowsStayInSync() {
        let store = AgentActivityStore()
        let actions = [
            AgentAction(
                attribution: .session(sessionCandidate),
                kind: .fileWrite,
                status: .completed,
                summary: "session"
            ),
            AgentAction(
                attribution: .inferred(sessionCandidate),
                kind: .fileWrite,
                status: .completed,
                summary: "inferred"
            ),
            AgentAction(
                attribution: .ambiguous(
                    candidates: [sessionCandidate, otherCandidate]
                ),
                kind: .fileWrite,
                status: .failed,
                summary: "ambiguous"
            )
        ]
        actions.forEach(store.record)
        let filter = AgentActivityFilter(
            kind: .fileWrite,
            status: .completed,
            attribution: .inferred
        )

        let storedIDs = store.filtered(using: filter).map(\.id)
        let rowIDs = actions.map(AgentActivityRow.init).filter { row in
            filter.matches(
                kind: row.kind,
                status: row.status,
                attribution: row.attribution
            )
        }
        .map(\.id)

        #expect(storedIDs == rowIDs)
        #expect(storedIDs == [actions[1].id])
    }

    @Test("Every optional filter combination has conjunctive store/UI semantics")
    func allFilterCombinations() {
        let store = AgentActivityStore()
        let kinds = AgentActionKind.allCases
        let statuses = AgentActionStatus.allCases
        let evidence = attributions
        var actions: [AgentAction] = []

        for (evidenceIndex, attribution) in evidence.enumerated() {
            for (kindIndex, kind) in kinds.enumerated() {
                for (statusIndex, status) in statuses.enumerated() {
                    let action = AgentAction(
                        attribution: attribution,
                        kind: kind,
                        status: status,
                        summary: "\(evidenceIndex)-\(kindIndex)-\(statusIndex)"
                    )
                    actions.append(action)
                    store.record(action)
                }
            }
        }

        let optionalKinds: [AgentActionKind?] = [nil] + kinds.map(Optional.some)
        let optionalStatuses: [AgentActionStatus?] =
            [nil] + statuses.map(Optional.some)
        let optionalEvidence: [ActivityAttributionFilter?] =
            [nil] + ActivityAttributionFilter.allCases.map(Optional.some)

        for kind in optionalKinds {
            for status in optionalStatuses {
                for attribution in optionalEvidence {
                    let filter = AgentActivityFilter(
                        kind: kind,
                        status: status,
                        attribution: attribution
                    )
                    let expectedIDs = actions.filter { action in
                        (kind == nil || action.kind == kind)
                            && (status == nil || action.status == status)
                            && (
                                attribution == nil
                                    || attribution?.matches(action.attribution) == true
                            )
                    }
                    .map(\.id)
                    let storeIDs = store.filtered(using: filter).map(\.id)
                    let rowIDs = actions.map(AgentActivityRow.init).filter { row in
                        filter.matches(
                            kind: row.kind,
                            status: row.status,
                            attribution: row.attribution
                        )
                    }
                    .map(\.id)

                    #expect(storeIDs == expectedIDs)
                    #expect(rowIDs == expectedIDs)
                }
            }
        }
    }

    @Test("Dynamic evidence scope retains a selected zero-match category")
    func dynamicEvidenceScopeRetainsSelectedCategory() {
        let actions = [
            AgentAction(
                attribution: .inferred(sessionCandidate),
                kind: .fileWrite,
                status: .completed,
                summary: "inferred"
            ),
            AgentAction(
                attribution: .ambiguous(
                    candidates: [sessionCandidate, otherCandidate]
                ),
                kind: .fileWrite,
                status: .failed,
                summary: "ambiguous"
            )
        ]
        let nonAttributionFilter = AgentActivityFilter(
            kind: .fileWrite,
            status: .failed
        )
        let scopedAttributions = actions.compactMap { action in
            nonAttributionFilter.matches(
                kind: action.kind,
                status: action.status,
                attribution: action.attribution
            ) ? action.attribution : nil
        }

        #expect(
            ActivityAttributionFilter.available(
                in: scopedAttributions,
                retaining: .inferred
            ) == [.inferred, .ambiguous]
        )
    }

    @Test("Localized category labels are distinct and non-empty")
    func categoryLabels() {
        let labels = ActivityAttributionFilter.allCases.map(\.filterLabel)

        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
        #expect(
            ActivityAttributionFilter.sessionLinked.filterLabel
                == Strings.agentActivityAttributionSessionLinked
        )
    }
}
