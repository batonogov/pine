import Foundation

/// Limits the pinned schema's one-shot accept response. Proposed policy
/// amendments are never sent back; remote environments, managed network
/// access, stdin/human checkpoints, and session-wide file grants are unsupported.
nonisolated enum CodexAppServerApprovalPolicy {
    static func allowsOneShot(method: String, payload: AgentEventJSON,
                              workingDirectory: URL, setupCommand: String? = nil) -> Bool {
        guard case .object(let fields) = payload,
              absentOrNull(fields["environmentId"]), absentOrNull(fields["networkApprovalContext"]),
              absentOrNull(fields["grantRoot"]) else { return false }
        if method == "item/fileChange/requestApproval" { return setupCommand == nil }
        guard method == "item/commandExecution/requestApproval",
              fields["kind"] == nil || fields["kind"] == .string("command"),
              fields["cwd"] == .string(workingDirectory.path),
              case .string(let command) = fields["command"], !command.isEmpty, command.utf8.count <= 65_536 else { return false }
        if let setupCommand {
            return command == setupCommand && absentOrNull(fields["approvalId"])
        }
        return true
    }

    private static func absentOrNull(_ value: AgentEventJSON?) -> Bool { value == nil || value == .null }
}
