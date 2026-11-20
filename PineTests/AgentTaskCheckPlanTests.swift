import Foundation
import Testing
@testable import Pine

struct AgentTaskCheckPlanTests {
    private func command(
        id: String = "test", required: Bool = true,
        arguments: [String] = ["test"], timeout: TimeInterval = 30,
        executable: URL = URL(fileURLWithPath: "/usr/bin/true")
    ) -> AgentTaskCheckCommand {
        AgentTaskCheckCommand(
            id: id, required: required, executable: executable,
            arguments: arguments, workingDirectory: "", timeout: timeout
        )
    }

    private func plan(_ commands: [AgentTaskCheckCommand]) -> AgentTaskCheckPlan {
        AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: String(repeating: "a", count: 64), commands: commands,
            capturePolicy: .conservative, configurationFiles: ["Package.swift"]
        )
    }

    @Test func emptyOptionalDuplicateAndUnsupportedPlansFailClosed() {
        #expect(!plan([]).isValid)
        #expect(!plan([command(required: false)]).isValid)
        #expect(!plan([command(), command()]).isValid)
        let unsupported = AgentTaskCheckPlan(
            scheme: 2, recipeFingerprint: String(repeating: "a", count: 64), commands: [command()],
            capturePolicy: .conservative, configurationFiles: []
        )
        #expect(!unsupported.isValid)
    }

    @Test func literalArgumentsRemainDistinctAndUnmodified() {
        let arguments = ["", "two words", "$(touch nope)", ";", "🐴", "a", "bc"]
        let value = command(arguments: arguments)
        #expect(value.isValid)
        #expect(value.arguments == arguments)
        #expect(value.fingerprint != command(arguments: ["", "two words", "$(touch nope)", ";", "🐴", "ab", "c"]).fingerprint)
        #expect(value.fingerprint != command(arguments: Array(arguments.reversed())).fingerprint)
    }

    @Test func commandAndRequiredSetChangesInvalidatePlanIdentity() {
        let original = plan([command()])
        #expect(original.isValid)
        #expect(original.fingerprint != plan([command(arguments: ["other"])]).fingerprint)
        #expect(original.fingerprint != plan([command(timeout: 31)]).fingerprint)
        #expect(original.fingerprint != plan([command(), command(id: "lint")]).fingerprint)
        #expect(plan([command(), command(id: "lint")]).fingerprint
            != plan([command(), command(id: "lint", required: false)]).fingerprint)
    }

    @Test func invalidCommandBoundsAndEscapingPathsAreRejected() {
        for timeout in [0, -1, .infinity, .nan, 3_601] {
            #expect(!command(timeout: timeout).isValid)
        }
        #expect(!command(arguments: ["bad\0argument"]).isValid)
        #expect(!command(arguments: [String(repeating: "x", count: 16_385)]).isValid)
        let escaped = AgentTaskCheckCommand(
            id: "test", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], workingDirectory: "../other-task", timeout: 30
        )
        #expect(!escaped.isValid)
    }

    @Test func configurationAndOutputDeclarationsBindPlanIdentity() {
        let original = plan([command()])
        let changed = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: original.recipeFingerprint, commands: original.commands,
            capturePolicy: AgentVerificationCapturePolicy(declaredOutputs: ["build"], requiredIgnoredInputs: []),
            configurationFiles: original.configurationFiles
        )
        #expect(changed.isValid)
        #expect(changed.fingerprint != original.fingerprint)
        let hiddenConfiguration = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: original.recipeFingerprint, commands: original.commands,
            capturePolicy: AgentVerificationCapturePolicy(declaredOutputs: ["Package.swift"], requiredIgnoredInputs: []),
            configurationFiles: original.configurationFiles
        )
        #expect(!hiddenConfiguration.isValid)
    }

    @Test func ambiguousExecutableURLsCannotAuthorizeLocalExecution() throws {
        let rejected = [
            "file://remote/usr/bin/true",
            "file://localhost/usr/bin/true",
            "file://user@/usr/bin/true",
            "file://user:password@/usr/bin/true",
            "file://:123/usr/bin/true",
            "file:///usr/bin/true?mode=other",
            "file:///usr/bin/true#other",
            "file:///usr/bin/true/",
            "file:///",
            "file:///usr/bin/tr%00ue",
            "file:///usr/bin/tr%0Aue",
            "https://example.com/usr/bin/true"
        ]
        for text in rejected {
            let executable = try #require(URL(string: text))
            #expect(!command(executable: executable).isValid)
            #expect(!plan([command(executable: executable)]).isValid)
        }
        let base = URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        let relative = try #require(URL(string: "true", relativeTo: base))
        #expect(!command(executable: relative).isValid)
        #expect(command().isValid)
        #expect(command(executable: try #require(URL(string: "file:///usr/bin/true"))).isValid)
    }

    @Test func grantRequiresExactTaskPlanEnvironmentAndCurrentApproval() throws {
        let taskID = UUID()
        let selected = plan([command(arguments: ["secret-not-for-persistence"])])
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
            configurationFingerprint: String(repeating: "c", count: 64)
        )
        var grant = AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: taskID, planFingerprint: selected.fingerprint,
            environment: environment, approvedAt: Date(), revokedAt: nil
        )
        #expect(grant.matchesScope(taskID: taskID, plan: selected, environment: environment))
        #expect(!grant.matchesScope(taskID: UUID(), plan: selected, environment: environment))
        #expect(!grant.matchesScope(taskID: taskID, plan: plan([command()]), environment: environment))
        let changedEnvironment = AgentTaskEnvironmentIdentity(
            osBuild: "25A2", toolchain: environment.toolchain,
            configurationFingerprint: environment.configurationFingerprint
        )
        #expect(!grant.matchesScope(taskID: taskID, plan: selected, environment: changedEnvironment))
        let data = try JSONEncoder().encode(grant)
        #expect(try #require(String(data: data, encoding: .utf8)).contains("secret-not-for-persistence") == false)
        #expect(try JSONDecoder().decode(AgentTaskCheckGrant.self, from: data) == grant)
        #expect(!String(reflecting: selected).contains("secret-not-for-persistence"))
        grant.revokedAt = Date()
        #expect(!grant.matchesScope(taskID: taskID, plan: selected, environment: environment))
    }

    @Test func eachApprovalBoundSelectionChangeInvalidatesOriginalGrant() {
        let taskID = UUID()
        let selected = plan([command()])
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
            configurationFingerprint: String(repeating: "c", count: 64)
        )
        let grant = AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: taskID, planFingerprint: selected.fingerprint,
            environment: environment, approvedAt: Date(), revokedAt: nil
        )
        let differentDirectory = AgentTaskCheckCommand(
            id: "test", required: true, executable: command().executable,
            arguments: command().arguments, workingDirectory: "Sources", timeout: 30
        )
        let changes: [(String, AgentTaskCheckPlan)] = [
            ("executable", plan([command(executable: URL(fileURLWithPath: "/usr/bin/false"))])),
            ("working directory", plan([differentDirectory])),
            ("recipe fingerprint", AgentTaskCheckPlan(
                scheme: 1, recipeFingerprint: String(repeating: "d", count: 64), commands: selected.commands,
                capturePolicy: selected.capturePolicy, configurationFiles: selected.configurationFiles
            )),
            ("configuration files", AgentTaskCheckPlan(
                scheme: 1, recipeFingerprint: selected.recipeFingerprint, commands: selected.commands,
                capturePolicy: selected.capturePolicy, configurationFiles: ["Package.resolved"]
            ))
        ]
        #expect(grant.matchesScope(taskID: taskID, plan: selected, environment: environment))
        for (field, changed) in changes {
            #expect(changed.isValid, "Changed field: \(field)")
            #expect(changed.fingerprint != selected.fingerprint, "Changed field: \(field)")
            #expect(!grant.matchesScope(taskID: taskID, plan: changed, environment: environment), "Changed field: \(field)")
        }
    }

    @Test func invalidGrantSchemaDateAndIncompleteEnvironmentFailClosed() {
        let taskID = UUID()
        let selected = plan([command()])
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "25A1", toolchain: String(repeating: "b", count: 64),
            configurationFingerprint: String(repeating: "c", count: 64)
        )
        let incomplete = AgentTaskEnvironmentIdentity(
            osBuild: environment.osBuild, toolchain: environment.toolchain, configurationFingerprint: nil
        )
        let boundaries: [(UInt8, Date, AgentTaskEnvironmentIdentity)] = [
            (0, Date(), environment),
            (2, Date(), environment),
            (1, Date(timeIntervalSince1970: .infinity), environment),
            (1, Date(timeIntervalSince1970: .nan), environment),
            (1, Date(), incomplete)
        ]
        for (scheme, approvedAt, boundEnvironment) in boundaries {
            let grant = AgentTaskCheckGrant(
                scheme: scheme, id: UUID(), taskID: taskID, planFingerprint: selected.fingerprint,
                environment: boundEnvironment, approvedAt: approvedAt, revokedAt: nil
            )
            #expect(!grant.matchesScope(taskID: taskID, plan: selected, environment: boundEnvironment))
        }
    }
}
