import Foundation
import Testing
@testable import Pine

struct AgentProjectRecipeTests {
    private let project = AgentTaskProjectIdentity(
        canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/first"
    )

    private static let swiftPackageFiles: Set<String> = [
        "Package.swift",
        "Package.resolved",
        "Sources/democli/main.swift",
        "Sources/democli/Support.swift",
        "Tests/democliTests/DemoCLITests.swift",
    ]

    private func proposed(
        files: Set<String> = AgentProjectRecipeTests.swiftPackageFiles
    ) throws -> AgentProjectRecipe {
        try #require(AgentProjectRecipe.propose(recognizedFiles: files, for: project))
    }

    /// Rebuilds a recipe with different result-command arguments so each
    /// selection tier carries distinguishable content.
    private func variant(_ base: AgentProjectRecipe, resultArguments: [String]) -> AgentProjectRecipe {
        let result = base.results[0]
        return AgentProjectRecipe(
            scheme: base.scheme, kind: base.kind, canonicalProjectPath: base.canonicalProjectPath,
            prerequisites: base.prerequisites, setup: base.setup, checks: base.checks,
            results: [AgentProjectResultAction(
                id: result.id, output: result.output,
                command: AgentTaskCheckCommand(
                    id: result.command.id, required: true, executable: result.command.executable,
                    arguments: resultArguments, workingDirectory: "", timeout: result.command.timeout
                )
            )],
            secretRequirements: base.secretRequirements
        )
    }

    @Test func proposedRecipeIsCompleteAndSelectable() throws {
        let recipe = try proposed()
        #expect(recipe.isValid)
        #expect(recipe.kind == .swiftPackage)
        #expect(recipe.prerequisites.map(\.name) == ["swift"])
        #expect(recipe.setup.map(\.id) == ["resolve"])
        let setupAllRequired = recipe.setup.allSatisfy(\.required)
        #expect(setupAllRequired)
        #expect(recipe.checks.commands.map(\.id) == ["build", "test"])
        #expect(recipe.checks.commands.first?.required == true)
        #expect(recipe.checks.commands.last?.required == false)
        #expect(recipe.checks.capturePolicy.declaredOutputs == [".build"])
        #expect(recipe.results.map(\.id) == ["run-example"])
        #expect(recipe.results.first?.output == .cli)
        #expect(recipe.secretRequirements.isEmpty)

        let selected = try AgentProjectRecipe.select(projectCheckedIn: recipe, for: project)
        #expect(selected.origin == .projectCheckedIn)
        #expect(selected.recipe == recipe)
        #expect(selected.plan.isValid)
        #expect(selected.plan.commands == recipe.checks.commands)
        #expect(selected.plan.recipeFingerprint == recipe.checks.fingerprint)
    }

    @Test func recognitionFailsClosedForUnsupportedOrAmbiguousTrees() {
        #expect(AgentProjectRecipe.propose(recognizedFiles: [], for: project) == nil)
        #expect(AgentProjectRecipe.propose(recognizedFiles: ["main.swift"], for: project) == nil)
        #expect(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/mylib/Lib.swift"], for: project
        ) == nil)
        #expect(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/mycli/nested/main.swift"], for: project
        ) == nil)
        var ambiguous = Self.swiftPackageFiles
        ambiguous.insert("Sources/othercli/main.swift")
        #expect(AgentProjectRecipe.propose(recognizedFiles: ambiguous, for: project) == nil)
    }

    @Test func selectionPrecedenceIsLocalThenAgentThenCheckedIn() throws {
        let checkedIn = try proposed()
        let agent = variant(checkedIn, resultArguments: ["run", "democli", "--agent"])
        let local = variant(checkedIn, resultArguments: ["run", "democli", "--local"])

        let byLocal = try AgentProjectRecipe.select(
            projectCheckedIn: checkedIn, agentProposed: agent, localSelection: local, for: project
        )
        #expect(byLocal.origin == .localSelection)
        #expect(byLocal.recipe == local)

        let byAgent = try AgentProjectRecipe.select(
            projectCheckedIn: checkedIn, agentProposed: agent, for: project
        )
        #expect(byAgent.origin == .agentProposed)
        #expect(byAgent.recipe == agent)

        let byCheckedIn = try AgentProjectRecipe.select(projectCheckedIn: checkedIn, for: project)
        #expect(byCheckedIn.origin == .projectCheckedIn)
        #expect(byCheckedIn.recipe == checkedIn)
    }

    @Test func invalidChosenRecipeNeverFallsBackToAnotherTier() throws {
        let checkedIn = try proposed()
        // Invalid local: a secret reference for a command the recipe does not declare.
        let invalid = AgentProjectRecipe(
            scheme: checkedIn.scheme, kind: checkedIn.kind,
            canonicalProjectPath: checkedIn.canonicalProjectPath,
            prerequisites: checkedIn.prerequisites, setup: checkedIn.setup, checks: checkedIn.checks,
            results: checkedIn.results,
            secretRequirements: ["unknown-command": [AgentProjectSecretReference(name: "DEPLOY_TOKEN")]]
        )
        #expect(!invalid.isValid)
        #expect(throws: AgentProjectRecipe.SelectionError.invalidRecipe) {
            try AgentProjectRecipe.select(
                projectCheckedIn: checkedIn, agentProposed: checkedIn, localSelection: invalid, for: project
            )
        }
        // A setup id colliding with a check id would be ambiguous for secret
        // requirements keyed by command id.
        let colliding = AgentProjectRecipe(
            scheme: checkedIn.scheme, kind: checkedIn.kind,
            canonicalProjectPath: checkedIn.canonicalProjectPath,
            prerequisites: checkedIn.prerequisites,
            setup: checkedIn.setup + [AgentTaskCheckCommand(
                id: "build", required: true, executable: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["x"], workingDirectory: "", timeout: 60
            )],
            checks: checkedIn.checks, results: checkedIn.results, secretRequirements: [:]
        )
        #expect(!colliding.isValid)
        #expect(throws: AgentProjectRecipe.SelectionError.unsupportedScheme) {
            var future = checkedIn
            future = AgentProjectRecipe(
                scheme: 2, kind: future.kind, canonicalProjectPath: future.canonicalProjectPath,
                prerequisites: future.prerequisites, setup: future.setup, checks: future.checks,
                results: future.results, secretRequirements: future.secretRequirements
            )
            _ = try AgentProjectRecipe.select(projectCheckedIn: future, for: project)
        }
        #expect(throws: AgentProjectRecipe.SelectionError.wrongProject) {
            try AgentProjectRecipe.select(
                projectCheckedIn: checkedIn,
                for: AgentTaskProjectIdentity(
                    canonicalProjectPath: "/other", canonicalWorktreePath: "/other/work"
                )
            )
        }
        #expect(throws: AgentProjectRecipe.SelectionError.missingRecipe) {
            try AgentProjectRecipe.select(projectCheckedIn: nil, for: project)
        }
        // The valid tiers remain selectable on their own.
        #expect(try AgentProjectRecipe.select(projectCheckedIn: checkedIn, for: project).recipe == checkedIn)
    }

    @Test func fingerprintIsContentIdentityIndependentOfOriginTier() throws {
        let checkedIn = try proposed()
        let sameContent = variant(checkedIn, resultArguments: checkedIn.results[0].command.arguments)
        #expect(sameContent == checkedIn)
        #expect(sameContent.fingerprint == checkedIn.fingerprint)
        #expect(try AgentProjectRecipe.select(projectCheckedIn: checkedIn, for: project).plan
            == AgentProjectRecipe.select(projectCheckedIn: nil, localSelection: sameContent, for: project).plan)
        #expect(variant(checkedIn, resultArguments: ["run", "other"]).fingerprint != checkedIn.fingerprint)
    }

    @Test func secretReferencesAreNamesNotValues() throws {
        let base = try proposed()
        let withSecret = AgentProjectRecipe(
            scheme: base.scheme, kind: base.kind, canonicalProjectPath: base.canonicalProjectPath,
            prerequisites: base.prerequisites, setup: base.setup, checks: base.checks,
            results: base.results,
            secretRequirements: ["run": [AgentProjectSecretReference(name: "DEPLOY_TOKEN")]]
        )
        #expect(withSecret.isValid)
        #expect(withSecret.fingerprint != base.fingerprint)
        #expect(try AgentProjectRecipe.select(projectCheckedIn: withSecret, for: project).recipe
            .secretRequirements == withSecret.secretRequirements)

        let badReference = AgentProjectRecipe(
            scheme: base.scheme, kind: base.kind, canonicalProjectPath: base.canonicalProjectPath,
            prerequisites: base.prerequisites, setup: base.setup, checks: base.checks,
            results: base.results,
            secretRequirements: ["run": [AgentProjectSecretReference(name: "deploy_token")]]
        )
        #expect(!badReference.isValid)

        let secretish = variant(base, resultArguments: ["run", "democli", "--token", "s3-secret-value"])
        #expect(!String(describing: secretish).contains("s3-secret-value"))
        #expect(!String(reflecting: secretish).contains("s3-secret-value"))
    }

    @Test func secondIsolatedTaskStartsWithoutReconstructingSetupChecksOrResults() throws {
        let origin = try proposed()
        let first = try AgentProjectRecipe.select(projectCheckedIn: origin, for: project)
        let secondProject = AgentTaskProjectIdentity(
            canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/second"
        )
        let second = try AgentProjectRecipe.select(projectCheckedIn: origin, for: secondProject)
        #expect(first.recipe == second.recipe)
        #expect(first.plan == second.plan)
        #expect(first.recipe.setup == second.recipe.setup)
        #expect(first.recipe.results == second.recipe.results)
        #expect(AgentProjectPreparation(recipe: first.recipe)
            == AgentProjectPreparation(recipe: second.recipe))

        // Task-scoped command grants still do not transfer between tasks.
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
            configurationFingerprint: String(repeating: "c", count: 64)
        )
        let grant = AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: UUID(), planFingerprint: first.plan.fingerprint,
            environment: environment, approvedAt: Date(), revokedAt: nil
        )
        #expect(grant.matchesScope(taskID: grant.taskID, plan: second.plan, environment: environment))
        #expect(!grant.matchesScope(taskID: UUID(), plan: second.plan, environment: environment))
    }

    @Test func verticalSliceFlowIsRepeatableAcrossIsolatedTasks() throws {
        // Task 1: propose → select → prepare → usable → observed result.
        let origin = try proposed()
        let selected = try AgentProjectRecipe.select(projectCheckedIn: origin, for: project)
        var preparation = AgentProjectPreparation(recipe: selected.recipe)
        preparation = preparation.reduced(by: .prerequisiteResolved("swift"))
        preparation = preparation.reduced(by: .setupSucceeded("resolve"))
        #expect(preparation.isCurrentFor(selected.recipe.fingerprint))

        let snapshot = AgentVerificationIdentitySnapshot(
            code: AgentTaskCodeStateIdentity(
                headCommit: String(repeating: "a", count: 64),
                trackedFingerprint: String(repeating: "b", count: 64),
                untrackedFingerprint: String(repeating: "c", count: 64),
                ignoredRelevantFingerprint: String(repeating: "d", count: 64)
            ),
            environment: AgentTaskEnvironmentIdentity(
                osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
                configurationFingerprint: String(repeating: "c", count: 64)
            )
        )
        var result = AgentTaskResultActionState(binding: AgentTaskResultActionBinding(
            taskID: UUID(), project: project, recipeFingerprint: selected.recipe.fingerprint,
            resultActionID: "run-example", output: .cli, snapshot: snapshot
        ))
        result = result.reduced(by: .launchRequested)
        result = result.reduced(by: .processObserved(processID: 42, processGroupID: 42))
        result = result.reduced(by: .processExited(0))
        #expect(result.isCurrent)
        #expect(result.verb == .runExample)

        // Task 2: the same origin recipe yields identical setup, checks,
        // and result commands without reconstruction.
        let secondProject = AgentTaskProjectIdentity(
            canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/second"
        )
        let second = try AgentProjectRecipe.select(projectCheckedIn: origin, for: secondProject)
        #expect(second.plan == selected.plan)
        #expect(second.recipe.setup.map(\.id) == selected.recipe.setup.map(\.id))
        #expect(second.recipe.results.map(\.id) == selected.recipe.results.map(\.id))
        let secondPreparation = AgentProjectPreparation(recipe: second.recipe)
        #expect(secondPreparation.recipeFingerprint == preparation.recipeFingerprint)
        #expect(!secondPreparation.isUsable)
    }

    @Test func proposeAndSelectPerformNoFilesystemSideEffects() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pine-recipe-\(UUID().uuidString)")
        let sources = directory.appending(path: "Sources").appending(path: "democli")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "manifest".write(to: directory.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "main".write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: directory.path, canonicalWorktreePath: directory.path
        )
        func entries() -> [String] {
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ))?.map(\.lastPathComponent).sorted() ?? []
        }
        let before = entries()
        let recipe = AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/democli/main.swift"], for: identity
        )
        #expect(entries() == before)
        if let recipe {
            _ = try AgentProjectRecipe.select(projectCheckedIn: recipe, for: identity)
            #expect(entries() == before)
        }
    }
}
