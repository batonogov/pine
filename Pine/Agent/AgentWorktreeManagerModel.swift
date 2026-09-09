//
//  AgentWorktreeManagerModel.swift
//  Pine
//
//  User-facing lifecycle for the git worktrees Pine creates on the user's
//  behalf (#1524). `AgentWorktreeService` already implemented inspection,
//  removal, integration preview and integration; until now none of it had a
//  production caller, so worktrees and branches accumulated silently. This is
//  the state machine that turns those four primitives into something a person
//  can see and answer.
//

import Foundation
import Observation

/// What ``AgentWorktreeManagerModel`` needs from the git-facing service.
///
/// ``AgentWorktreeService`` is the production conformance. The protocol exists
/// so the state machine can be tested against scripted results — every
/// alternative would mean building throwaway repositories for cases like "the
/// worktree became dirty between the alert and the answer", which is a race,
/// not a fixture.
nonisolated protocol AgentWorktreeManaging: Sendable {
    func inspectRemoval(
        _ worktree: AgentManagedWorktree
    ) async -> Result<
        AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure
    >

    func remove(
        _ worktree: AgentManagedWorktree,
        confirmation: AgentWorktreeRemovalConfirmation?
    ) async -> AgentWorktreeRemovalResult

    func previewIntegration(
        _ worktree: AgentManagedWorktree,
        previewID: UUID
    ) async -> AgentWorktreeIntegrationPreviewResult

    func integrate(
        _ preview: AgentWorktreeIntegrationPreview,
        confirmation: AgentWorktreeIntegrationConfirmation
    ) async -> AgentWorktreeIntegrationResult
}

extension AgentWorktreeService: AgentWorktreeManaging {}

/// Working-tree state of one row, as the list shows it.
nonisolated enum AgentWorktreeRowStatus: Equatable, Sendable {
    case checking
    case clean
    case dirty([String])
    /// Git could not be asked, or the directory is no longer where Pine put
    /// it. Shown rather than hidden: a row the app cannot vouch for is still a
    /// row the user may need to reclaim.
    case unavailable
}

nonisolated struct AgentWorktreeRow: Identifiable, Equatable, Sendable {
    let worktree: AgentManagedWorktree
    var status: AgentWorktreeRowStatus

    var id: URL { worktree.worktreeRoot }
}

/// Exactly what a destructive-removal confirmation has to disclose before the
/// user can answer it: the directory that disappears, and every uncommitted
/// path inside it.
///
/// Built from a *fresh* ``AgentWorktreeManaging/inspectRemoval(_:)`` rather
/// than from the list's cached status, so the paths on screen are the paths
/// the service will demand back in the confirmation.
nonisolated struct AgentWorktreeRemovalPrompt: Identifiable, Equatable,
    Sendable {
    let worktree: AgentManagedWorktree
    let dirtyPaths: [String]

    var id: URL { worktree.worktreeRoot }
    var destroysUncommittedWork: Bool { !dirtyPaths.isEmpty }
}

/// Outcome banner shown under the list.
nonisolated enum AgentWorktreeManagerMessage: Equatable, Sendable {
    case removed(branch: String)
    case integrated(targetBranch: String, changedPathCount: Int)
    case failure(String)
}

/// Lists Pine-managed worktrees, and drives removal and integration through
/// the exact-consent protocol ``AgentWorktreeService`` already enforces.
///
/// The model never fabricates a confirmation: every field it hands back is
/// copied from the inspection or preview the user was shown. A mismatch is how
/// the service detects stale consent, so weakening the copy here would silently
/// convert "the repository moved under us" into a merge or a delete.
@MainActor
@Observable
final class AgentWorktreeManagerModel {
    private(set) var rows: [AgentWorktreeRow] = []
    private(set) var removalPrompt: AgentWorktreeRemovalPrompt?
    private(set) var integrationPreview: AgentWorktreeIntegrationPreview?
    /// A git mutation or inspection this model started is in flight. Also the
    /// re-entry guard: a double-clicked Remove must issue one `git worktree
    /// remove`, not two.
    private(set) var isBusy = false
    private(set) var message: AgentWorktreeManagerMessage?
    /// The listing load (#1563) is still reading the repository — the sheet
    /// shows progress, not the empty state, for its duration. Lowered only by
    /// ``refresh(_:)``, so a caller cannot forget to end it.
    private(set) var isListing = false

    @ObservationIgnored private let service: any AgentWorktreeManaging
    @ObservationIgnored
    private let onRemoved: (AgentManagedWorktree) async -> Void
    @ObservationIgnored private var refreshGeneration = 0

    /// Injected suspension inside ``refresh(_:)``, between the git inspection
    /// and the generation re-read that decides whether to apply it. No-op in
    /// production. Same shape as `ProjectManager.recoveryOfferListingSeam`:
    /// the window being protected is the one the `await` opens, and testing it
    /// with `Task.yield()` is a race, not a test.
    @ObservationIgnored
    var inspectionSeam: @Sendable () async -> Void = {}

    /// Number of dirty paths spelled out in the confirmation text before it
    /// switches to a count. The confirmation *value* always carries the full
    /// list — this caps the reading, not the consent.
    static let disclosedDirtyPathLimit = 12

    init(
        service: any AgentWorktreeManaging,
        onRemoved: @escaping (AgentManagedWorktree) async -> Void = { _ in }
    ) {
        self.service = service
        self.onRemoved = onRemoved
    }

    // MARK: - Listing

    /// Marks the listing load as started, so the sheet shows progress
    /// instead of the empty state while the repository is being read
    /// (#1563). ``refresh(_:)`` ends it together with installing the rows.
    func beginListing() {
        isListing = true
    }

    /// Replaces the list and re-reads every row's working-tree state.
    ///
    /// Rows appear immediately as ``AgentWorktreeRowStatus/checking`` so the
    /// sheet is never empty while git runs. A refresh that started earlier and
    /// finishes later is discarded by generation, not by luck.
    func refresh(_ worktrees: [AgentManagedWorktree]) async {
        isListing = false
        refreshGeneration += 1
        let generation = refreshGeneration
        rows = worktrees.map {
            AgentWorktreeRow(worktree: $0, status: .checking)
        }

        for worktree in worktrees {
            let result = await service.inspectRemoval(worktree)
            await inspectionSeam()
            guard generation == refreshGeneration else { return }
            let status: AgentWorktreeRowStatus
            switch result {
            case .success(let inspection):
                status = inspection.dirtyPaths.isEmpty
                    ? .clean
                    : .dirty(inspection.dirtyPaths)
            case .failure:
                status = .unavailable
            }
            guard let index = rows.firstIndex(where: {
                $0.id == worktree.worktreeRoot
            }) else { continue }
            rows[index].status = status
        }
    }

    // MARK: - Removal

    /// Re-inspects `worktree` and raises the destructive confirmation.
    func prepareRemoval(_ worktree: AgentManagedWorktree) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil

        switch await service.inspectRemoval(worktree) {
        case .success(let inspection):
            removalPrompt = AgentWorktreeRemovalPrompt(
                worktree: worktree,
                dirtyPaths: inspection.dirtyPaths
            )
        case .failure(let failure):
            message = .failure(Self.describe(removalFailure: failure))
        }
    }

    func cancelRemoval() {
        removalPrompt = nil
    }

    /// Answers the raised prompt affirmatively.
    ///
    /// The confirmation is forced only when the inspection actually found
    /// uncommitted work, and then it repeats that inspection's paths verbatim.
    /// A clean worktree is removed with no confirmation at all — the service
    /// rejects a confirmation it did not ask for, which is what stops a stale
    /// "yes, delete my changes" from being replayed against a different tree.
    func confirmRemoval() async {
        guard !isBusy, let prompt = removalPrompt else { return }
        isBusy = true
        defer { isBusy = false }

        let confirmation = prompt.destroysUncommittedWork
            ? AgentWorktreeRemovalConfirmation(
                worktreeRoot: prompt.worktree.worktreeRoot,
                dirtyPaths: prompt.dirtyPaths,
                acknowledgesUnrecoverableDataLoss: true
            )
            : nil

        switch await service.remove(
            prompt.worktree,
            confirmation: confirmation
        ) {
        case .removed:
            removalPrompt = nil
            rows.removeAll { $0.id == prompt.worktree.worktreeRoot }
            message = .removed(branch: prompt.worktree.branchName)
            await onRemoved(prompt.worktree)
        case .failed(.confirmationRequired(let inspection)):
            // The worktree picked up uncommitted work between the inspection
            // behind the alert and this answer. Re-ask with what is at risk
            // now; forcing the removal here would spend consent the user gave
            // for an emptier tree.
            removalPrompt = AgentWorktreeRemovalPrompt(
                worktree: prompt.worktree,
                dirtyPaths: inspection.dirtyPaths
            )
        case .failed(let failure):
            removalPrompt = nil
            message = .failure(Self.describe(removalFailure: failure))
        }
    }

    // MARK: - Integration

    /// Computes the merge preview and raises the integration confirmation.
    func prepareIntegration(_ worktree: AgentManagedWorktree) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil

        switch await service.previewIntegration(
            worktree,
            previewID: UUID()
        ) {
        case .ready(let preview):
            integrationPreview = preview
        case .failed(let failure):
            message = .failure(Self.describe(previewFailure: failure))
        }
    }

    func cancelIntegration() {
        integrationPreview = nil
    }

    /// Whether the raised preview can be merged. A preview with conflicts is
    /// still shown — the user needs to read the conflicting paths — but it is
    /// not answerable, because ``AgentWorktreeService`` refuses it anyway and
    /// an enabled button that always fails is worse than a disabled one.
    var canConfirmIntegration: Bool {
        guard let integrationPreview else { return false }
        return !integrationPreview.hasConflicts
    }

    /// Merges the previewed commit into the project's checkout, staged and
    /// uncommitted. Pine deliberately does not commit or push.
    func confirmIntegration() async {
        guard !isBusy,
              let preview = integrationPreview,
              !preview.hasConflicts else { return }
        isBusy = true
        defer { isBusy = false }

        let confirmation = AgentWorktreeIntegrationConfirmation(
            previewID: preview.id,
            sourceCommit: preview.sourceCommit,
            targetHead: preview.targetHead,
            targetBranch: preview.targetBranch,
            changedPaths: preview.changedPaths
        )

        switch await service.integrate(preview, confirmation: confirmation) {
        case .integratedWithoutCommit:
            integrationPreview = nil
            message = .integrated(
                targetBranch: preview.targetBranch,
                changedPathCount: preview.changedPaths.count
            )
        case .failed(let failure):
            integrationPreview = nil
            message = .failure(Self.describe(integrationFailure: failure))
        }
    }

    func dismissMessage() {
        message = nil
    }

    // MARK: - Presentation

    /// Body of the removal alert. Names the directory that is deleted and,
    /// when there is uncommitted work, the paths that go with it — the whole
    /// point of ``AgentWorktreeService/inspectRemoval(_:)``.
    static func removalMessage(
        for prompt: AgentWorktreeRemovalPrompt,
        locale: Locale = .current
    ) -> String {
        guard prompt.destroysUncommittedWork else {
            return Strings.agentWorktreesRemoveCleanText(
                prompt.worktree.worktreeRoot.path,
                prompt.worktree.branchName,
                locale: locale
            )
        }
        let shown = prompt.dirtyPaths.prefix(disclosedDirtyPathLimit)
        var listing = shown.map { "• \($0)" }.joined(separator: "\n")
        let remainder = prompt.dirtyPaths.count - shown.count
        if remainder > 0 {
            listing += "\n" + Strings.agentWorktreesMoreChangesText(
                remainder,
                locale: locale
            )
        }
        return Strings.agentWorktreesRemoveDirtyText(
            prompt.worktree.worktreeRoot.path,
            listing,
            locale: locale
        )
    }

    /// Body of the integration alert. Discloses the source commit, the branch
    /// being written to, and the files that move — the three facts
    /// ``AgentWorktreeIntegrationConfirmation`` is an approval of.
    static func integrationMessage(
        for preview: AgentWorktreeIntegrationPreview,
        locale: Locale = .current
    ) -> String {
        let paths = preview.hasConflicts
            ? preview.conflictingPaths
            : preview.changedPaths
        let shown = paths.prefix(disclosedDirtyPathLimit)
        var listing = shown.map { "• \($0)" }.joined(separator: "\n")
        let remainder = paths.count - shown.count
        if remainder > 0 {
            listing += "\n" + Strings.agentWorktreesMoreChangesText(
                remainder,
                locale: locale
            )
        }
        if preview.hasConflicts {
            return Strings.agentWorktreesIntegrateConflictText(
                preview.targetBranch,
                listing,
                locale: locale
            )
        }
        return Strings.agentWorktreesIntegrateText(
            String(preview.sourceCommit.prefix(7)),
            preview.targetBranch,
            listing,
            locale: locale
        )
    }

    /// Banner text for one outcome.
    static func text(
        for message: AgentWorktreeManagerMessage,
        locale: Locale = .current
    ) -> String {
        switch message {
        case .removed:
            return Strings.agentWorktreesRemovedText(locale: locale)
        case .integrated(let targetBranch, let changedPathCount):
            return Strings.agentWorktreesIntegratedText(
                targetBranch,
                changedPathCount,
                locale: locale
            )
        case .failure(let reason):
            return reason
        }
    }

    // MARK: - Failure text

    static func describe(
        removalFailure: AgentWorktreeRemovalFailure,
        locale: Locale = .current
    ) -> String {
        switch removalFailure {
        case .unsafeWorktree:
            return Strings.agentWorktreesUnsafeText(locale: locale)
        case .inspectionFailed:
            return Strings.agentWorktreesInspectFailedText(locale: locale)
        case .confirmationRequired, .confirmationMismatch:
            return Strings.agentWorktreesChangedText(locale: locale)
        case .gitRejected(let reason):
            return Strings.agentWorktreesGenericText(reason, locale: locale)
        case .removalInterrupted(let root):
            return Strings.agentWorktreesGenericText(
                root.path,
                locale: locale
            )
        }
    }

    static func describe(
        previewFailure: AgentWorktreeIntegrationPreviewFailure,
        locale: Locale = .current
    ) -> String {
        switch previewFailure {
        case .unsafeWorktree:
            return Strings.agentWorktreesUnsafeText(locale: locale)
        case .sourceBranchChanged:
            return Strings.agentWorktreesChangedText(locale: locale)
        case .sourceWorktreeDirty:
            return Strings.agentWorktreesSourceDirtyText(locale: locale)
        case .targetSnapshotUnavailable:
            return Strings.agentWorktreesInspectFailedText(locale: locale)
        case .targetDetached:
            return Strings.agentWorktreesTargetDetachedText(locale: locale)
        case .targetCheckoutDirty:
            return Strings.agentWorktreesTargetDirtyText(locale: locale)
        case .noChanges:
            return Strings.agentWorktreesNoChangesText(locale: locale)
        case .gitRejected(let reason):
            return Strings.agentWorktreesGenericText(reason, locale: locale)
        }
    }

    static func describe(
        integrationFailure: AgentWorktreeIntegrationFailure,
        locale: Locale = .current
    ) -> String {
        switch integrationFailure {
        case .confirmationMismatch, .sourceChanged, .targetChanged:
            return Strings.agentWorktreesChangedText(locale: locale)
        case .conflictsRequireResolution:
            return Strings.agentWorktreesConflictsText(locale: locale)
        case .integrationInterrupted(let root):
            return Strings.agentWorktreesGenericText(
                root.path,
                locale: locale
            )
        case .manualRecoveryRequired(let reason):
            return Strings.agentWorktreesManualRecoveryText(
                reason,
                locale: locale
            )
        }
    }
}
