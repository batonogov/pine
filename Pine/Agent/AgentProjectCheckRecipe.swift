import Foundation

/// Runtime check-recipe suggestion, not execution authority or a disk format.
/// Literal argv stays ephemeral, following AgentTaskCheckCommand's privacy contract.
/// Setup and result actions are not supported by this check-only recipe kind.
nonisolated struct AgentProjectCheckRecipe: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let currentScheme: UInt8 = 1
    let scheme: UInt8
    let id: String
    /// Canonical origin project, not the first task's isolated worktree.
    let canonicalProjectPath: String
    let commands: [AgentTaskCheckCommand]
    let capturePolicy: AgentVerificationCapturePolicy
    let configurationFiles: Set<String>

    var description: String { "<redacted:project-check-recipe>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    var fingerprint: String {
        var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.project-check-recipe.v1")
        hash.append("scheme", String(scheme))
        hash.append("id", id)
        hash.append("project", canonicalProjectPath)
        hash.append("capture-policy", capturePolicy.fingerprint)
        for path in AgentVerificationCapturePolicy.sorted(configurationFiles) {
            hash.append("configuration", path)
        }
        for command in commands { hash.append("command", command.fingerprint) }
        return hash.finish()
    }
}

extension AgentTaskCheckPlan {
    enum RecipeSelectionError: Error, Equatable {
        case missingRecipe, unsupportedScheme, invalidRecipe, wrongProject
    }

    /// Explicit local selection only. Import/restore callers must not invoke this
    /// as an automatic approval path. The returned plan still requires a current
    /// task/environment grant and the executor's immediate pre-spawn validation.
    /// An invalid local override never falls back to a different command set.
    static func selectRecipe(
        projectSuggestion: AgentProjectCheckRecipe?,
        localOverride: AgentProjectCheckRecipe? = nil,
        for project: AgentTaskProjectIdentity
    ) throws -> AgentTaskCheckPlan {
        guard let recipe = localOverride ?? projectSuggestion else {
            throw RecipeSelectionError.missingRecipe
        }
        guard recipe.scheme == AgentProjectCheckRecipe.currentScheme else {
            throw RecipeSelectionError.unsupportedScheme
        }
        guard recipe.canonicalProjectPath == project.canonicalProjectPath else {
            throw RecipeSelectionError.wrongProject
        }
        guard !recipe.id.isEmpty, recipe.id.utf8.count <= 128, !recipe.id.utf8.contains(0),
              recipe.canonicalProjectPath.hasPrefix("/"),
              recipe.canonicalProjectPath.utf8.count <= 16_384,
              !recipe.canonicalProjectPath.utf8.contains(0),
              URL(fileURLWithPath: recipe.canonicalProjectPath).standardizedFileURL.path
                == recipe.canonicalProjectPath else {
            throw RecipeSelectionError.invalidRecipe
        }
        let plan = AgentTaskCheckPlan(
            scheme: currentScheme,
            recipeFingerprint: String(repeating: "0", count: 64),
            commands: recipe.commands,
            capturePolicy: recipe.capturePolicy,
            configurationFiles: recipe.configurationFiles
        )
        guard plan.isValid else { throw RecipeSelectionError.invalidRecipe }
        // Bound every declaration before hashing potentially untrusted inputs.
        return AgentTaskCheckPlan(
            scheme: plan.scheme, recipeFingerprint: recipe.fingerprint,
            commands: plan.commands, capturePolicy: plan.capturePolicy,
            configurationFiles: plan.configurationFiles
        )
    }
}
