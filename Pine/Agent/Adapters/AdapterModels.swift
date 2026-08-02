import Foundation

nonisolated enum AgentPresentationStyle: String, Sendable { case claude, codex, aider, copilot, pi, generic }

nonisolated struct AgentPresentationDescriptor: Sendable {
    let agentID: AgentID
    let displayName: String
    let executableAliases: Set<ExecutableAlias>
    let style: AgentPresentationStyle

    init(agentID: AgentID, displayName: String, executableAliases: Set<ExecutableAlias>, style: AgentPresentationStyle) throws {
        guard executableAliases.count <= 16 else { throw AdapterValueError.tooLong("executableAliases", maximum: 16) }
        self.agentID = agentID
        self.displayName = try AdapterIdentifierValidation.displayText(displayName)
        self.executableAliases = executableAliases
        self.style = style
    }
}

/// A bounded programmatic registration. A future config loader owns byte and JSON validation.
nonisolated struct UserAgentPresentationRegistration: Sendable {
    let identifier: String
    let displayName: String
    let executableAliases: [String]

    init(identifier: String, displayName: String, executableAliases: [String]) throws {
        self.identifier = identifier
        self.displayName = displayName
        self.executableAliases = executableAliases
        _ = try normalized()
    }

    func normalized() throws -> AgentPresentationDescriptor {
        guard executableAliases.count <= 16 else { throw AdapterValueError.tooLong("executableAliases", maximum: 16) }
        let requested = try AgentID(validating: identifier)
        let userID = try AgentID(validating: requested.value.hasPrefix("user:") ? requested.value : "user:\(requested.value)")
        let aliases = try executableAliases.map(ExecutableAlias.init(validating:))
        guard Set(aliases).count == aliases.count else { throw AdapterRegistrationError.duplicateAlias }
        return try AgentPresentationDescriptor(
            agentID: userID,
            displayName: displayName,
            executableAliases: Set(aliases),
            style: .generic
        )
    }
}

nonisolated struct AdapterDescriptor: Sendable {
    let adapterID: AdapterID
    let agentID: AgentID
    let factoryID: AdapterFactoryID
    let contractVersions: PineAdapterContractVersionRange
    let maximumProfiles: [AdapterCapabilityProfile]
}

nonisolated struct DetectedVendorVersion: Hashable, Sendable, CustomStringConvertible {
    let value: String
    init(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AdapterValueError.invalidDisplayText
        }
        self.value = try AdapterIdentifierValidation.displayText(value)
    }
    var description: String { value }
}

nonisolated struct AdapterProbeResult: Sendable {
    let detectedVendorVersion: DetectedVendorVersion
    let detectedSchema: DetectedVendorVersion?
    let offeredProfiles: [AdapterCapabilityProfile]
    init(
        detectedVendorVersion: DetectedVendorVersion,
        detectedSchema: DetectedVendorVersion?,
        offeredProfiles: [AdapterCapabilityProfile]
    ) throws {
        guard offeredProfiles.count <= 16 else { throw AdapterProbeError.malformedResponse }
        guard Set(offeredProfiles).count == offeredProfiles.count else { throw AdapterProbeError.malformedResponse }
        self.detectedVendorVersion = detectedVendorVersion
        self.detectedSchema = detectedSchema
        self.offeredProfiles = offeredProfiles
    }
}

nonisolated enum CandidateFileOperation: String, Sendable { case create, modify, delete, rename }

nonisolated struct ClaimedContentIdentity: Equatable, Sendable {
    let sha256: String
    let byteCount: UInt64
    init(sha256: String, byteCount: UInt64) throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              byteCount <= 1_099_511_627_776 else {
            throw AdapterCandidateError.invalidContentIdentity
        }
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

nonisolated struct CandidateFileChange: Equatable, Sendable {
    let operation: CandidateFileOperation
    let relativePath: String
    let destinationRelativePath: String?
    let before: ClaimedContentIdentity?
    let after: ClaimedContentIdentity?

    init(
        operation: CandidateFileOperation,
        relativePath: String,
        destinationRelativePath: String? = nil,
        before: ClaimedContentIdentity? = nil,
        after: ClaimedContentIdentity? = nil
    ) throws {
        try Self.validate(path: relativePath)
        if let destinationRelativePath { try Self.validate(path: destinationRelativePath) }
        guard (operation == .rename) == (destinationRelativePath != nil) else {
            throw AdapterCandidateError.contradictoryEvent
        }
        guard operation != .create || before == nil,
              operation != .delete || after == nil else { throw AdapterCandidateError.contradictoryEvent }
        self.operation = operation
        self.relativePath = relativePath
        self.destinationRelativePath = destinationRelativePath
        self.before = before
        self.after = after
    }

    private static func validate(path: String) throws {
        guard path == path.precomposedStringWithCanonicalMapping,
              path.utf8.count <= 4_096, path.split(separator: "/", omittingEmptySubsequences: false).count <= 128,
              AgentHistoryUndoPreflight.isCanonicalRelativePath(path),
              path.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                           0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value)
                      && !scalar.properties.isDefaultIgnorableCodePoint
              }) else {
            throw AdapterCandidateError.invalidRelativePath
        }
    }
}

nonisolated enum CandidateToolCategory: String, Sendable {
    case read, write, search, execute, fileChange, network, other
}
nonisolated enum CandidateToolPhase: String, Sendable { case started, succeeded, failed, cancelled }

nonisolated struct CandidateToolEvent: Sendable {
    let phase: CandidateToolPhase
    let category: CandidateToolCategory
    let toolCall: VendorReference
    let fileChanges: [CandidateFileChange]
    init(phase: CandidateToolPhase, category: CandidateToolCategory, toolCall: VendorReference, fileChanges: [CandidateFileChange]) throws {
        guard toolCall.role == .toolCall, fileChanges.count <= 128,
              category != .fileChange || !fileChanges.isEmpty else {
            throw AdapterCandidateError.contradictoryEvent
        }
        try Self.validateBatch(fileChanges)
        self.phase = phase; self.category = category; self.toolCall = toolCall; self.fileChanges = fileChanges
    }

    private static func validateBatch(_ changes: [CandidateFileChange]) throws {
        var endpoints: [String] = []
        for change in changes {
            let source = AgentHistoryUndoPreflight.conservativePathKey(change.relativePath)
            try insert(source, into: &endpoints)
            if let destination = change.destinationRelativePath {
                let key = AgentHistoryUndoPreflight.conservativePathKey(destination)
                try insert(key, into: &endpoints)
            }
        }
    }

    private static func insert(_ path: String, into endpoints: inout [String]) throws {
        let components = path.split(separator: "/")
        guard !endpoints.contains(where: { existing in
            let existingComponents = existing.split(separator: "/")
            return components.starts(with: existingComponents) || existingComponents.starts(with: components)
        }) else { throw AdapterCandidateError.contradictoryEvent }
        endpoints.append(path)
    }
}

nonisolated struct CandidateLifecycleEvent: Sendable {
    let scope: AdapterLifecycleScope
    let phase: AdapterLifecyclePhase
    let reference: VendorReference?
    init(scope: AdapterLifecycleScope, phase: AdapterLifecyclePhase, reference: VendorReference?) throws {
        guard phase != .waitingForQuestion,
              phase != .waitingForApproval else {
            throw AdapterCandidateError.contradictoryEvent
        }
        if let reference {
            let validRole: Bool
            switch scope {
            case .session, .run: validRole = reference.role == .conversation
            case .turn: validRole = reference.role == .turn
            case .item: validRole = reference.role == .item
            }
            guard validRole else { throw AdapterCandidateError.contradictoryEvent }
        }
        self.scope = scope; self.phase = phase; self.reference = reference
    }
}

nonisolated struct CandidateAttentionEvent: Sendable {
    let scope: AdapterLifecycleScope
    let phase: AdapterLifecyclePhase
    let request: VendorReference
    let context: VendorReference?

    init(
        scope: AdapterLifecycleScope,
        phase: AdapterLifecyclePhase,
        request: VendorReference,
        context: VendorReference? = nil
    ) throws {
        guard [.waitingForQuestion, .waitingForApproval].contains(phase), request.role == .request else {
            throw AdapterCandidateError.contradictoryEvent
        }
        if let context {
            let expectedRole: VendorReference.Role = switch scope {
            case .session, .run: .conversation
            case .turn: .turn
            case .item: .item
            }
            guard context.role == expectedRole else { throw AdapterCandidateError.contradictoryEvent }
        }
        self.scope = scope
        self.phase = phase
        self.request = request
        self.context = context
    }
}

nonisolated enum AdapterCandidateEvent: Sendable {
    case lifecycle(CandidateLifecycleEvent)
    case question(CandidateAttentionEvent)
    case approval(CandidateAttentionEvent)
    case tool(CandidateToolEvent)
    case processExited(status: Int32?)

    func validate(against contract: NegotiatedAdapterContract) throws {
        let profile = contract.profile
        switch self {
        case let .lifecycle(event):
            guard event.phase != .waitingForQuestion,
                  event.phase != .waitingForApproval,
                  profile.lifecycle.authorizes(scope: event.scope, phase: event.phase) else {
                throw AdapterCandidateError.capabilityOverreach
            }
        case let .question(attention):
            guard attention.phase == .waitingForQuestion,
                  profile.lifecycle.authorizes(scope: attention.scope, phase: attention.phase) else {
                throw AdapterCandidateError.capabilityOverreach
            }
        case let .approval(attention):
            guard attention.phase == .waitingForApproval,
                  profile.lifecycle.authorizes(scope: attention.scope, phase: attention.phase) else {
                throw AdapterCandidateError.capabilityOverreach
            }
        case let .tool(event):
            guard profile.evidence.contains(.tool),
                  event.category != .fileChange || profile.evidence.contains(.fileChange),
                  event.fileChanges.isEmpty || profile.evidence.contains(.fileChange) else {
                throw AdapterCandidateError.capabilityOverreach
            }
        case .processExited:
            break // Detection hint only; never successful lifecycle completion.
        }
    }
}

nonisolated struct AdapterCandidate: Sendable {
    let event: AdapterCandidateEvent
    let timestampHint: TimestampHint?
    let sourcePosition: AdapterSourcePosition?

    init(
        event: AdapterCandidateEvent,
        timestampHint: TimestampHint? = nil,
        sourcePosition: AdapterSourcePosition? = nil
    ) {
        self.event = event
        self.timestampHint = timestampHint
        self.sourcePosition = sourcePosition
    }

    func validate(against contract: NegotiatedAdapterContract) throws {
        try event.validate(against: contract)
        let delivery = contract.profile.delivery
        if delivery.replay == .sourceCursor {
            guard sourcePosition?.sourceEvent != nil, sourcePosition?.resumePosition != nil,
                  sourcePosition?.sourceSequence != nil else {
                throw AdapterCandidateError.incompleteReplayPosition
            }
        } else if sourcePosition?.sourceEvent != nil || sourcePosition?.resumePosition != nil {
            throw AdapterCandidateError.forbiddenReplayPosition
        }
        if delivery.ordering == .ordered, sourcePosition?.sourceSequence == nil {
            throw AdapterCandidateError.missingSourceSequence
        }
        if delivery.ordering == .unordered, sourcePosition?.sourceSequence != nil {
            throw AdapterCandidateError.forbiddenSourceSequence
        }
    }
}

nonisolated struct AdapterSourcePosition: Sendable {
    let sourceEvent: VendorReference?
    let resumePosition: AdapterResumePosition?
    let sourceSequence: UInt64?

    init(
        sourceEvent: VendorReference? = nil,
        resumePosition: AdapterResumePosition? = nil,
        sourceSequence: UInt64? = nil
    ) throws {
        guard sourceEvent.map({ $0.role == .event }) ?? true,
              sourceSequence.map({ $0 > 0 }) ?? true else {
            throw AdapterCandidateError.invalidSourcePosition
        }
        self.sourceEvent = sourceEvent
        self.resumePosition = resumePosition
        self.sourceSequence = sourceSequence
    }
}

nonisolated struct TimestampHint: Sendable {
    let secondsSince1970: Double
    let durationMilliseconds: UInt32?
    init(secondsSince1970: Double, durationMilliseconds: UInt32?) throws {
        guard secondsSince1970.isFinite, secondsSince1970 >= 0, secondsSince1970 <= 32_503_680_000 else {
            throw AdapterCandidateError.invalidTimestamp
        }
        guard durationMilliseconds.map({ $0 <= 86_400_000 }) ?? true else {
            throw AdapterCandidateError.invalidTimestamp
        }
        self.secondsSince1970 = secondsSince1970; self.durationMilliseconds = durationMilliseconds
    }
}

nonisolated enum AdapterCandidateError: Error, Equatable, Sendable {
    case invalidRelativePath, invalidContentIdentity, contradictoryEvent, invalidTimestamp, capabilityOverreach
    case invalidSourcePosition, incompleteReplayPosition, forbiddenReplayPosition, missingSourceSequence
    case forbiddenSourceSequence
}
