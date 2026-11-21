import Foundation
import Testing
@testable import Pine

struct AgentProjectPreparationTests {
    private let project = AgentTaskProjectIdentity(
        canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/first"
    )

    private func swiftRecipe() throws -> AgentProjectRecipe {
        try #require(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/democli/main.swift"],
            for: project
        ))
    }

    private func twoStepRecipe() throws -> AgentProjectRecipe {
        let base = try swiftRecipe()
        return AgentProjectRecipe(
            scheme: base.scheme, kind: base.kind, canonicalProjectPath: base.canonicalProjectPath,
            prerequisites: base.prerequisites,
            setup: base.setup + [AgentTaskCheckCommand(
                id: "update", required: true, executable: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["package", "update"], workingDirectory: "", timeout: 600
            )],
            checks: base.checks, results: base.results, secretRequirements: base.secretRequirements
        )
    }

    @Test func usableOnlyWhenEveryActionAndPrerequisiteIsComplete() throws {
        var preparation = AgentProjectPreparation(recipe: try swiftRecipe())
        #expect(!preparation.isUsable)
        #expect(preparation.phase == .preparing)
        preparation = preparation.reduced(by: .setupSucceeded("resolve"))
        #expect(preparation.phase == .preparing) // prerequisite still unresolved
        preparation = preparation.reduced(by: .prerequisiteResolved("swift"))
        #expect(preparation.isUsable)
        #expect(preparation.isCurrentFor(preparation.recipeFingerprint))
    }

    @Test func partialSetupNeverAppearsUsable() throws {
        var preparation = AgentProjectPreparation(recipe: try twoStepRecipe())
        preparation = preparation.reduced(by: .prerequisiteResolved("swift"))
        preparation = preparation.reduced(by: .setupSucceeded("resolve"))
        #expect(preparation.phase == .preparing) // "update" still incomplete
        preparation = preparation.reduced(by: .setupSucceeded("update"))
        #expect(preparation.isUsable)
    }

    @Test func failureIsExplainedAndRetriesAreBounded() throws {
        var preparation = AgentProjectPreparation(recipe: try twoStepRecipe())
        preparation = preparation.reduced(by: .prerequisiteResolved("swift"))
        preparation = preparation.reduced(by: .setupSucceeded("resolve"))
        preparation = preparation.reduced(by: .setupFailed("update"))
        #expect(preparation.phase == .failed)
        #expect(preparation.reason == .setupActionFailed("update"))

        for _ in 0..<AgentProjectPreparation.maximumRetries {
            preparation = preparation.reduced(by: .retryRequested)
            #expect(preparation.phase == .preparing)
            #expect(preparation.reason == nil)
            #expect(preparation.completedActions.contains("resolve")) // resume at first failure
            preparation = preparation.reduced(by: .setupFailed("update"))
            #expect(preparation.phase == .failed)
        }
        preparation = preparation.reduced(by: .retryRequested)
        #expect(preparation.phase == .failed)
        #expect(preparation.reason == .retryBudgetExhausted)
        preparation = preparation.reduced(by: .retryRequested)
        #expect(preparation.reason == .retryBudgetExhausted) // stays exhausted
        #expect(preparation.completedActions.contains("resolve"))
    }

    @Test func unavailablePrerequisiteIsExplainedAndNotRetried() throws {
        var preparation = AgentProjectPreparation(recipe: try swiftRecipe())
        preparation = preparation.reduced(by: .prerequisiteUnavailable("swift"))
        #expect(preparation.phase == .unavailable)
        #expect(preparation.reason == .missingPrerequisite("swift"))
        #expect(preparation.reduced(by: .retryRequested).phase == .unavailable)
        #expect(preparation.reduced(by: .cancelled).phase == .cancelled)
        #expect(!preparation.isCurrentFor(preparation.recipeFingerprint))
    }

    @Test func recipeChangeInvalidatesPreparedState() throws {
        let first = try swiftRecipe()
        let changed = try #require(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/othercli/main.swift"],
            for: project
        ))
        #expect(changed.fingerprint != first.fingerprint)

        var preparation = AgentProjectPreparation(recipe: first)
        preparation = preparation.reduced(by: .prerequisiteResolved("swift"))
        preparation = preparation.reduced(by: .setupSucceeded("resolve"))
        #expect(preparation.isUsable)
        #expect(!preparation.isCurrentFor(changed.fingerprint))
    }

    @Test func unknownIDsAndOutOfPhaseEventsAreNoOps() throws {
        let preparation = AgentProjectPreparation(recipe: try swiftRecipe())
        #expect(preparation.reduced(by: .setupSucceeded("bogus")) == preparation)
        #expect(preparation.reduced(by: .prerequisiteResolved("bogus")) == preparation)
        #expect(preparation.reduced(by: .retryRequested) == preparation)
        #expect(preparation.reduced(by: .setupFailed("bogus")) == preparation)

        var usable = preparation
        usable = usable.reduced(by: .prerequisiteResolved("swift"))
        usable = usable.reduced(by: .setupSucceeded("resolve"))
        #expect(usable.phase == .usable)
        #expect(usable.reduced(by: .setupFailed("resolve")) == usable)
        #expect(usable.reduced(by: .cancelled) == usable)
    }
}
