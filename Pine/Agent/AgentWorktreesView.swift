//
//  AgentWorktreesView.swift
//  Pine
//
//  The sheet behind Agent ▸ Manage Agent Worktrees (#1524). Lists the git
//  worktrees Pine created for agent tasks in this window — plus the ones a
//  project close dropped from the record while their directories stayed on
//  disk, rebuilt by discovery (#1563) — with the branch and the working-tree
//  state of each, and offers the two things the app could previously only do
//  to itself: merge one back, or delete it.
//

import AppKit
import SwiftUI

/// Value-type projection of one row, so the list renders without a live model
/// and can be exercised from a preview or a snapshot.
struct AgentWorktreeRowPresentation: Identifiable, Equatable {
    let id: URL
    let branch: String
    let projectName: String
    let path: String
    let status: AgentWorktreeRowStatus

    init(row: AgentWorktreeRow, projectName: String) {
        id = row.id
        branch = row.worktree.branchName
        self.projectName = projectName
        path = row.worktree.worktreeRoot.path
        status = row.status
    }

    /// Removal is offered for every row. A worktree Pine cannot inspect is
    /// exactly the one the user most needs to be able to reclaim, and the
    /// service still fails closed on anything outside the managed folder.
    var canRemove: Bool { true }

    /// Merging needs a readable, clean source. Offering it on a tree git could
    /// not read would only produce an alert saying so.
    var canIntegrate: Bool {
        switch status {
        case .clean: return true
        case .checking, .dirty, .unavailable: return false
        }
    }
}

struct AgentWorktreesView: View {
    @Environment(\.locale) private var locale
    let session: ProjectWindowSession
    let registry: ProjectRegistry
    @Binding var isPresented: Bool
    @State private var model: AgentWorktreeManagerModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let model, let message = model.message {
                Divider()
                banner(message)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .task {
            let model = model ?? makeModel()
            self.model = model
            model.beginListing()
            await model.refresh(await session.worktreeManagerListing())
        }
        .alert(
            Strings.agentWorktreesRemoveTitle,
            isPresented: removalBinding,
            presenting: model?.removalPrompt
        ) { prompt in
            Button(Strings.dialogCancel, role: .cancel) {
                model?.cancelRemoval()
            }
            Button(
                Strings.agentWorktreesRemoveConfirm,
                role: .destructive
            ) {
                Task { @MainActor in await model?.confirmRemoval() }
            }
            .accessibilityIdentifier(
                AccessibilityID.agentWorktreesConfirmRemove
            )
            Button(Strings.contextRevealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [prompt.worktree.worktreeRoot]
                )
            }
        } message: { prompt in
            Text(verbatim: AgentWorktreeManagerModel.removalMessage(
                for: prompt,
                locale: locale
            ))
        }
        .alert(
            Strings.agentWorktreesIntegrateTitle,
            isPresented: integrationBinding,
            presenting: model?.integrationPreview
        ) { _ in
            Button(Strings.dialogCancel, role: .cancel) {
                model?.cancelIntegration()
            }
            if model?.canConfirmIntegration == true {
                Button(Strings.agentWorktreesIntegrateConfirm) {
                    Task { @MainActor in await model?.confirmIntegration() }
                }
                .accessibilityIdentifier(
                    AccessibilityID.agentWorktreesConfirmIntegrate
                )
            }
        } message: { preview in
            Text(verbatim: AgentWorktreeManagerModel.integrationMessage(
                for: preview,
                locale: locale
            ))
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text(Strings.agentWorktreesTitle)
                .font(.headline)
            Spacer()
            if model?.isBusy == true {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(
                Text(verbatim: AgentReadOnlySheetChrome.closeLabel(
                    locale: locale
                ))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let presentations = rowPresentations
        if presentations.isEmpty {
            if model?.isListing == true {
                // Discovery is still reading the repository (#1563): show
                // work in progress, not an empty list that would be a lie
                // for as long as the git call runs.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: MenuIcons.agentWorktrees)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(Strings.agentWorktreesEmptyTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(Strings.agentWorktreesEmptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentations) { presentation in
                        row(presentation)
                        if presentation.id != presentations.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ presentation: AgentWorktreeRowPresentation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: presentation.branch)
                        .font(.system(size: 13, weight: .semibold))
                    statusBadge(presentation.status)
                }
                Text(verbatim: "\(presentation.projectName) — \(presentation.path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: presentation.path))
            }

            Spacer()

            Button {
                guard let worktree = worktree(for: presentation.id) else {
                    return
                }
                Task { @MainActor in
                    await model?.prepareIntegration(worktree)
                }
            } label: {
                Text(Strings.agentWorktreesIntegrate)
            }
            .controlSize(.small)
            .disabled(!presentation.canIntegrate || model?.isBusy == true)
            .accessibilityIdentifier(
                AccessibilityID.agentWorktreesIntegrate(presentation.branch)
            )

            Button {
                guard let worktree = worktree(for: presentation.id) else {
                    return
                }
                Task { @MainActor in
                    await model?.prepareRemoval(worktree)
                }
            } label: {
                Text(Strings.agentWorktreesRemove)
            }
            .controlSize(.small)
            .disabled(model?.isBusy == true)
            .accessibilityIdentifier(
                AccessibilityID.agentWorktreesRemove(presentation.branch)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusBadge(_ status: AgentWorktreeRowStatus) -> some View {
        switch status {
        case .checking:
            Text(Strings.agentWorktreesStatusChecking)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .clean:
            Text(Strings.agentWorktreesStatusClean)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .dirty(let paths):
            Label {
                Text(verbatim: Strings.agentWorktreesDirtyCountText(
                    paths.count,
                    locale: locale
                ))
            } icon: {
                Image(systemName: "pencil.circle.fill")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
        case .unavailable:
            Label {
                Text(Strings.agentWorktreesStatusUnavailable)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private func banner(_ message: AgentWorktreeManagerMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: bannerSymbol(message))
                .foregroundStyle(bannerTint(message))
            Text(verbatim: AgentWorktreeManagerModel.text(
                for: message,
                locale: locale
            ))
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model?.dismissMessage()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                Text(verbatim: AgentReadOnlySheetChrome.closeLabel(
                    locale: locale
                ))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.agentWorktreesBanner)
    }

    private func bannerSymbol(
        _ message: AgentWorktreeManagerMessage
    ) -> String {
        switch message {
        case .removed, .integrated: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func bannerTint(
        _ message: AgentWorktreeManagerMessage
    ) -> Color {
        switch message {
        case .removed, .integrated: return .green
        case .failure: return .orange
        }
    }

    // MARK: - Plumbing

    private var rowPresentations: [AgentWorktreeRowPresentation] {
        (model?.rows ?? []).map { row in
            AgentWorktreeRowPresentation(
                row: row,
                projectName: session.displayName(for: row.worktree.repositoryRoot)
            )
        }
    }

    private func worktree(for root: URL) -> AgentManagedWorktree? {
        model?.rows.first { $0.id == root }?.worktree
    }

    private func makeModel() -> AgentWorktreeManagerModel {
        AgentWorktreeManagerModel(
            service: session.agentWorktreeManager,
            onRemoved: { [session, registry] worktree in
                await session.forgetWorktree(worktree, registry: registry)
            }
        )
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { model?.removalPrompt != nil },
            set: { isShown in
                if !isShown { model?.cancelRemoval() }
            }
        )
    }

    private var integrationBinding: Binding<Bool> {
        Binding(
            get: { model?.integrationPreview != nil },
            set: { isShown in
                if !isShown { model?.cancelIntegration() }
            }
        )
    }
}
