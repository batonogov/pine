//
//  AgentTaskPersistenceStatusView.swift
//  Pine
//
//  Explicit task-history recovery without starting or resuming an agent.
//

import SwiftUI

struct AgentTaskPersistenceStatusView: View {
    let registry: AgentTaskRegistry
    let project: AgentTaskProjectIdentity

    private var rejection: AgentTaskMetadataRejection? {
        if case .rejected(let reason) = registry.loadStatusByProject[project.persistenceKey] {
            return reason
        }
        if case .rejected(let reason) = registry.saveResultByProject[project.persistenceKey] {
            return reason
        }
        return nil
    }

    private var detail: LocalizedStringKey {
        switch rejection {
        case .lockContention: Strings.agentMetadataLocked
        case .transientIO, .ioFailure, .durabilityUnknown, nil: Strings.agentMetadataIOFailure
        case .unknownSchema: Strings.agentMetadataFutureSchema
        default: Strings.agentMetadataProtected
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Strings.agentMetadataUnavailable, systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
            Text(URL(fileURLWithPath: project.canonicalProjectPath).lastPathComponent)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if registry.metadataRecoveryProjects.contains(project) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Strings.agentMetadataRetry)
            } else if registry.canRetryMetadataPersistence(project) {
                Button(Strings.agentMetadataRetry) {
                    Task { await registry.retryMetadataPersistence(project) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentTask.persistenceStatus")
    }
}
