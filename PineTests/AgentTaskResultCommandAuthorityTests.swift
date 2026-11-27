import Foundation
import Testing
@testable import Pine

nonisolated private final class ResultAuthorityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var grantValue: AgentTaskCheckGrant?
    private var readiness: AgentTaskReadiness?
    private var capturedIdentity: AgentVerificationIdentityCaptureResult?
    private var currentEnvironment = true

    init(grant: AgentTaskCheckGrant) {
        grantValue = grant
        readiness = AgentTaskReadiness(isReady: true, gaps: [])
    }

    func setGrant(_ value: AgentTaskCheckGrant?) { lock.withLock { grantValue = value } }
    func setReadiness(_ value: AgentTaskReadiness?) { lock.withLock { readiness = value } }
    func setIdentity(_ value: AgentVerificationIdentityCaptureResult?) {
        lock.withLock { capturedIdentity = value }
    }
    func setEnvironmentIsCurrent(_ value: Bool) { lock.withLock { currentEnvironment = value } }

    func authority(
        taskID: UUID, project: AgentTaskProjectIdentity,
        plan: AgentTaskCheckPlan, expected: AgentVerificationIdentitySnapshot
    ) -> AgentTaskResultCommandAuthority {
        AgentTaskResultCommandAuthority(
            taskID: taskID, project: project, plan: plan, expected: expected,
            currentGrant: { [self] in lock.withLock { grantValue } },
            currentReadiness: { [self] _ in lock.withLock { readiness } },
            captureIdentity: { [self] _ in lock.withLock { capturedIdentity } ?? .current(expected) },
            environmentIsCurrent: { [self] in lock.withLock { currentEnvironment } }
        )
    }
}

/// `AgentTaskResultCommandAuthority.validate` is the pre-spawn fence of every
/// setup and result command. Each refusal is named, so the result surface
/// states the real reason instead of a collapsed one (#1725).
struct AgentTaskResultCommandAuthorityTests {
    private let taskID = UUID()
    private let project = AgentTaskProjectIdentity(
        canonicalProjectPath: "/project", canonicalWorktreePath: "/tasks/first"
    )
    private let identity = AgentVerificationIdentitySnapshot(
        code: ADEContractFixtures.codeState("a"), environment: ADEContractFixtures.environment
    )
    private let plan = AgentTaskCheckPlan(
        scheme: AgentTaskCheckPlan.currentScheme,
        recipeFingerprint: ADEContractFixtures.hex("a"),
        commands: [AgentTaskCheckCommand(
            id: "build", required: true, executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: ["build"], workingDirectory: "", timeout: 60
        )],
        capturePolicy: AgentVerificationCapturePolicy(
            declaredOutputs: [".build"], requiredIgnoredInputs: []
        ),
        configurationFiles: ["Package.swift"]
    )

    /// A grant for this task and plan, unless a test narrows its scope.
    private func grant(
        taskID: UUID? = nil,
        planFingerprint: String? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        revokedAt: Date? = nil
    ) -> AgentTaskCheckGrant {
        AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme, id: UUID(),
            taskID: taskID ?? self.taskID,
            planFingerprint: planFingerprint ?? plan.fingerprint,
            environment: environment ?? identity.environment,
            approvedAt: Date(), revokedAt: revokedAt
        )
    }

    private func validate(
        _ probe: ResultAuthorityProbe? = nil,
        project: AgentTaskProjectIdentity? = nil
    ) -> AgentTaskResultLaunchRefusal? {
        let probe = probe ?? ResultAuthorityProbe(grant: grant())
        return probe.authority(
            taskID: taskID, project: project ?? self.project, plan: plan, expected: identity
        ).validate(environment: ["PATH": "/usr/bin:/bin"])
    }

    @Test func currentIdentityReadinessGrantAndEnvironmentAuthorizeTheCommand() {
        #expect(validate() == nil)
        // The spawn gate recaptures with exactly the child environment.
        let probe = ResultAuthorityProbe(grant: grant())
        #expect(probe.authority(
            taskID: taskID, project: project, plan: plan, expected: identity
        ).validate(environment: ["PATH": "/custom", "PINE_RESULT_TEST": "literal child value"]) == nil)
    }

    @Test func originalCheckoutIsRefusedBeforeAnyOtherCheck() {
        let checkout = AgentTaskProjectIdentity(
            canonicalProjectPath: "/project", canonicalWorktreePath: "/project"
        )
        #expect(validate(project: checkout) == .originalCheckout)
        // Named even when the grant is also gone: the checkout fence runs first.
        let revoked = ResultAuthorityProbe(grant: grant())
        revoked.setGrant(nil)
        #expect(validate(revoked, project: checkout) == .originalCheckout)
    }

    @Test func bindingChangedIsNamedWhenTheRecapturedIdentityIsNotTheBoundOne() {
        let changed = ResultAuthorityProbe(grant: grant())
        changed.setIdentity(.changed)
        #expect(validate(changed) == .bindingChanged)

        let other = ResultAuthorityProbe(grant: grant())
        other.setIdentity(.current(AgentVerificationIdentitySnapshot(
            code: ADEContractFixtures.codeState("b"), environment: identity.environment
        )))
        #expect(validate(other) == .bindingChanged)
    }

    @Test func cancelledIdentityCaptureIsRefusedAsChangedAuthority() {
        let probe = ResultAuthorityProbe(grant: grant())
        probe.setIdentity(.cancelled)
        #expect(validate(probe) == .authorityChanged)
    }

    @Test(arguments: [
        AgentVerificationIdentityCaptureResult.Reason.unavailableBinding,
        .unsavedEditorChanges, .unavailableTool, .budgetExceeded,
    ])
    func unavailableIdentityCaptureIsRefusedAsEnvironmentUnavailable(
        reason: AgentVerificationIdentityCaptureResult.Reason
    ) {
        let probe = ResultAuthorityProbe(grant: grant())
        probe.setIdentity(.unavailable(reason))
        #expect(validate(probe) == .environmentUnavailable)
    }

    @Test func environmentThatIsNoLongerCurrentIsRefusedAsEnvironmentUnavailable() {
        let probe = ResultAuthorityProbe(grant: grant())
        probe.setEnvironmentIsCurrent(false)
        #expect(validate(probe) == .environmentUnavailable)
    }

    @Test(arguments: [
        AgentTaskReadiness(isReady: false, gaps: [.verificationNotCurrent]),
        AgentTaskReadiness(isReady: false, gaps: [.failingEvidence(.independentCheck)]),
        // A set Ready flag beside a gap is not Ready either.
        AgentTaskReadiness(isReady: true, gaps: [.staleEvidence(.reviewerOutcome)]),
    ])
    func unreadyResultIsRefusedAsNotReady(readiness: AgentTaskReadiness) {
        let probe = ResultAuthorityProbe(grant: grant())
        probe.setReadiness(readiness)
        #expect(validate(probe) == .notReady)
    }

    @Test func readinessIsNamedBeforeTheGrant() {
        let probe = ResultAuthorityProbe(grant: grant())
        probe.setGrant(nil)
        probe.setReadiness(nil)
        #expect(validate(probe) == .notReady)
    }

    @Test func missingForeignRevokedOrMismatchedGrantIsRefusedAsGrantNotCurrent() {
        let missing = ResultAuthorityProbe(grant: grant())
        missing.setGrant(nil)
        #expect(validate(missing) == .grantNotCurrent)

        let foreign = ResultAuthorityProbe(grant: grant(taskID: UUID()))
        #expect(validate(foreign) == .grantNotCurrent)

        let revoked = ResultAuthorityProbe(grant: grant(revokedAt: Date()))
        #expect(validate(revoked) == .grantNotCurrent)

        let rePlanned = ResultAuthorityProbe(grant: grant(planFingerprint: ADEContractFixtures.hex("b")))
        #expect(validate(rePlanned) == .grantNotCurrent)

        let otherEnvironment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: "other",
            configurationFingerprint: ADEContractFixtures.hex("e")
        )
        let reProvisioned = ResultAuthorityProbe(grant: grant(environment: otherEnvironment))
        #expect(validate(reProvisioned) == .grantNotCurrent)
    }

    @Test func secretBearingResultCommandNeverYieldsALaunchContext() throws {
        let recipe = try #require(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/Example/main.swift"], for: project
        ))
        // A command that needs a secret has no resolution path yet: no
        // context can be made for it, so nothing can ever spawn it.
        let secret = AgentProjectRecipe(
            scheme: recipe.scheme, kind: recipe.kind,
            canonicalProjectPath: recipe.canonicalProjectPath,
            prerequisites: recipe.prerequisites, setup: recipe.setup, checks: recipe.checks,
            results: recipe.results,
            secretRequirements: ["run": [AgentProjectSecretReference(name: "DEPLOY_TOKEN")]]
        )
        #expect(secret.isValid)
        let selection = try AgentProjectRecipe.select(projectCheckedIn: secret, for: project)
        let binding = AgentTaskResultActionBinding(
            taskID: taskID, project: project, recipeFingerprint: selection.recipe.fingerprint,
            resultActionID: "run-example", output: .cli, snapshot: identity
        )
        var preparation = AgentProjectPreparation(recipe: selection.recipe)
        for name in preparation.prerequisiteNames {
            preparation = preparation.reduced(by: .prerequisiteResolved(name))
        }
        for id in preparation.setupActionIDs {
            preparation = preparation.reduced(by: .setupSucceeded(id))
        }
        let authority = ResultAuthorityProbe(
            grant: grant(planFingerprint: selection.plan.fingerprint)
        ).authority(taskID: taskID, project: project, plan: selection.plan, expected: identity)
        #expect(AgentTaskResultLaunchContext.make(
            binding: binding, selection: selection, preparation: preparation, authority: authority
        ) == nil)
    }
}
