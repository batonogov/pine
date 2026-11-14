import Foundation
import Testing
@testable import Pine

struct CodexAppServerApprovalPolicyTests {
    private let root = URL(filePath: "/tmp/pine-approval-root")
    private var command: [String: AgentEventJSON] {
        ["command": .string("fixture-command"), "cwd": .string(root.path)]
    }

    @Test func exactSetupCommandStillRequiresOrdinaryCommandKind() {
        #expect(CodexAppServerApprovalPolicy.allowsOneShot(method: "item/commandExecution/requestApproval",
            payload: .object(command), workingDirectory: root, setupCommand: "fixture-command"))
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/commandExecution/requestApproval",
            payload: .object(command), workingDirectory: root, setupCommand: "other-command"))
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/fileChange/requestApproval",
            payload: .object([:]), workingDirectory: root, setupCommand: "fixture-command"))
    }

    @Test(arguments: ["writeStdin", "humanCommand", "futureKind"])
    func unsupportedKindsCannotBecomeOneShotCommands(_ kind: String) {
        var fields = command
        fields["kind"] = .string(kind)
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/commandExecution/requestApproval",
            payload: .object(fields), workingDirectory: root))
    }

    @Test(arguments: ["environmentId", "networkApprovalContext", "grantRoot"])
    func oneShotAcceptCannotAuthorizeDifferentEnvironmentOrSessionScope(_ key: String) {
        var fields = command
        fields[key] = .string("untrusted-value")
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/commandExecution/requestApproval",
            payload: .object(fields), workingDirectory: root))
    }

    @Test func implementationApprovalMustUseExactBoundWorkingDirectory() {
        var fields = command
        fields["cwd"] = .string("/tmp/other-root")
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/commandExecution/requestApproval",
            payload: .object(fields), workingDirectory: root))
    }

    @Test func fileApprovalCannotGrantSessionWideRootEvenInsideBinding() {
        #expect(CodexAppServerApprovalPolicy.allowsOneShot(method: "item/fileChange/requestApproval",
            payload: .object(["grantRoot": .null]), workingDirectory: root))
        #expect(!CodexAppServerApprovalPolicy.allowsOneShot(method: "item/fileChange/requestApproval",
            payload: .object(["grantRoot": .string(root.path)]), workingDirectory: root))
    }
}
