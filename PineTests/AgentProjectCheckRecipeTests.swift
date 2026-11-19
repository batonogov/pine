import Foundation
import Testing
@testable import Pine

struct AgentProjectCheckRecipeTests {
    private let project = AgentTaskProjectIdentity(
        canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/first"
    )

    private func recipe(
        scheme: UInt8 = 1,
        id: String = "swift",
        projectPath: String = "/project",
        arguments: [String] = ["test"],
        required: Bool = true,
        outputs: Set<String> = [],
        configuration: Set<String> = ["Package.swift"]
    ) -> AgentProjectCheckRecipe {
        AgentProjectCheckRecipe(
            scheme: scheme, id: id, canonicalProjectPath: projectPath,
            commands: [
                AgentTaskCheckCommand(
                    id: "test", required: required,
                    executable: URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: arguments, workingDirectory: "", timeout: 60
                )
            ],
            capturePolicy: AgentVerificationCapturePolicy(
                declaredOutputs: outputs, requiredIgnoredInputs: []
            ),
            configurationFiles: configuration
        )
    }

    @Test func selectedRecipeFeedsExistingPlanWithoutChangingLiteralCommand() throws {
        let suggestion = recipe(arguments: ["test", "", "$(not a shell)", "two words", "🐴"])
        let plan = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: suggestion, for: project)
        #expect(plan.isValid)
        #expect(plan.commands == suggestion.commands)
        #expect(plan.recipeFingerprint == suggestion.fingerprint)
        #expect(plan.capturePolicy == suggestion.capturePolicy)
        #expect(plan.configurationFiles == suggestion.configurationFiles)
    }

    @Test func repeatTaskReusesRecipeNotOriginalWorktreeOrTaskGrant() throws {
        let suggestion = recipe()
        let first = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: suggestion, for: project)
        let secondProject = AgentTaskProjectIdentity(
            canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/second"
        )
        let second = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: suggestion, for: secondProject)
        #expect(first == second)
        let firstTask = UUID()
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
            configurationFingerprint: String(repeating: "c", count: 64)
        )
        let grant = AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: firstTask, planFingerprint: first.fingerprint,
            environment: environment, approvedAt: Date(), revokedAt: nil
        )
        #expect(grant.matchesScope(taskID: firstTask, plan: second, environment: environment))
        #expect(!grant.matchesScope(taskID: UUID(), plan: second, environment: environment))
        for changed in [
            recipe(arguments: ["test", "--parallel"]),
            recipe(id: "different-selection"),
            recipe(outputs: [".build"]),
            recipe(configuration: ["Package.swift", "Package.resolved"])
        ] {
            let changedPlan = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: changed, for: project)
            #expect(!grant.matchesScope(taskID: firstTask, plan: changedPlan, environment: environment))
        }
    }

    @Test func explicitLocalOverrideWinsButInvalidOverrideNeverFallsBack() throws {
        let suggestion = recipe()
        let local = recipe(arguments: ["test", "--filter", "Selected"])
        let selected = try AgentTaskCheckPlan.selectRecipe(
            projectSuggestion: suggestion, localOverride: local, for: project
        )
        #expect(selected.commands == local.commands)
        #expect(throws: AgentTaskCheckPlan.RecipeSelectionError.invalidRecipe) {
            try AgentTaskCheckPlan.selectRecipe(
                projectSuggestion: suggestion, localOverride: recipe(required: false), for: project
            )
        }
        #expect(try AgentTaskCheckPlan.selectRecipe(
            projectSuggestion: nil, localOverride: local, for: project
        ) == selected)
    }

    @Test func missingUnsupportedWrongProjectAndInvalidInputsFailClosed() {
        #expect(throws: AgentTaskCheckPlan.RecipeSelectionError.missingRecipe) {
            try AgentTaskCheckPlan.selectRecipe(projectSuggestion: nil, for: project)
        }
        #expect(throws: AgentTaskCheckPlan.RecipeSelectionError.unsupportedScheme) {
            try AgentTaskCheckPlan.selectRecipe(projectSuggestion: recipe(scheme: 2), for: project)
        }
        #expect(throws: AgentTaskCheckPlan.RecipeSelectionError.wrongProject) {
            try AgentTaskCheckPlan.selectRecipe(projectSuggestion: recipe(projectPath: "/other"), for: project)
        }
        for invalid in [
            recipe(id: ""), recipe(id: "bad\0id"), recipe(required: false),
            recipe(configuration: ["../escape"]), recipe(outputs: ["Package.swift"]),
            recipe(arguments: ["bad\0argument"])
        ] {
            #expect(throws: AgentTaskCheckPlan.RecipeSelectionError.invalidRecipe) {
                try AgentTaskCheckPlan.selectRecipe(projectSuggestion: invalid, for: project)
            }
        }
    }

    @Test func suggestionsAndPlansDoNotExposeLiteralSecretsInDiagnostics() throws {
        let suggestion = recipe(arguments: ["secret-argv-value"])
        let plan = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: suggestion, for: project)
        #expect(!String(describing: suggestion).contains("secret-argv-value"))
        #expect(!String(reflecting: suggestion).contains("secret-argv-value"))
        #expect(!String(reflecting: plan).contains("secret-argv-value"))
    }
}
