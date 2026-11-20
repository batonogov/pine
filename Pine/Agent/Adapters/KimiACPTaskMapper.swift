import CryptoKit
import Foundation

/// Ephemeral mapping of one Kimi ACP connection into the shared adapter
/// contract. ACP carries no provider turn ID on the wire; the session actor
/// owns prompt correlation and tells this mapper when a prompt is active.
/// Candidates are not trusted until registry ingress; no transcript, command,
/// question text, or provider timestamp is retained here.
nonisolated struct KimiACPTaskMapper {
    enum Effect: Sendable, Equatable {
        case working(chunk: String?)
        case attention(question: Attention, requestID: CodexAppServerRequestID, method: String)
        case requestResolved(request: VendorReference)
        case unsupportedRequest(CodexAppServerRequestID)
        case ignored
        case needsReconciliation
    }

    /// Presentation-free routing data for one pending question/approval.
    /// Wire params stay with the connection's replay memory, not here.
    struct Attention: Sendable, Equatable {
        let request: VendorReference
        let context: VendorReference
        let toolCall: VendorReference?
        let form: KimiACPForm?
        let options: [String: String]
    }

    static let maximumPendingRequests = KimiACPConnection.maximumServerRequests
    let connectionID: UUID
    let session: VendorReference
    private(set) var promptActive = false
    private var cancellationRequested = false
    private var pending: [CodexAppServerRequestID: (request: VendorReference, tool: String?, form: Bool)] = [:]
    private var answered: Set<CodexAppServerRequestID> = []
    private var resolved: Set<CodexAppServerRequestID> = []
    private var closed = false

    init(connectionID: UUID, sessionID: String) throws {
        guard KimiACPWire.validSessionID(sessionID) else { throw KimiACPWireError.invalidSessionID }
        self.connectionID = connectionID
        session = try VendorReference(role: .conversation, value: sessionID)
    }

    // MARK: Prompt and replay fencing

    /// Called only for an explicitly authorized session/prompt on this binding.
    mutating func beginPrompt() throws {
        guard !closed, !promptActive, !cancellationRequested else {
            throw KimiACPWireError.invalidState
        }
        promptActive = true
    }

    /// The correlated session/prompt response is the only turn terminator in
    /// ACP; every other "completion" is a claim, not a settlement.
    /// (`session/load` history replay is consumed by the session bootstrap
    /// before this mapper exists; it is never projected here.)
    mutating func endPrompt() throws {
        guard !closed, promptActive else { throw KimiACPWireError.invalidState }
        promptActive = false
        cancellationRequested = false
    }

    // MARK: Requests

    /// ACP scopes asks to the session, not to a root prompt: a settled parent
    /// turn must not close this attention context, but a request with no
    /// active prompt is stale and must not be answered.
    mutating func noteRequest(
        _ identifier: CodexAppServerRequestID,
        method: String,
        params: AgentEventJSON
    ) throws -> Effect {
        guard !closed else { return .needsReconciliation }
        guard promptActive, !cancellationRequested else {
            return .unsupportedRequest(identifier)
        }
        let question = method == "elicitation/create"
        let approval = method == "session/request_permission"
        guard question || approval else { return .unsupportedRequest(identifier) }
        guard !resolved.contains(identifier), !answered.contains(identifier) else {
            return .unsupportedRequest(identifier)
        }
        guard pending[identifier] == nil else { return .ignored }
        let fields = try KimiACPWire.object(params)
        guard KimiACPWire.matches(fields["sessionId"], string: session.rawValue) else {
            return .unsupportedRequest(identifier)
        }
        let form: KimiACPForm?
        var options: [String: String] = [:]
        var toolValue: String?
        if question {
            do {
                form = try KimiACPForm(fields)
            } catch KimiACPWireError.unsupportedCapability {
                // URL mode or a schema outside the strict subset: reject so
                // Kimi's documented fallback to session/request_permission
                // applies, instead of losing the whole turn.
                return .unsupportedRequest(identifier)
            }
            toolValue = try fields["toolCallId"].map { try KimiACPWire.boundedString($0, maximum: 256) }
        } else {
            form = nil
            let tool = try KimiACPWire.object(fields["toolCall"] ?? .null)
            toolValue = try tool["toolCallId"].map { try KimiACPWire.boundedString($0, maximum: 256) }
            guard case .array(let values) = fields["options"], !values.isEmpty, values.count <= 16 else {
                throw KimiACPWireError.invalidEnvelope
            }
            for value in values {
                let option = try KimiACPWire.object(value)
                let kind = try KimiACPWire.string(option["kind"])
                let optionID = try KimiACPWire.string(option["optionId"])
                guard options[kind] == nil, !options.values.contains(optionID) else {
                    throw KimiACPWireError.invalidEnvelope
                }
                options[kind] = optionID
            }
            // Pine offers no remembered decisions: both one-shot options are
            // required. Never fall back to a permissive default answer.
            guard options["allow_once"] != nil, options["reject_once"] != nil else {
                return .unsupportedRequest(identifier)
            }
        }
        guard pending.count < Self.maximumPendingRequests else {
            throw KimiACPWireError.capacity
        }
        let request = try VendorReference(role: .request, value: requestDigest(identifier))
        pending[identifier] = (request: request, tool: toolValue, form: question)
        let toolCall = try toolValue.map { try VendorReference(role: .toolCall, value: $0) }
        return .attention(question: Attention(
            request: request, context: session, toolCall: toolCall,
            form: form, options: options
        ), requestID: identifier, method: method)
    }

    func isActionable(_ identifier: CodexAppServerRequestID) -> Bool {
        !closed && !cancellationRequested && promptActive
            && pending[identifier] != nil && !answered.contains(identifier)
    }

    /// One-shot: after a physical write the request leaves `pending`; a
    /// re-answer must fail, and provider-side resolution only releases the
    /// replay memory.
    mutating func markAnswered(_ identifier: CodexAppServerRequestID) throws {
        guard pending[identifier] != nil, !answered.contains(identifier) else {
            throw KimiACPWireError.invalidState
        }
        pending.removeValue(forKey: identifier)
        answered.insert(identifier)
    }

    /// Spec: on session/cancel the client MUST answer every pending permission
    /// request with the `cancelled` outcome. Returns the exact wire IDs.
    mutating func cancelledPending() -> [CodexAppServerRequestID] {
        guard !cancellationRequested else { return [] }
        cancellationRequested = true
        return Array(pending.keys)
    }

    /// Provider-side resolution (owning tool reached a terminal status). A
    /// resolved request can never be answered later; the replay memory still
    /// serves redeliveries until capacity eviction.
    mutating func resolve(_ identifier: CodexAppServerRequestID) -> Effect {
        guard let entry = pending.removeValue(forKey: identifier) else { return .ignored }
        resolved.insert(identifier)
        answered.remove(identifier)
        return .requestResolved(request: entry.request)
    }

    /// Terminal `tool_call_update` for an owned tool settles every pending ask
    /// associated with it. Late tool activity after cancellation settles
    /// silently: the turn state is already unknown until the provider's
    /// cancelled stop reason confirms it.
    mutating func toolSettled(toolCallID: String) -> [Effect] {
        var effects: [Effect] = []
        for (identifier, entry) in Array(pending) where entry.tool == toolCallID {
            let effect = resolve(identifier)
            if case .requestResolved = effect { effects.append(effect) }
        }
        return effects
    }

    // MARK: Session updates

    mutating func map(_ message: CodexAppServerMessage, connection: UUID) throws -> [Effect] {
        guard connection == connectionID else { return [] }
        guard !closed else { return [.needsReconciliation] }
        guard case .notification(let method, let params) = message, method == "session/update" else {
            return []
        }
        let fields = try KimiACPWire.object(params)
        guard KimiACPWire.matches(fields["sessionId"], string: session.rawValue) else {
            return []
        }
        let update = try KimiACPWire.object(fields["update"] ?? .null)
        guard let kind = update["sessionUpdate"], case .string(let kindValue) = kind,
              kindValue.utf8.count <= 128 else {
            return [.needsReconciliation]
        }
        let settled = try toolEffects(update)
        guard promptActive else {
            // Late activity after the prompt response is not completion
            // evidence; it cannot move the settled turn state.
            return settled
        }
        let chunk = try agentChunkText(update)
        switch kindValue {
        case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk",
             "tool_call", "tool_call_update", "plan", "current_mode_update",
             "available_commands_update", "config_option_update", "session_info_update",
             "usage_update", "notice", "compaction_update", "compaction_summary_chunk":
            var effects = settled
            effects.append(.working(chunk: chunk))
            return effects
        default:
            // Future ACP kinds are additive; they cannot establish lifecycle
            // state, so they are observed and ignored, never fatal.
            return settled
        }
    }

    /// Only `agent_message_chunk` text is retained (bounded by the session);
    /// thought and user chunks are activity, not result evidence.
    private func agentChunkText(_ update: [String: AgentEventJSON]) throws -> String? {
        guard update["sessionUpdate"] == .string("agent_message_chunk"),
              case .object(let content) = update["content"] ?? .null,
              content["type"] == .string("text"),
              case .string(let text) = content["text"] else {
            return nil
        }
        guard text.utf8.count <= KimiACPPromptContent.maximumTextBytes else {
            throw KimiACPWireError.capacity
        }
        return text
    }

    private mutating func toolEffects(_ update: [String: AgentEventJSON]) throws -> [Effect] {
        let kind = try update["sessionUpdate"].flatMap { try KimiACPWire.string($0) }
        guard kind == "tool_call" || kind == "tool_call_update" else { return [] }
        guard case .string(let toolID) = update["toolCallId"],
              toolID.utf8.count <= 256 else {
            return []
        }
        if kind == "tool_call_update" {
            guard let status = try update["status"].flatMap({ try KimiACPWire.string($0) }),
                  ["completed", "failed", "cancelled"].contains(status) else {
                return []
            }
            return toolSettled(toolCallID: toolID)
        }
        return []
    }

    mutating func close() {
        closed = true
        promptActive = false
        pending.removeAll()
        answered.removeAll()
        resolved.removeAll()
    }

    var hasPendingRequests: Bool { !pending.isEmpty }

    private func requestDigest(_ identifier: CodexAppServerRequestID) throws -> String {
        // Typed JSON preserves integer-vs-string ID identity. This is a
        // redacted deterministic reference, not a replay cursor.
        SHA256.hash(data: try identifier.json.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}
