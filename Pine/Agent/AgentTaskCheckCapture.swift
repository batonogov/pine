import Foundation

extension AgentVerificationIdentityCapture {
    nonisolated enum CheckInputError: Error {
        case inconsistentOperation
    }

    /// Used at the off-main launch gate and again after process cleanup.
    /// The executor still validates current run/selection/grant authority and
    /// compares the returned snapshot with operation.expected before any effect.
    nonisolated static func forCheckOperation(
        _ operation: AgentTaskCheckOperationInputs,
        environmentValues: [String: String],
        cancellation: GitCommandCancellationToken
    ) throws -> Self {
        try operation.binding.validateAuthority()
        let inputs = operation.capture
        let plan = operation.plan
        let binding = operation.binding
        let root = inputs.lease.canonicalWorktree
        guard operation.taskID == operation.binding.taskID,
              inputs.lease.identity == operation.binding.identity,
              plan.isValid, plan.commands.contains(where: { $0.id == operation.commandID }),
              inputs.policy == plan.capturePolicy,
              inputs.tools.count == Set(inputs.tools).count,
              Set(inputs.tools) == Set(plan.commands.map(\.executable)),
              inputs.configurationFiles.count == plan.configurationFiles.count,
              Set(inputs.configurationFiles) == Set(plan.configurationFiles.map { root.appending(path: $0) }),
              case .available = inputs.editor else {
            throw CheckInputError.inconsistentOperation
        }
        return Self(
            inputs: inputs,
            environmentValues: { environmentValues },
            authorityIsCurrent: { (try? binding.validateAuthority()) != nil },
            cancellation: cancellation
        )
    }
}
