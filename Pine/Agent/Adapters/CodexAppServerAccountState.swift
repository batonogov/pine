import Foundation

/// Account/read is separate from owned-pipe transport authentication. This
/// value contains no account ID, email, token, provider path, or plan details.
/// Configured credentials are not proof that the next provider call will work.
nonisolated enum CodexAppServerAccountState: Equatable, Sendable {
    case signInRequired
    case credentialsConfigured
    case externalProviderUnverified
    case unknown

    init(response: AgentEventJSON) throws {
        guard case .object(let fields) = response,
              case .bool(let requiresAuth) = fields["requiresOpenaiAuth"] else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        if !requiresAuth {
            self = .externalProviderUnverified
        } else if fields["account"] == nil || fields["account"] == .null {
            self = .signInRequired
        } else {
            guard case .object(let account) = fields["account"],
                  case .string(let type) = account["type"] else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            self = ["apiKey", "chatgpt"].contains(type) ? .credentialsConfigured : .unknown
        }
    }
}
