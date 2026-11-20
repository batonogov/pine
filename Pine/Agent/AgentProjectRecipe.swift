import Foundation

/// The source of a selected recipe. Distinguishes checked-in suggestions
/// from agent proposals from locally selected configuration. Origin affects
/// selection precedence and displayed trust only; it never affects the
/// recipe fingerprint and it never grants execution authority.
nonisolated enum AgentProjectRecipeOrigin: String, Sendable {
    case projectCheckedIn
    case agentProposed
    case localSelection
}

/// A supported project kind. `swiftPackage` is the implemented vertical
/// slice; other kinds are documented extension points
/// (docs/ade-project-recipes.md).
nonisolated enum AgentProjectRecipeKind: String, Sendable {
    case swiftPackage
}

/// A supported environment prerequisite: a canonical tool executable the
/// environment must provide. The recipe stores a reference, not a version
/// claim; the environment identity binds the actual executable bytes
/// through the existing capture contract.
nonisolated struct AgentProjectPrerequisite: Hashable, Sendable {
    let name: String
    let executable: URL

    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 128 && !name.utf8.contains(0)
            && executable.isFileURL && executable.baseURL == nil && executable.host == nil
            && executable.path.hasPrefix("/") && !executable.hasDirectoryPath
            && executable.path.utf8.count <= 16_384 && !executable.path.utf8.contains(0)
            && !executable.path.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }
}

/// A named reference to a secret, never its value. Values are resolved at
/// launch time by the environment owner (#1723) from a validated binding;
/// no recipe, plan, grant, or log ever contains the value.
nonisolated struct AgentProjectSecretReference: Hashable, Sendable {
    /// An environment variable name such as `DEPLOY_TOKEN`.
    let name: String

    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }
}

/// The typed output a result action must produce before it may be
/// presented as a current result. A suggested URL or path is not evidence
/// of a running result.
nonisolated enum AgentProjectResultOutput: Equatable, Sendable {
    /// An identified build artifact relative to the task root.
    case artifact(relativePath: String)
    /// A Pine-owned loopback server endpoint.
    case server(host: String, port: UInt16)
    /// A one-shot CLI example run.
    case cli
    /// A document reference; non-runnable, presented as view-only.
    case document(relativePath: String)

    var isRunnable: Bool {
        if case .document = self { return false }
        return true
    }

    /// A one-shot run keeps its observed result without a live process.
    var isOneShot: Bool {
        if case .cli = self { return true }
        return false
    }

    /// A live development preview: a server serving the worktree changes
    /// without new evidence whenever the worktree changes.
    var isLivePreview: Bool {
        if case .server = self { return true }
        return false
    }

    var isValid: Bool {
        switch self {
        case .artifact(let path), .document(let path):
            return AgentVerificationCapturePolicy.validRelativePath(path)
        case .server(let host, let port):
            return (host == "127.0.0.1" || host == "::1") && port > 0
        case .cli:
            return true
        }
    }

    /// Canonical encoding for fingerprinting, not a display string.
    var fingerprintComponent: String {
        switch self {
        case .artifact(let path): return "artifact\u{0}" + path
        case .server(let host, let port): return "server\u{0}" + host + "\u{0}" + String(port)
        case .cli: return "cli"
        case .document(let path): return "document\u{0}" + path
        }
    }
}

/// A named result action: the shared command contract used to produce a
/// typed output. Selection grants no execution authority; launching
/// requires the current binding, grant, and pre-spawn validation.
nonisolated struct AgentProjectResultAction: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: String
    let output: AgentProjectResultOutput
    let command: AgentTaskCheckCommand

    var description: String { "<redacted:result-action>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.utf8.contains(0)
            && output.isValid && command.isValid
    }
}

/// A versioned, declarative project recipe: identity, environment
/// prerequisites, setup actions, checks, and named result actions.
///
/// Suggestion content, not a disk format and not execution authority.
/// Importing, opening, or restoring a file that describes a recipe selects
/// nothing and runs nothing. Setup and result commands reuse the shared
/// check-command contract (#1753/#1754); there is no second command or
/// execution policy.
nonisolated struct AgentProjectRecipe: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let currentScheme: UInt8 = 1
    static let maximumSetupActions = 16
    static let maximumResultActions = 8
    static let maximumPrerequisites = 16
    static let maximumSecretRequirements = 64

    let scheme: UInt8
    let kind: AgentProjectRecipeKind
    let canonicalProjectPath: String
    let prerequisites: [AgentProjectPrerequisite]
    /// Setup is all-or-nothing: every action is required.
    let setup: [AgentTaskCheckCommand]
    /// The selected check contract; its fingerprint flows into the plan.
    let checks: AgentProjectCheckRecipe
    let results: [AgentProjectResultAction]
    /// Secret references keyed by the command id that requires them.
    let secretRequirements: [String: [AgentProjectSecretReference]]

    var description: String { "<redacted:project-recipe>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    var isValid: Bool {
        scheme == Self.currentScheme
            && canonicalProjectPath.hasPrefix("/")
            && canonicalProjectPath.utf8.count <= 16_384
            && !canonicalProjectPath.utf8.contains(0)
            && URL(fileURLWithPath: canonicalProjectPath).standardizedFileURL.path == canonicalProjectPath
            && prerequisites.count <= Self.maximumPrerequisites
            && prerequisites.allSatisfy(\.isValid)
            && Set(prerequisites.map(\.name)).count == prerequisites.count
            && setup.count <= Self.maximumSetupActions
            && setup.allSatisfy { $0.required && $0.isValid }
            && Set(setup.map(\.id) + checks.commands.map(\.id) + results.map(\.command.id)).count
                == setup.count + checks.commands.count + results.count
            && checks.scheme == AgentProjectCheckRecipe.currentScheme
            && checks.canonicalProjectPath == canonicalProjectPath
            // The embedded section must be selectable, not just shaped: probe
            // it with the shared plan gate (zero-filled fingerprint is valid,
            // mirroring AgentProjectCheckRecipe.selectRecipe).
            && AgentTaskCheckPlan(
                scheme: checks.scheme,
                recipeFingerprint: String(repeating: "0", count: 64),
                commands: checks.commands,
                capturePolicy: checks.capturePolicy,
                configurationFiles: checks.configurationFiles
            ).isValid
            && results.count <= Self.maximumResultActions
            && results.allSatisfy(\.isValid)
            && Set(results.map(\.id)).count == results.count
            && secretRequirements.count <= Self.maximumSecretRequirements
            && secretRequirements.allSatisfy { commandID, references in
                commandID.utf8.count <= 128 && !commandID.utf8.contains(0)
                    && references.count <= 16 && references.allSatisfy(\.isValid)
                    && Set(references.map(\.name)).count == references.count
            }
            && secretRequirements.keys.allSatisfy(knownCommandIDs.contains)
    }

    /// Content identity, independent of origin and selection tier.
    var fingerprint: String {
        var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.project-recipe.v1")
        hash.append("scheme", String(scheme))
        hash.append("kind", kind.rawValue)
        hash.append("project", canonicalProjectPath)
        for prerequisite in prerequisites {
            hash.append("prerequisite", prerequisite.name + "\u{0}" + prerequisite.executable.path)
        }
        for command in setup { hash.append("setup", command.fingerprint) }
        hash.append("checks", checks.fingerprint)
        for result in results {
            hash.append("result", result.id + "\u{0}" + result.output.fingerprintComponent
                + "\u{0}" + result.command.fingerprint)
        }
        for commandID in secretRequirements.keys.sorted() {
            for reference in (secretRequirements[commandID] ?? []).sorted(by: { $0.name < $1.name }) {
                hash.append("secret", commandID + "\u{0}" + reference.name)
            }
        }
        return hash.finish()
    }

    private var knownCommandIDs: Set<String> {
        Set(setup.map(\.id)).union(checks.commands.map(\.id)).union(results.map(\.command.id))
    }

    enum SelectionError: Error, Equatable {
        case missingRecipe
        case unsupportedScheme
        case wrongProject
        case invalidRecipe
    }

    struct Selected: Equatable, Sendable {
        let recipe: AgentProjectRecipe
        let origin: AgentProjectRecipeOrigin
        /// The check plan derived from this specific selected recipe version.
        let plan: AgentTaskCheckPlan
    }
}

extension AgentProjectRecipe {
    /// Explicit selection only; import, open, and restore must not call
    /// this automatically. Precedence: local selection, then agent
    /// proposal, then checked-in suggestion. A chosen recipe that is
    /// invalid, unsupported, or for another project never falls back to a
    /// different tier's commands. The returned plan still requires the
    /// current task/environment grant and pre-spawn validation.
    static func select(
        projectCheckedIn: AgentProjectRecipe?,
        agentProposed: AgentProjectRecipe? = nil,
        localSelection: AgentProjectRecipe? = nil,
        for project: AgentTaskProjectIdentity
    ) throws -> Selected {
        let recipe: AgentProjectRecipe
        let origin: AgentProjectRecipeOrigin
        switch (localSelection, agentProposed, projectCheckedIn) {
        case let (local?, _, _):
            recipe = local
            origin = .localSelection
        case let (_, agent?, _):
            recipe = agent
            origin = .agentProposed
        case let (_, _, checkedIn?):
            recipe = checkedIn
            origin = .projectCheckedIn
        default:
            throw SelectionError.missingRecipe
        }
        guard recipe.scheme == Self.currentScheme else { throw SelectionError.unsupportedScheme }
        guard recipe.canonicalProjectPath == project.canonicalProjectPath else {
            throw SelectionError.wrongProject
        }
        guard recipe.isValid else { throw SelectionError.invalidRecipe }
        // The checks section is bound by the existing contract; failure means
        // the selected recipe is unusable, never that another tier's checks
        // should run instead.
        let plan = try AgentTaskCheckPlan.selectRecipe(projectSuggestion: recipe.checks, for: project)
        return Selected(recipe: recipe, origin: origin, plan: plan)
    }

    /// Recognizes supported project files and proposes a small plan for the
    /// implemented `swiftPackage` kind. Pure over recognized relative file
    /// names; the caller enumerates the directory off the main thread.
    /// Returns nil when no supported kind is recognized. A proposal is a
    /// suggestion until explicitly selected.
    static func propose(
        recognizedFiles: Set<String>,
        for project: AgentTaskProjectIdentity
    ) -> AgentProjectRecipe? {
        guard recognizedFiles.contains("Package.swift") else { return nil }
        // Exactly one executable target: Sources/<target>/main.swift.
        var targets: Set<String> = []
        for path in recognizedFiles where path.hasPrefix("Sources/") {
            let components = path.split(separator: "/")
            if components.count >= 3, String(components[2]) == "main.swift" {
                targets.insert(String(components[1]))
            }
        }
        guard targets.count == 1, let target = targets.first else { return nil }
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        var checkCommands = [AgentTaskCheckCommand(
            id: "build", required: true, executable: swift,
            arguments: ["build"], workingDirectory: "", timeout: 1800
        )]
        if recognizedFiles.contains(where: { $0.hasPrefix("Tests/") }) {
            checkCommands.append(AgentTaskCheckCommand(
                id: "test", required: false, executable: swift,
                arguments: ["test"], workingDirectory: "", timeout: 1800
            ))
        }
        return AgentProjectRecipe(
            scheme: Self.currentScheme,
            kind: .swiftPackage,
            canonicalProjectPath: project.canonicalProjectPath,
            prerequisites: [AgentProjectPrerequisite(name: "swift", executable: swift)],
            setup: [AgentTaskCheckCommand(
                id: "resolve", required: true, executable: swift,
                arguments: ["package", "resolve"], workingDirectory: "", timeout: 600
            )],
            checks: AgentProjectCheckRecipe(
                scheme: AgentProjectCheckRecipe.currentScheme,
                id: "swift",
                canonicalProjectPath: project.canonicalProjectPath,
                commands: checkCommands,
                capturePolicy: AgentVerificationCapturePolicy(
                    declaredOutputs: [".build"], requiredIgnoredInputs: []
                ),
                configurationFiles: Set(["Package.swift"] + (
                    recognizedFiles.contains("Package.resolved") ? ["Package.resolved"] : []
                ))
            ),
            results: [AgentProjectResultAction(
                id: "run-example",
                output: .cli,
                command: AgentTaskCheckCommand(
                    id: "run", required: true, executable: swift,
                    arguments: ["run", target], workingDirectory: "", timeout: 600
                )
            )],
            secretRequirements: [:]
        )
    }
}
