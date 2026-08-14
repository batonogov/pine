//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import AppKit
import Darwin
import os
import SwiftUI

nonisolated struct TerminationFileAliasIdentity: Hashable, Sendable {
    private enum Storage: Hashable, Sendable {
        case existing(device: dev_t, inode: ino_t)
        case missing(
            ancestorDevice: dev_t,
            ancestorInode: ino_t,
            normalizedSuffix: [String]
        )
    }

    private let storage: Storage

    fileprivate static func existing(
        device: dev_t,
        inode: ino_t
    ) -> Self {
        Self(storage: .existing(device: device, inode: inode))
    }

    fileprivate static func missing(
        ancestorDevice: dev_t,
        ancestorInode: ino_t,
        normalizedSuffix: [String]
    ) -> Self {
        Self(storage: .missing(
            ancestorDevice: ancestorDevice,
            ancestorInode: ancestorInode,
            normalizedSuffix: normalizedSuffix
        ))
    }
}

nonisolated enum TerminationFileAliasCaptureResult: Sendable {
    case captured([TerminationFileAliasIdentity])
    case failed(message: String)
    case timedOut
}

nonisolated private final class TerminationFileAliasCaptureResolver:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        TerminationFileAliasCaptureResult,
        Never
    >?

    init(
        _ continuation: CheckedContinuation<
            TerminationFileAliasCaptureResult,
            Never
        >
    ) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: TerminationFileAliasCaptureResult) -> Bool {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: result)
        return true
    }
}

/// Resolves filesystem aliases away from the main actor. Existing paths use
/// their device/inode identity, so hard links, symlinks, and case aliases
/// compare equal. Missing paths are keyed below their nearest existing
/// ancestor using the volume's case behavior and canonical Unicode spelling.
nonisolated enum TerminationFileAliasResolver {
    private static let workQueue = DispatchQueue(
        label: "com.pine.termination-file-alias",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let deadlineQueue = DispatchQueue(
        label: "com.pine.termination-file-alias-deadline",
        qos: .userInteractive
    )

    static func capture(
        _ urls: [URL],
        until deadline: DispatchTime
    ) async -> TerminationFileAliasCaptureResult {
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds else {
            return .timedOut
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationFileAliasCaptureResolver(continuation)
            workQueue.async {
                let result: TerminationFileAliasCaptureResult
                do {
                    let identities = try urls.map {
                        try identity(
                            at: $0,
                            deadlineNanoseconds: deadline.uptimeNanoseconds
                        )
                    }
                    result = .captured(identities)
                } catch let error as TerminationFileAliasError
                where error == .timedOut {
                    result = .timedOut
                } catch {
                    result = .failed(message: error.localizedDescription)
                }
                resolver.resolve(result)
            }
            deadlineQueue.asyncAfter(deadline: deadline) {
                resolver.resolve(.timedOut)
            }
        }
    }

    private enum TerminationFileAliasError: Error {
        case timedOut
    }

    private static func identity(
        at originalURL: URL,
        deadlineNanoseconds: UInt64
    ) throws -> TerminationFileAliasIdentity {
        try checkDeadline(deadlineNanoseconds)
        var currentURL = originalURL.standardizedFileURL
        var missingComponents: [String] = []

        while true {
            try checkDeadline(deadlineNanoseconds)
            var status = stat()
            let descriptor = Darwin.open(
                currentURL.path,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC
            )
            if descriptor >= 0 {
                defer { Darwin.close(descriptor) }
                guard Darwin.fstat(descriptor, &status) == 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno)
                    )
                }
                if missingComponents.isEmpty {
                    return .existing(
                        device: status.st_dev,
                        inode: status.st_ino
                    )
                }
                let resourceValues = try currentURL.resourceValues(
                    forKeys: [.volumeSupportsCaseSensitiveNamesKey]
                )
                guard let isCaseSensitive = resourceValues
                    .volumeSupportsCaseSensitiveNames else {
                    throw CocoaError(.fileReadUnknown)
                }
                let suffix = missingComponents.reversed().map {
                    normalize($0, caseSensitive: isCaseSensitive)
                }
                return .missing(
                    ancestorDevice: status.st_dev,
                    ancestorInode: status.st_ino,
                    normalizedSuffix: suffix
                )
            }
            guard errno == ENOENT else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            missingComponents.append(currentURL.lastPathComponent)
            currentURL = parentURL
        }
    }

    private static func normalize(
        _ component: String,
        caseSensitive: Bool
    ) -> String {
        let canonical = component.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return canonical }
        return canonical.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func checkDeadline(_ deadlineNanoseconds: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            throw TerminationFileAliasError.timedOut
        }
    }
}

nonisolated enum PreparedPaneSaveCommitResult: Sendable, Equatable {
    case saved
    case invalidated
    case timedOut
    case failed(message: String, retainedArtifacts: [URL])
}

nonisolated enum TerminationPaneSaveStageResult: Sendable {
    case ready
    case invalidated
    case failed(message: String, retainedArtifacts: [URL])
    case timedOut
}

nonisolated private final class TerminationAwaitResolver<Result: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?

    init(_ continuation: CheckedContinuation<Result, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result) -> Bool {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: result)
        return true
    }
}

/// Thin coordinator that owns the workspace, terminal, and tab managers.
/// Passed via environment so views can access all sub-managers.
@MainActor
private final class RetiredDialogOwnerWindow {
    weak var window: NSWindow?
    let generation: UUID

    init(window: NSWindow, generation: UUID) {
        self.window = window
        self.generation = generation
    }
}

@MainActor
@Observable
final class ProjectManager {
    enum PresentationLifecycle: Equatable {
        case visible
        case backgroundSuspended
        case destroyed
    }

    private static let terminationInstallDeadlineQueue = DispatchQueue(
        label: "com.pine.project.termination-install-deadline",
        qos: .userInteractive
    )
    typealias SaveDestinationChooser = @MainActor (
        _ tab: EditorTab,
        _ projectRoot: URL?,
        _ context: DialogPresentationContext
    ) async -> URL?
    typealias OpenFileChooser = @MainActor (
        _ projectRoot: URL?,
        _ context: DialogPresentationContext
    ) async -> URL?

    fileprivate struct PlannedTabSave {
        let tabManager: TabManager
        let tab: EditorTab
        var destination: URL?
    }

    struct TerminationOpenTabInventory: Equatable {
        fileprivate struct Entry: Hashable {
            let tabManager: ObjectIdentifier
            let tabID: UUID
            let originalFileURL: URL?
            let authorizedSaveAsURL: URL?

            func authorizes(_ tab: EditorTab) -> Bool {
                let liveURL = tab.fileURL?.standardizedFileURL
                return liveURL == originalFileURL
                    || liveURL == authorizedSaveAsURL
            }
        }

        fileprivate let tabManagers: Set<ObjectIdentifier>
        fileprivate let entries: Set<Entry>
    }

    struct PreparedPaneSavePlan {
        fileprivate let entries: [PlannedTabSave]
        fileprivate let dirtyAuthorization: DirtyEditorContentAuthorization

        var standardizedDestinationURLs: [URL] {
            entries.compactMap { planned in
                (planned.destination ?? planned.tab.fileURL)?
                    .standardizedFileURL
            }
        }

        var plannedTabIDs: Set<UUID> {
            Set(entries.map(\.tab.id))
        }

        var plannedDestinationURLsByTabID: [UUID: URL] {
            Dictionary(uniqueKeysWithValues: entries.compactMap { planned in
                guard let destination = planned.destination else {
                    return nil
                }
                return (planned.tab.id, destination.standardizedFileURL)
            })
        }
    }

    struct PreparedTerminationPaneSavePlan {
        fileprivate let source: PreparedPaneSavePlan
        fileprivate let staged: [TerminationStagedSave]
    }

    enum PaneSavePreparationResult {
        case ready(PreparedPaneSavePlan)
        case cancelledByUser
        case invalidated
    }

    let workspace: WorkspaceManager
    let terminal: TerminalManager
    /// Structured agent-action feed for the Activity Panel (vision #933,
    /// Phase 2 — Visibility, issue #1072).
    let agentActivity = AgentActivityStore()
    /// Persistent, review-only history of observed finished-agent activity
    /// (vision #933, Phase 2 — Visibility, issues #1073 and #1183).
    let agentHistory = AgentHistoryStore()
    /// The primary TabManager (initial root editor pane). Project-scoped
    /// services are wired to every pane-owned manager by `PaneManager`'s
    /// configurator. For the *focused* pane's TabManager, use
    /// ``activeTabManager`` which delegates to ``PaneManager/activeEditorTabManager``.
    ///
    /// Note: this instance can become an *orphan* — i.e. no pane in the
    /// `PaneManager` tree references it — after `pruneEmptyEditorLeaves`
    /// removes the root editor pane (terminals-only layout) or after a
    /// session restore that does not bind it to any leaf. In that state it
    /// is harmless: it holds no tabs, contributes nothing to `allTabs`, and
    /// is recreated as a leaf-bound TabManager via `ensureEditorPane()`
    /// when the user opens a file again. The reference remains as the stable
    /// fallback used by project-level commands while no editor pane exists.
    let primaryTabManager = TabManager()
    let searchProvider = ProjectSearchProvider()
    let quickOpenProvider = QuickOpenProvider()
    let progress = ProgressTracker()
    let contextFileWriter: ContextFileWriter
    /// Language Server Protocol manager — owns per-language server processes
    /// and aggregates diagnostics (#1010, parent #994). Spawned lazily on the
    /// first open of a matching file; shut down on project close / app quit.
    let lspManager: LSPManager
    /// Project-scoped diagnostics aggregate for the Problems panel (#1236).
    /// Merges LSP diagnostics (read live) with config-validator diagnostics
    /// (revision-guarded). Owned here so every window observes the same truth.
    let problemsController: ProblemsPanelController
    /// Weak anchor for every native dialog owned by this project.
    ///
    /// The window owns the visible project surface; keeping this reference
    /// weak prevents the project model (which may remain alive in the
    /// background) from extending the NSWindow lifetime.
    @ObservationIgnored
    private(set) weak var dialogOwnerWindow: NSWindow?
    @ObservationIgnored
    private(set) var dialogOwnerWindowGeneration = UUID()
    @ObservationIgnored
    private var retiredDialogOwnerWindows: [RetiredDialogOwnerWindow] = []
    @ObservationIgnored
    private var completedDialogOwnerWindow: RetiredDialogOwnerWindow?
    @ObservationIgnored
    private var dialogOperationTail: Task<Void, Never>?
    @ObservationIgnored
    private var dialogOperationGeneration = 0
    @ObservationIgnored
    private var isAutoSaveFrozenForTermination = false
    @ObservationIgnored
    private(set) lazy var paneManager = PaneManager(existingTabManager: primaryTabManager)
    /// Test seam and single native Save-panel implementation for Save,
    /// Save As, Save All, close-window, and Quit paths.
    @ObservationIgnored
    var saveDestinationChooser: SaveDestinationChooser = { tab, projectRoot, context in
        let panel = NSSavePanel()
        panel.title = Strings.saveAsPanelTitle
        panel.nameFieldStringValue = tab.fileName
        panel.directoryURL = tab.fileURL?.deletingLastPathComponent()
            ?? projectRoot
        guard await panel.runSheet(on: context) == .OK else {
            return nil
        }
        return panel.url
    }
    @ObservationIgnored
    var openFileChooser: OpenFileChooser = { projectRoot, context in
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectRoot
        panel.message = Strings.openFilePanelMessage
        panel.prompt = Strings.openFilePanelPrompt
        guard await panel.runSheet(on: context) == .OK else {
            return nil
        }
        return panel.url
    }
    @ObservationIgnored
    var terminationSaveInstaller: @Sendable (
        TerminationStagedSave,
        DispatchTime,
        @escaping @Sendable (TerminationSaveInstallResult) -> Void
    ) async -> TerminationSaveInstallResult = { staged, deadline, lateCompletion in
        await TerminationSaveCoordinator.install(
            staged,
            until: deadline,
            lateCompletion: lateCompletion
        )
    }
    @ObservationIgnored
    var terminationSaveCleaner: @Sendable (
        [TerminationStagedSave]
    ) -> TerminationSaveCleanupResult = {
        TerminationSaveCoordinator.cleanup($0)
    }
    @ObservationIgnored
    var terminationSaveLateFailureHandler: @Sendable (
        String,
        [URL]
    ) -> Void = { message, retainedArtifacts in
        let paths = retainedArtifacts.map(\.path).joined(separator: ",")
        Logger.app.error(
            "Late termination save failure: \(message, privacy: .public); retained=\(paths, privacy: .public)"
        )
    }

    /// Returns the TabManager for the currently focused pane.
    /// Falls back to the primary ``primaryTabManager`` when no editor pane is active.
    var activeTabManager: TabManager {
        paneManager.activeEditorTabManager ?? primaryTabManager
    }

    /// Collects all tabs from every pane (for session save, dirty-tab checks, etc.).
    var allTabs: [EditorTab] {
        paneManager.tabManagers.values.flatMap(\.tabs)
    }

    /// Whether any tab in any pane has unsaved changes.
    var hasUnsavedChanges: Bool {
        paneManager.tabManagers.values.contains { $0.hasUnsavedChanges }
    }

    /// All dirty tabs across all panes.
    var allDirtyTabs: [EditorTab] {
        paneManager.tabManagers.values.flatMap(\.dirtyTabs)
    }

    func captureTerminationOpenTabInventory(
        allowingSaveAs destinationsByTabID: [UUID: URL]
    ) -> TerminationOpenTabInventory {
        let tabManagers = paneManager.allTabManagers
        return TerminationOpenTabInventory(
            tabManagers: Set(tabManagers.map(ObjectIdentifier.init)),
            entries: Set(tabManagers.flatMap { tabManager in
                tabManager.tabs.map { tab in
                    TerminationOpenTabInventory.Entry(
                        tabManager: ObjectIdentifier(tabManager),
                        tabID: tab.id,
                        originalFileURL: tab.fileURL?.standardizedFileURL,
                        authorizedSaveAsURL:
                            destinationsByTabID[tab.id]?.standardizedFileURL
                    )
                }
            })
        )
    }

    func terminationOpenTabInventoryStillMatches(
        _ inventory: TerminationOpenTabInventory
    ) -> Bool {
        let tabManagers = paneManager.allTabManagers
        guard Set(tabManagers.map(ObjectIdentifier.init))
                == inventory.tabManagers else {
            return false
        }
        let liveTabs = tabManagers.flatMap { tabManager in
            tabManager.tabs.map { (ObjectIdentifier(tabManager), $0) }
        }
        guard liveTabs.count == inventory.entries.count else { return false }
        return liveTabs.allSatisfy { tabManagerID, tab in
            inventory.entries.contains { entry in
                entry.tabManager == tabManagerID
                    && entry.tabID == tab.id
                    && entry.authorizes(tab)
            }
        }
    }

    func freezeAutoSaveForTermination() {
        guard !isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = true
        paneManager.allTabManagers.forEach {
            $0.freezeAutoSaveForTermination()
        }
    }

    func cancelAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        paneManager.allTabManagers.forEach {
            $0.cancelAutoSaveTerminationFreeze()
        }
    }

    func finishAutoSaveTerminationFreeze() {
        guard isAutoSaveFrozenForTermination else { return }
        isAutoSaveFrozenForTermination = false
        paneManager.allTabManagers.forEach {
            $0.finishAutoSaveTerminationFreeze()
        }
    }

    /// Validates an exact dirty-buffer authorization across every editor
    /// pane. This is intentionally separate from commit so Quit can validate
    /// every project before mutating any project.
    func canCommitDiscard(
        _ authorization: DirtyEditorContentAuthorization
    ) -> Bool {
        authorization.covers(allDirtyTabs)
    }

    /// Commits an already validated "Don't Save" decision across panes.
    /// There is no suspension between the project-level validation and these
    /// per-manager commits, so another MainActor mutation cannot interleave.
    @discardableResult
    func commitDiscard(
        _ authorization: DirtyEditorContentAuthorization,
        postReloadNotifications: Bool = true
    ) -> Bool {
        guard canCommitDiscard(authorization) else { return false }
        let reloads = allDirtyTabs.map {
            ReloadedTab(url: $0.url, text: $0.savedContent)
        }
        for tabManager in paneManager.allTabManagers {
            guard tabManager.discardChanges(
                authorizedBy: authorization,
                postReloads: false
            ) else {
                return false
            }
        }
        if postReloadNotifications {
            for reload in reloads {
                NotificationCenter.default.post(
                    name: .tabReloadedFromDisk,
                    object: nil,
                    userInfo: ["url": reload.url, "text": reload.text]
                )
            }
        }
        return true
    }

    /// Saves all tabs across all panes. Returns false if any save fails.
    @discardableResult
    func saveAllPaneTabs() -> Bool {
        let tabManagers = paneManager.allTabManagers
        let dirtyTabs = tabManagers.flatMap(\.dirtyTabs)
        guard dirtyTabs.allSatisfy({
            $0.kind == .text
                && !$0.isTruncated
                && $0.fileURL != nil
        }) else {
            return false
        }
        for tabMgr in tabManagers {
            guard tabMgr.saveAllTabs() else { return false }
        }
        return true
    }

    /// Collects all human Save-As decisions without writing any file. Quit
    /// performs this phase before starting its bounded machine-work clock.
    func prepareSaveAllPaneTabs(
        context: DialogPresentationContext
    ) async -> PaneSavePreparationResult {
        let dirtyAuthorization = DirtyEditorContentAuthorization(
            tabs: allDirtyTabs
        )
        var savePlan = paneManager.allTabManagers.flatMap { tabManager in
            tabManager.tabs.compactMap { tab -> PlannedTabSave? in
                guard tab.isDirty else { return nil }
                return PlannedTabSave(
                    tabManager: tabManager,
                    tab: tab,
                    destination: nil
                )
            }
        }
        // Preflight every known-unsavable tab before the first write. Without
        // this guard, a valid pane could be written before a later truncated
        // buffer rejects Save All, leaving the project partially saved.
        guard savePlan.allSatisfy({
            $0.tab.kind == .text && !$0.tab.isTruncated
        }) else {
            return .invalidated
        }

        // Collect every untitled destination before the first disk write.
        // Cancelling any later Save panel must leave earlier buffers dirty
        // instead of producing a partially saved project.
        for index in savePlan.indices
        where savePlan[index].tab.fileURL == nil {
            guard let destination = await saveDestinationChooser(
                savePlan[index].tab,
                workspace.rootURL,
                context
            ) else {
                return .cancelledByUser
            }
            savePlan[index].destination = destination
        }

        // A panel may suspend long enough for a tab to close, become saved,
        // change backing, or become truncated. Revalidate every captured
        // identity before committing any member of the plan.
        guard dirtyAuthorization.covers(allDirtyTabs),
              savePlan.allSatisfy({ planned in
            guard let current = planned.tabManager.tabs.first(where: {
                $0.id == planned.tab.id
            }) else {
                return false
            }
            return current.isDirty
                && current.kind == .text
                && !current.isTruncated
                && current.fileURL == planned.tab.fileURL
                && current.content == planned.tab.content
        }) else {
            return .invalidated
        }

        let effectiveDestinations = savePlan.compactMap { planned in
            (planned.destination ?? planned.tab.fileURL)?
                .standardizedFileURL
        }
        guard effectiveDestinations.count == savePlan.count,
              Set(effectiveDestinations).count
                == effectiveDestinations.count else {
            return .invalidated
        }

        // An untitled Save-As target must not alias a file already open in
        // another tab, even when that other tab is clean and therefore absent
        // from the plan. Otherwise Save All could create two clean buffers for
        // one backing file, with only the last write matching disk.
        let plannedTabIDs = Set(savePlan.map(\.tab.id))
        let unplannedOpenDestinations = Set(
            allTabs.compactMap { tab -> URL? in
                guard !plannedTabIDs.contains(tab.id) else { return nil }
                return tab.fileURL?.standardizedFileURL
            }
        )
        let newDestinations = savePlan.compactMap(\.destination).map {
            $0.standardizedFileURL
        }
        guard newDestinations.allSatisfy({
            !unplannedOpenDestinations.contains($0)
        }) else {
            return .invalidated
        }

        return .ready(PreparedPaneSavePlan(
            entries: savePlan,
            dirtyAuthorization: dirtyAuthorization
        ))
    }

    /// Commits an already prepared Save All plan without presenting UI. Slow
    /// save preparation suspends off-main; every captured tab revision is
    /// revalidated again before its write.
    func commitPreparedSaveAllPaneTabs(
        _ plan: PreparedPaneSavePlan
    ) async -> PreparedPaneSaveCommitResult {
        guard preparedSavePlanStillValid(plan) else {
            return .invalidated
        }
        for planned in plan.entries {
            planned.tabManager.cancelAutoSave()
        }

        for planned in plan.entries {
            do {
                guard try await planned.tabManager.trySaveTabAsync(
                    snapshot: planned.tab,
                    saveAsDestination: planned.destination
                ) else {
                    return .invalidated
                }
            } catch {
                return .failed(
                    message: error.localizedDescription,
                    retainedArtifacts: []
                )
            }
        }
        return .saved
    }

    /// Stages every potentially slow formatter and data write away from the
    /// main actor. Staging files live beside their destinations so the later
    /// commit is a same-volume atomic replacement.
    func stagePreparedSaveAllPaneTabsForTermination(
        _ plan: PreparedPaneSavePlan,
        until deadline: DispatchTime
    ) async -> (
        TerminationPaneSaveStageResult,
        PreparedTerminationPaneSavePlan?
    ) {
        guard preparedSavePlanStillValid(plan) else {
            return (.invalidated, nil)
        }
        let destinations = plan.entries.compactMap { planned in
            planned.destination ?? planned.tab.fileURL
        }
        guard destinations.count == plan.entries.count else {
            return (.invalidated, nil)
        }
        let destinationStates: [TerminationDestinationState]
        switch await TerminationSaveCoordinator.captureDestinationStates(
            at: destinations,
            until: deadline
        ) {
        case .captured(let captured):
            destinationStates = captured
        case .failed(let message):
            return (
                .failed(message: message, retainedArtifacts: []),
                nil
            )
        case .timedOut:
            return (.timedOut, nil)
        }
        guard destinationStates.count == plan.entries.count,
              preparedSavePlanStillValid(plan) else {
            return (.invalidated, nil)
        }
        guard zip(plan.entries, destinationStates).allSatisfy({ planned, state in
            guard planned.destination == nil,
                  let revision = planned.tab.backingFileRevision else {
                return true
            }
            return state.exists
                && state.contentDigest == revision.contentDigest
        }) else {
            return (.invalidated, nil)
        }
        let requests = zip(plan.entries, destinationStates).compactMap { pair
            -> TerminationSaveRequest? in
            let (planned, expectedDestinationState) = pair
            guard let destination = planned.destination
                    ?? planned.tab.fileURL else {
                return nil
            }
            let settings = planned.tabManager.editorSettings
            return TerminationSaveRequest(
                tabID: planned.tab.id,
                contentVersion: planned.tab.contentVersion,
                persistenceGeneration: planned.tab.persistenceGeneration,
                content: planned.tab.content,
                originalURL: planned.tab.fileURL,
                destination: destination,
                expectedDestinationState: expectedDestinationState,
                encodingRawValue: planned.tab.encoding.rawValue,
                settings: EditorSaveSettingsSnapshot(
                    insertFinalNewline: settings.insertFinalNewline,
                    stripTrailingWhitespace:
                        settings.stripTrailingWhitespace,
                    formatOnSave: settings.formatOnSave
                ),
                formatters: planned.tabManager.fileFormatters
            )
        }
        guard requests.count == plan.entries.count else {
            return (.invalidated, nil)
        }
        let lateFailureHandler = terminationSaveLateFailureHandler
        switch await TerminationSaveCoordinator.stage(
            requests,
            until: deadline,
            lateCompletion: { result in
                guard case .failed(let message, let retainedArtifacts) = result,
                      !retainedArtifacts.isEmpty else { return }
                lateFailureHandler(message, retainedArtifacts)
            }
        ) {
        case .ready(let staged):
            return (
                .ready,
                PreparedTerminationPaneSavePlan(
                    source: plan,
                    staged: staged
                )
            )
        case .failed(let message, let retainedArtifacts):
            return (
                .failed(
                    message: message,
                    retainedArtifacts: retainedArtifacts
                ),
                nil
            )
        case .timedOut:
            return (.timedOut, nil)
        }
    }

    func terminationSaveDestinationsStillMatch(
        _ plan: PreparedTerminationPaneSavePlan,
        until deadline: DispatchTime
    ) async -> Bool {
        await TerminationSaveCoordinator.destinationStatesAreCurrent(
            plan.staged,
            until: deadline
        )
    }

    /// Installs staged files serially off-main. The deadline is checked before
    /// every install and after every in-flight atomic syscall. An individual
    /// rename cannot be interrupted safely, so its model reconciliation always
    /// completes before a timeout is reported.
    func commitStagedSaveAllPaneTabsForTermination(
        _ plan: PreparedTerminationPaneSavePlan,
        until deadline: DispatchTime,
        inventoryStillAuthorized: @MainActor () -> Bool = { true }
    ) async -> PreparedPaneSaveCommitResult {
        let source = plan.source
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds,
              inventoryStillAuthorized(),
              preparedSavePlanStillValid(source),
              plan.staged.count == source.entries.count,
              zip(source.entries, plan.staged).allSatisfy({ entry, staged in
                  let destination = entry.destination ?? entry.tab.fileURL
                  return staged.request.tabID == entry.tab.id
                      && staged.request.contentVersion
                          == entry.tab.contentVersion
                      && staged.request.persistenceGeneration
                          == entry.tab.persistenceGeneration
                      && staged.request.content == entry.tab.content
                      && staged.request.originalURL == entry.tab.fileURL
                      && staged.request.destination == destination
              }) else {
            let cleanup = await cleanupTerminationSavePlan(
                plan,
                until: deadline
            )
            if let failure = terminationCleanupFailure(cleanup) {
                return failure
            }
            return .invalidated
        }

        for (index, pair) in zip(source.entries, plan.staged).enumerated() {
            let (entry, staged) = pair
            guard DispatchTime.now().uptimeNanoseconds
                    < deadline.uptimeNanoseconds else {
                let cleanup = await cleanupTerminationStagedSaves(
                    Array(plan.staged.dropFirst(index)),
                    until: deadline
                )
                if let failure = terminationCleanupFailure(cleanup) {
                    return failure
                }
                return .timedOut
            }
            guard inventoryStillAuthorized(),
                  preparedEntryStillValid(entry) else {
                let cleanup = await cleanupTerminationStagedSaves(
                    Array(plan.staged.dropFirst(index)),
                    until: deadline
                )
                if let failure = terminationCleanupFailure(cleanup) {
                    return failure
                }
                return .invalidated
            }
            let tabManager = entry.tabManager
            let lateFailureHandler = terminationSaveLateFailureHandler
            let lateCompletion: @Sendable (
                TerminationSaveInstallResult
            ) -> Void = { result in
                switch result {
                case .failed(let message, let retainedArtifacts):
                    guard !retainedArtifacts.isEmpty else { return }
                    lateFailureHandler(message, retainedArtifacts)
                case .installed(let metadata):
                    Task { @MainActor in
                    guard tabManager.tabs.first(where: {
                        $0.id == staged.request.tabID
                    })?.persistenceGeneration
                        == staged.request.persistenceGeneration else {
                        return
                    }
                    guard tabManager.reconcileTerminationStagedSave(
                        request: staged.request,
                        savedContent: staged.preparedContent,
                        metadata: metadata
                    ) else {
                        Logger.app.critical(
                            "Late termination save model reconciliation failed"
                        )
                        return
                    }
                    }
                case .timedOut:
                    break
                }
            }
            let installResult = await awaitTerminationSaveInstall(
                staged,
                until: deadline,
                lateCompletion: lateCompletion
            )
            let inventoryWasAuthorizedAfterInstall =
                inventoryStillAuthorized()
            switch installResult {
            case .failed(let message, let retainedArtifacts):
                // A typed retained artifact belongs to the current install
                // transaction even when its parent directory moved and its
                // display URL no longer matches the original staging URL.
                // Preserve that staged identity and clean only later entries.
                let cleanupStartIndex = retainedArtifacts.isEmpty
                    ? index
                    : index + 1
                let cleanupResult = await cleanupTerminationStagedSaves(
                    Array(plan.staged.dropFirst(cleanupStartIndex)),
                    until: deadline,
                    excluding: retainedArtifacts
                )
                let cleanupArtifacts: [URL]
                if case .failed(_, let artifacts) = cleanupResult {
                    cleanupArtifacts = artifacts
                } else {
                    cleanupArtifacts = []
                }
                return .failed(
                    message: message,
                    retainedArtifacts:
                        Array(Set(retainedArtifacts + cleanupArtifacts))
                )
            case .installed(let metadata):
                guard entry.tabManager.reconcileTerminationStagedSave(
                    request: staged.request,
                    savedContent: staged.preparedContent,
                    metadata: metadata
                ) else {
                    Logger.app.critical(
                        "Termination save model changed during atomic commit"
                    )
                    let cleanup = await cleanupTerminationStagedSaves(
                        Array(plan.staged.dropFirst(index + 1)),
                        until: deadline
                    )
                    if let failure = terminationCleanupFailure(cleanup) {
                        return failure
                    }
                    return .invalidated
                }
                guard inventoryWasAuthorizedAfterInstall,
                      inventoryStillAuthorized() else {
                    let cleanup = await cleanupTerminationStagedSaves(
                        Array(plan.staged.dropFirst(index + 1)),
                        until: deadline
                    )
                    if let failure = terminationCleanupFailure(cleanup) {
                        return failure
                    }
                    return .invalidated
                }
            case .timedOut:
                let cleanup = await cleanupTerminationStagedSaves(
                    Array(plan.staged.dropFirst(index)),
                    until: deadline
                )
                if let failure = terminationCleanupFailure(cleanup) {
                    return failure
                }
                guard inventoryWasAuthorizedAfterInstall else {
                    return .invalidated
                }
                return .timedOut
            }
            if DispatchTime.now().uptimeNanoseconds
                    >= deadline.uptimeNanoseconds {
                let cleanup = await cleanupTerminationStagedSaves(
                    Array(plan.staged.dropFirst(index + 1)),
                    until: deadline
                )
                if let failure = terminationCleanupFailure(cleanup) {
                    return failure
                }
                return .timedOut
            }
        }
        return .saved
    }

    private func awaitTerminationSaveInstall(
        _ staged: TerminationStagedSave,
        until deadline: DispatchTime,
        lateCompletion: @escaping @Sendable (
            TerminationSaveInstallResult
        ) -> Void
    ) async -> TerminationSaveInstallResult {
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds else {
            return .timedOut
        }
        let installer = terminationSaveInstaller
        return await withCheckedContinuation { continuation in
            let resolver = TerminationAwaitResolver(continuation)
            let operationTask = Task {
                let result = await installer(
                    staged,
                    deadline,
                    lateCompletion
                )
                if !resolver.resolve(result) {
                    lateCompletion(result)
                }
            }
            Self.terminationInstallDeadlineQueue.asyncAfter(
                deadline: deadline
            ) {
                if resolver.resolve(.timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }

    func cleanupTerminationSavePlan(
        _ plan: PreparedTerminationPaneSavePlan,
        excluding retainedArtifacts: [URL] = [],
        until deadline: DispatchTime
    ) async -> TerminationSaveCleanupResult {
        await cleanupTerminationStagedSaves(
            plan.staged,
            until: deadline,
            excluding: retainedArtifacts
        )
    }

    private func cleanupTerminationStagedSaves(
        _ staged: [TerminationStagedSave],
        until deadline: DispatchTime,
        excluding retainedArtifacts: [URL] = []
    ) async -> TerminationSaveCleanupResult {
        let protectedPaths = Set(retainedArtifacts.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        })
        let cleanupCandidates = staged.filter {
            !protectedPaths.contains(
                $0.stagingURL.resolvingSymlinksInPath()
                    .standardizedFileURL.path
            )
        }
        guard !cleanupCandidates.isEmpty else { return .cleaned }
        let timedOut = TerminationSaveCleanupResult.failed(
            message: "Termination save cleanup exceeded its deadline",
            retainedArtifacts: []
        )
        guard DispatchTime.now().uptimeNanoseconds
                < deadline.uptimeNanoseconds else {
            return timedOut
        }
        let cleaner = terminationSaveCleaner
        let lateFailureHandler = terminationSaveLateFailureHandler
        return await withCheckedContinuation { continuation in
            let resolver = TerminationAwaitResolver(continuation)
            let operationTask = Task.detached(priority: .utility) {
                let result = cleaner(cleanupCandidates)
                guard !resolver.resolve(result),
                      case .failed(
                          let message,
                          let retainedArtifacts
                      ) = result,
                      !retainedArtifacts.isEmpty else {
                    return
                }
                lateFailureHandler(message, retainedArtifacts)
            }
            Self.terminationInstallDeadlineQueue.asyncAfter(
                deadline: deadline
            ) {
                if resolver.resolve(timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }

    private func terminationCleanupFailure(
        _ result: TerminationSaveCleanupResult
    ) -> PreparedPaneSaveCommitResult? {
        guard case .failed(let message, let retainedArtifacts) = result else {
            return nil
        }
        return .failed(
            message: message,
            retainedArtifacts: retainedArtifacts
        )
    }

    private func preparedEntryStillValid(_ planned: PlannedTabSave) -> Bool {
        guard paneManager.allTabManagers.contains(where: {
            $0 === planned.tabManager
        }),
              let current = planned.tabManager.tabs.first(where: {
                  $0.id == planned.tab.id
              }) else {
            return false
        }
        return current.isDirty
            && current.kind == .text
            && !current.isTruncated
            && current.contentVersion == planned.tab.contentVersion
            && current.persistenceGeneration
                == planned.tab.persistenceGeneration
            && current.content == planned.tab.content
            && current.fileURL == planned.tab.fileURL
    }

    private func preparedSavePlanStillValid(
        _ plan: PreparedPaneSavePlan
    ) -> Bool {
        let liveTabManagers = paneManager.allTabManagers
        guard plan.dirtyAuthorization.covers(allDirtyTabs),
              plan.entries.allSatisfy({ planned in
                  guard liveTabManagers.contains(where: {
                      $0 === planned.tabManager
                  }) else {
                      return false
                  }
                  guard let current = planned.tabManager.tabs.first(where: {
                      $0.id == planned.tab.id
                  }) else {
                      return false
                  }
                  return current.isDirty
                      && current.kind == .text
                      && !current.isTruncated
                      && current.fileURL == planned.tab.fileURL
                      && current.contentVersion == planned.tab.contentVersion
                      && current.persistenceGeneration
                          == planned.tab.persistenceGeneration
                      && current.content == planned.tab.content
              }) else {
            return false
        }

        let effectiveDestinations = plan.entries.compactMap { planned in
            (planned.destination ?? planned.tab.fileURL)?
                .standardizedFileURL
        }
        guard effectiveDestinations.count == plan.entries.count,
              Set(effectiveDestinations).count
                == effectiveDestinations.count else {
            return false
        }
        let plannedTabIDs = Set(plan.entries.map(\.tab.id))
        let unplannedOpenDestinations = Set(
            allTabs.compactMap { tab -> URL? in
                guard !plannedTabIDs.contains(tab.id) else { return nil }
                return tab.fileURL?.standardizedFileURL
            }
        )
        return plan.entries.compactMap(\.destination).allSatisfy {
            !unplannedOpenDestinations.contains($0.standardizedFileURL)
        }
    }

    /// Window-scoped save-all used by close and menu decisions.
    @discardableResult
    func saveAllPaneTabs(context: DialogPresentationContext) async -> Bool {
        let prepared = await prepareSaveAllPaneTabs(context: context)
        guard case .ready(let plan) = prepared else { return false }
        switch await commitPreparedSaveAllPaneTabs(plan) {
        case .saved:
            return true
        case .invalidated, .timedOut:
            return false
        case .failed(let message, _):
            _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                on: context,
                messageText: Strings.fileOperationErrorTitle,
                informativeText: message
            )
            return false
        }
    }

    /// Resolves the editor pane a native File command should keep targeting
    /// if focus changes before its deferred delivery.
    func nativeFileCommandPaneID() -> PaneID? {
        if paneManager.root.content(for: paneManager.activePaneID) == .editor {
            return paneManager.activePaneID
        }
        return paneManager.root.leafIDs.first(where: {
            paneManager.root.content(for: $0) == .editor
        })
    }

    /// Creates one project-window-scoped untitled buffer and focuses its
    /// editor pane. Names stay unique across every split in the project.
    @discardableResult
    func createUntitledFile(in initiatingPaneID: PaneID? = nil) -> UUID? {
        let baseName = Strings.recoveryUntitled
        let existingNames = Set(
            allTabs.lazy.filter(\.isUntitled).map(\.fileName)
        )
        var sequence = 1
        var displayName = baseName
        while existingNames.contains(displayName) {
            sequence += 1
            displayName = "\(baseName) \(sequence)"
        }

        let tabManager: TabManager
        let destinationPaneID: PaneID
        if let initiatingPaneID {
            guard paneManager.root.content(for: initiatingPaneID) == .editor,
                  let initiatingTabManager = paneManager.tabManager(
                      for: initiatingPaneID
                  ) else {
                return nil
            }
            tabManager = initiatingTabManager
            destinationPaneID = initiatingPaneID
        } else {
            tabManager = paneManager.ensureEditorPane()
            destinationPaneID = paneManager.activePaneID
        }
        guard let tabID = tabManager.createUntitledTab(
            displayName: displayName
        ) else {
            return nil
        }
        _ = paneManager.selectEditorTab(
            tabID,
            in: destinationPaneID
        )
        return tabID
    }

    /// Presents File > Open as a sheet owned by this project window and opens
    /// the selected file in the editor pane captured before the panel appears.
    /// A focus change while the sheet is suspended must not retarget the file.
    func openFileFromMenu(
        initiatingPaneID capturedPaneID: PaneID? = nil
    ) {
        let context = DialogPresenter.forProject(self)
        let expectedRoot = workspace.rootURL
        let initiatingPaneID: PaneID
        if let capturedPaneID {
            guard paneManager.root.content(for: capturedPaneID) == .editor,
                  paneManager.tabManager(for: capturedPaneID) != nil else {
                return
            }
            initiatingPaneID = capturedPaneID
        } else if paneManager.root.content(for: paneManager.activePaneID)
            == .editor {
            initiatingPaneID = paneManager.activePaneID
        } else if let existingEditorPaneID =
            paneManager.root.leafIDs.first(where: {
                paneManager.root.content(for: $0) == .editor
            }) {
            initiatingPaneID = existingEditorPaneID
        } else {
            _ = paneManager.ensureEditorPane()
            initiatingPaneID = paneManager.activePaneID
        }
        guard let initiatingTabManager = paneManager.tabManager(
            for: initiatingPaneID
        ) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let fileURL = await openFileChooser(
                          expectedRoot,
                          context
                      ),
                      workspace.rootURL == expectedRoot,
                      paneManager.root.content(for: initiatingPaneID)
                        == .editor,
                      paneManager.tabManager(for: initiatingPaneID)
                        === initiatingTabManager else {
                    return
                }
                _ = paneManager.openFileInPane(
                    url: fileURL,
                    paneID: initiatingPaneID
                )
            }
        }
    }

    // MARK: - Menu-triggered saves (reentrancy-safe)

    /// Cmd+S from the File menu. Defers the save (and its synchronous
    /// `@Observable` model mutation when format-on-save changes content) to
    /// the next runloop so it does NOT execute inside the SwiftUI
    /// `ButtonAction` callstack. That reentrancy forced a synchronous SwiftUI
    /// body re-evaluation that collided with the button-action's exclusive
    /// access and triggered `_swift_reportExclusivityConflict` → `abort()`
    /// on macOS 26.5.1 when format-on-save reformatted the buffer (#1058).
    ///
    /// Autosave uses the UI-free throwing primitive directly. Close and quit
    /// use async, window-scoped save overloads after their sheet decisions;
    /// neither runs inside a `ButtonAction`.
    ///
    /// The disk write is deferred by ~1 runloop (imperceptible at 60 Hz);
    /// the dirty indicator and git status settle one frame later.
    func saveActiveTabFromMenu() {
        let context = DialogPresenter.forProject(self)
        guard paneManager.root.content(for: paneManager.activePaneID)
                == .editor,
              let tabManager = paneManager.activeTabManager else {
            return
        }
        let activeID = tabManager.activeTabID
        performMenuSave { [weak self, weak tabManager] in
            guard let self else { return false }
            guard let tabManager,
                  let activeID else {
                return false
            }
            return await self.saveTab(
                tabID: activeID,
                in: tabManager,
                forceSaveAs: false,
                context: context
            )
        }
    }

    /// File > Save As. Captures the focused editor identity before deferring
    /// beyond the SwiftUI ButtonAction call stack.
    func saveActiveTabAsFromMenu() {
        let context = DialogPresenter.forProject(self)
        guard paneManager.root.content(for: paneManager.activePaneID)
                == .editor,
              let tabManager = paneManager.activeTabManager,
              let activeID = tabManager.activeTabID else {
            return
        }
        performMenuSave { [weak self, weak tabManager] in
            guard let self, let tabManager else { return false }
            return await self.saveTab(
                tabID: activeID,
                in: tabManager,
                forceSaveAs: true,
                context: context
            )
        }
    }

    /// Cmd+Option+S (Save All) from the File menu. Same reentrancy rationale
    /// as ``saveActiveTabFromMenu`` — Save All can also mutate `@Observable`
    /// per-pane tab state synchronously when format-on-save changes content.
    func saveAllTabsFromMenu() {
        let context = DialogPresenter.forProject(self)
        performMenuSave { [weak self] in
            guard let self else { return false }
            return await saveAllPaneTabs(context: context)
        }
    }

    /// Shared deferral for menu-triggered saves. Runs the save `operation`
    /// on the next runloop (outside any `ButtonAction` callstack), then
    /// refreshes git status + line diffs when it succeeded.
    private func performMenuSave(
        _ operation: @escaping @MainActor () async -> Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard await operation() else { return }
                await self.workspace.gitProvider.refreshAsync()
                NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
            }
        }
    }

    /// Saves an exact editor buffer. Untitled files and explicit Save As use
    /// the project owner's sheet; ordinary file-backed buffers write directly.
    func saveTab(
        tabID: UUID,
        in tabManager: TabManager,
        forceSaveAs: Bool,
        context: DialogPresentationContext
    ) async -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabID }),
              tab.kind == .text,
              !tab.isTruncated else {
            return false
        }
        if !forceSaveAs, tab.fileURL != nil,
           let index = tabManager.tabs.firstIndex(where: { $0.id == tabID }) {
            return await tabManager.saveTab(at: index, context: context)
        }

        guard let destination = await saveDestinationChooser(
            tab,
            workspace.rootURL,
            context
        ),
        tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        do {
            return try await tabManager.saveTabAsAsync(
                tabID: tabID,
                to: destination
            )
        } catch {
            _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                on: context,
                messageText: Strings.fileOperationErrorTitle,
                informativeText: error.localizedDescription
            )
            return false
        }
    }

    /// Checks every editor pane for externally modified or deleted files.
    /// Aggregates the per-pane results so global observers do not depend on
    /// the root environment's `TabManager`, which may be orphaned after pane
    /// pruning or simply not own the currently visible tab.
    func checkExternalChanges() -> TabManager.ExternalChangeResult {
        var conflicts: [TabManager.ExternalConflict] = []
        var reloadedFileNames: [String] = []
        var seenReloadedFileNames = Set<String>()

        for tabManager in paneManager.allTabManagers {
            let result = tabManager.checkExternalChanges()
            conflicts.append(contentsOf: result.conflicts)
            for fileName in result.reloadedFileNames
                where seenReloadedFileNames.insert(fileName).inserted {
                reloadedFileNames.append(fileName)
            }
        }

        // Tabs already closed by per-pane checkExternalChanges()
        return .init(conflicts: conflicts, reloadedFileNames: reloadedFileNames, cleanDeletedIDs: [])
    }

    /// Reloads matching tabs in every editor pane. The same file can be open
    /// in multiple panes, and the primary TabManager may not own any visible
    /// editor after pane pruning.
    func reloadTabs(url: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.reloadTab(url: url)
        }
    }

    func reloadTab(conflict: TabManager.ExternalConflict) {
        for tabManager in paneManager.allTabManagers
        where tabManager.tabs.contains(where: { $0.id == conflict.tabID }) {
            tabManager.reloadTab(conflict: conflict)
        }
    }

    @discardableResult
    func authorizeExternalChange(
        _ conflict: TabManager.ExternalConflict
    ) -> Bool {
        for tabManager in paneManager.allTabManagers
        where tabManager.tabs.contains(where: { $0.id == conflict.tabID }) {
            return tabManager.authorizeExternalChange(conflict)
        }
        return false
    }

    /// Returns all open tabs affected by deletion across every editor pane.
    func tabsAffectedByDeletion(url: URL) -> [EditorTab] {
        paneManager.allTabManagers.flatMap { $0.tabsAffectedByDeletion(url: url) }
    }

    /// Closes matching tabs for a deleted path across every editor pane.
    func closeTabsForDeletedFile(url: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.closeTabsForDeletedFile(url: url)
        }
    }

    /// Updates tab URLs in every editor pane to reflect a renamed file or
    /// directory, preserving tab identity. The primary ``primaryTabManager``
    /// alone is not enough — the same file may be open in a split pane, and
    /// the primary TabManager may be orphaned after pane pruning.
    func handleFileRenamed(oldURL: URL, newURL: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
        }
    }

    let toastManager = ToastManager()
    /// Tracks active and recent user-task runs for the task execution UI
    /// (issue #1246). Owned by the project window so the output surface,
    /// toast, and Cancel button all share one source of truth.
    let taskRunStore = UserTaskRunStore()
    /// Recovery snapshots and their lifecycle are owned by the main actor.
    private(set) var recoveryManager: RecoveryManager?
    /// Project-scoped session persistence. Production uses `.standard`;
    /// process-level lifecycle tests inject a namespaced suite so launching a
    /// second real Pine process cannot read or overwrite developer state.
    let sessionDefaults: UserDefaults
    private(set) var presentationLifecycle: PresentationLifecycle = .visible
    #if DEBUG
    private(set) var editorServiceSuspendCountForTesting = 0
    private(set) var editorServiceResumeCountForTesting = 0
    #endif
    private var editorContextCommandGeneration: UInt64 = 0
    private let contextPresentationIdentity: ContextPresentationIdentity
    @ObservationIgnored
    private var agentTaskFilesystemAdmission:
        RecentAgentTaskFilesystemValidationLease?
    @ObservationIgnored
    private var agentTaskFilesystemAdmissionGeneration = UUID()
    @ObservationIgnored
    private var agentTaskFilesystemIdentity: AgentTaskProjectIdentity?

    #if DEBUG
    func removeRecoveryManagerForTesting() {
        recoveryManager?.cancelScheduledSnapshot()
        recoveryManager?.stopPeriodicSnapshots()
        recoveryManager = nil
    }
    #endif

    init(
        lspSettings: LSPSettings = .shared,
        sessionDefaults: UserDefaults = .standard,
        agentProcessSnapshotPoller: AgentProcessSnapshotPoller? = nil,
        agentTaskRegistry: AgentTaskRegistry? = nil,
        workspaceFilesystemValidationSeam:
            @escaping @Sendable () async -> Void = {},
        contextFileWriter: ContextFileWriter = ContextFileWriter(),
        contextPresentationIdentity: ContextPresentationIdentity =
            ContextPresentationIdentity(epoch: 1)
    ) {
        self.sessionDefaults = sessionDefaults
        self.workspace = WorkspaceManager(
            filesystemValidationSeam: workspaceFilesystemValidationSeam
        )
        self.contextFileWriter = contextFileWriter
        self.contextPresentationIdentity = contextPresentationIdentity
        self.terminal = TerminalManager(
            agentProcessSnapshotPoller: agentProcessSnapshotPoller,
            agentTaskRegistry: agentTaskRegistry
        )
        self.lspManager = LSPManager(settings: lspSettings)
        self.problemsController = ProblemsPanelController(lspManager: lspManager)
        workspace.setOnRootNodesChanged { [weak self] nodes in
            guard let self, let rootURL = self.workspace.rootURL else { return }
            self.quickOpenProvider.rebuildIndex(from: nodes, rootURL: rootURL)
            // Agent activity correlation (#1072): when the file tree refreshes
            // (typically a FileSystemWatcher event) and ≥1 agent session is
            // active, attribute newly-modified files to the active session(s).
            self.correlateAgentActivity(rootURL: rootURL)
        }
        workspace.progressTracker = progress
        workspace.gitProvider.progressTracker = progress
        paneManager.configureEditorTabManager = { [weak self] tabManager in
            self?.configureEditorTabManager(tabManager)
        }
        paneManager.configureTerminalTab = { [weak self] tab in
            self?.terminal.configureAgentLifecycle(for: tab)
            self?.configureFilesystemAdmission(for: tab)
        }
        problemsController.configureDocumentStatesProvider { [weak self] in
            self?.problemsDocumentStates ?? []
        }
        // Wire TerminalManager to PaneManager (lazy wiring)
        terminal.paneManager = paneManager
    }

    @discardableResult
    func bindDialogOwnerWindow(_ window: NSWindow) -> UUID {
        guard retiredDialogOwnerGeneration(for: window) == nil else {
            return dialogOwnerWindowGeneration
        }
        completedDialogOwnerWindow = nil
        if dialogOwnerWindow !== window {
            dialogOwnerWindowGeneration = UUID()
        }
        dialogOwnerWindow = window
        return dialogOwnerWindowGeneration
    }

    /// Starts a registry-authorized window presentation before SwiftUI can
    /// bind its replacement NSWindow. Rotating now, rather than at the later
    /// bind, fences a delayed close from the previous window during the gap
    /// between retained-manager admission and replacement-window capture.
    func prepareForWindowPresentation() {
        let previousOwner = dialogOwnerWindow
        let previousGeneration = dialogOwnerWindowGeneration
        let completedOwner = completedDialogOwnerWindow?.window
        if let previousOwner {
            retiredDialogOwnerWindows.removeAll {
                $0.window == nil || $0.window === previousOwner
            }
            retiredDialogOwnerWindows.append(RetiredDialogOwnerWindow(
                window: previousOwner,
                generation: previousGeneration
            ))
        }
        dialogOwnerWindowGeneration = UUID()
        dialogOwnerWindow = nil
        if let previousOwner {
            if let delegate = previousOwner.delegate as? CloseDelegate,
               delegate.projectManager === self {
                delegate.retirePresentationAuthorization(for: previousOwner)
            } else {
                DialogPresenter.ownerDidClose(previousOwner)
            }
        }
        // SwiftUI can reopen a completed WindowGroup lifecycle by ordering the
        // same NSWindow instance front without updating its representable.
        // Re-arm only an owner whose old close callback already committed;
        // unfinished retired owners remain fenced until a fresh window binds.
        if let completedOwner,
           let delegate = completedOwner.delegate as? CloseDelegate,
           delegate.projectManager === self,
           delegate.didCompleteWindowLifecycle {
            delegate.beginNewWindowLifecycle(on: completedOwner)
        }
    }

    func retiredDialogOwnerGeneration(for window: NSWindow) -> UUID? {
        retiredDialogOwnerWindows.removeAll { $0.window == nil }
        return retiredDialogOwnerWindows.first(where: {
            $0.window === window
        })?.generation
    }

    func recordCompletedDialogOwnerLifecycle(
        _ window: NSWindow,
        generation: UUID?
    ) {
        guard let generation,
              dialogOwnerWindow === window,
              dialogOwnerWindowGeneration == generation else { return }
        completedDialogOwnerWindow = RetiredDialogOwnerWindow(
            window: window,
            generation: generation
        )
    }

    func authorizeCompletedDialogOwnerLifecycle(
        _ window: NSWindow,
        generation: UUID?
    ) -> Bool {
        guard let generation,
              let completed = completedDialogOwnerWindow,
              completed.window === window,
              completed.generation == generation else {
            return false
        }
        if let retiredGeneration = retiredDialogOwnerGeneration(for: window) {
            guard retiredGeneration == generation else { return false }
            retiredDialogOwnerWindows.removeAll { $0.window === window }
        }
        completedDialogOwnerWindow = nil
        return true
    }

    func unbindDialogOwnerWindow(_ window: NSWindow) {
        guard dialogOwnerWindow === window else { return }
        dialogOwnerWindow = nil
    }

    /// Waits for the project window to become a valid native dialog owner.
    /// Project scenes are created asynchronously, so launch/drop flows cannot
    /// safely assume a fixed delay is enough before opening a large file.
    ///
    /// The retry loop is bounded and cancellation-aware. Tests can inject the
    /// wait and eligibility predicate to exercise delayed binding without
    /// depending on AppKit timing.
    func awaitDialogOwnerWindow(
        maximumAttempts: Int = 80,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        isEligible: (@MainActor (NSWindow) -> Bool)? = nil,
        recoverOwner: (@MainActor () -> NSWindow?)? = nil
    ) async -> NSWindow? {
        let wait = waitForNextAttempt ?? {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let acceptsWindow = isEligible ?? {
            DialogPresenter.isEligibleApplicationOwner($0)
        }
        let recover = recoverOwner ?? { [weak self] in
            guard let self else { return nil }
            return DialogPresenter.recoverProjectOwnerWindow(
                for: self,
                isEligible: acceptsWindow
            )
        }

        for _ in 0..<max(0, maximumAttempts) {
            guard !Task.isCancelled else { return nil }
            if let window = dialogOwnerWindow, acceptsWindow(window) {
                return window
            }
            if let window = recover(), acceptsWindow(window) {
                return window
            }
            await wait()
        }

        guard !Task.isCancelled else { return nil }
        if let window = dialogOwnerWindow, acceptsWindow(window) {
            return window
        }
        guard let window = recover(), acceptsWindow(window) else { return nil }
        return window
    }

    /// Serializes stateful dialog workflows whose model snapshot must be
    /// recomputed only after an earlier decision finishes. The native sheet
    /// coordinator serializes presentation, while this queue prevents two
    /// filesystem events from taking stale tab snapshots before either sheet
    /// resolves.
    func enqueueDialogOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previous = dialogOperationTail
        dialogOperationGeneration &+= 1
        let generation = dialogOperationGeneration
        dialogOperationTail = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            await operation()
            if dialogOperationGeneration == generation {
                dialogOperationTail = nil
            }
        }
    }

    isolated deinit {
        dialogOperationTail?.cancel()
        recoveryManager?.stopPeriodicSnapshots()
    }

    /// Sets up crash recovery for the given project directory.
    /// Called once when the project URL becomes known (from `loadDirectory`).
    func setupRecovery(projectURL: URL) {
        guard recoveryManager == nil else { return }
        let manager = RecoveryManager(projectURL: projectURL)
        manager.tabsProvider = { [weak self] in
            self?.allTabs ?? []
        }
        // The primary manager can temporarily be orphaned from the pane tree,
        // so configure it explicitly as well as every currently visible pane.
        primaryTabManager.recoveryManager = manager
        for tabManager in paneManager.allTabManagers {
            tabManager.recoveryManager = manager
        }
        manager.startPeriodicSnapshots()
        recoveryManager = manager
    }

    /// Stops services that exist only to keep a visible editor current while
    /// retaining PTYs, terminal buffers, agent identity, and user-task owners.
    func suspendEditorServices() {
        guard presentationLifecycle == .visible else { return }
        presentationLifecycle = .backgroundSuspended
        #if DEBUG
        editorServiceSuspendCountForTesting += 1
        #endif
        recoveryManager?.snapshotDirtyTabs(allTabs)
        recoveryManager?.cancelScheduledSnapshot()
        recoveryManager?.stopPeriodicSnapshots()
        workspace.suspend()
        searchProvider.cancel()
        lspManager.suspendForBackground()
        cleanupEditorContext()
    }

    /// Re-arms each visible-editor service once for one retained manager.
    func resumeEditorServices() {
        guard presentationLifecycle == .backgroundSuspended else { return }
        presentationLifecycle = .visible
        #if DEBUG
        editorServiceResumeCountForTesting += 1
        #endif
        workspace.resume()
        recoveryManager?.startPeriodicSnapshots()
        lspManager.resumeFromBackground()
        synchronizeAgentHandoff()
        problemsController.refreshDocumentOwnership()
    }

    /// Final resource teardown used only after registry reclamation proves
    /// there is no process/task ownership left to preserve.
    func shutdownReclaimableProject() {
        guard presentationLifecycle != .destroyed else { return }
        presentationLifecycle = .destroyed
        recoveryManager?.snapshotDirtyTabs(allTabs)
        recoveryManager?.cancelScheduledSnapshot()
        recoveryManager?.stopPeriodicSnapshots()
        workspace.suspend()
        searchProvider.cancel()
        lspManager.shutdownAll()
        terminal.shutdownPermanently()
        agentTaskFilesystemAdmission = nil
        agentTaskFilesystemAdmissionGeneration = UUID()
    }

    var requiresBackgroundRetention: Bool {
        allTabs.contains(where: \.isDirty)
            || terminal.requiresBackgroundRetention
            || hasOutstandingUserTaskExecution
    }

    /// Applies project-owned services to every editor group, including groups
    /// created later by pane splits or session restoration.
    private func configureEditorTabManager(_ tabManager: TabManager) {
        tabManager.recoveryManager = recoveryManager
        if isAutoSaveFrozenForTermination {
            tabManager.freezeAutoSaveForTermination()
        }
        tabManager.dialogContextProvider = { [weak self] in
            guard let self else { return .unscoped }
            return DialogPresenter.forProject(self)
        }
        tabManager.onEditorContextChanged = { [weak self] in
            guard let self else { return }
            self.updateEditorContext()
            self.problemsController.refreshDocumentOwnership()
        }
    }

    /// Visible editor documents with exact project/pane/tab/revision
    /// ownership. Config validators and LSP views exist only for active tabs,
    /// so inactive tabs intentionally do not validate an old panel record.
    private var problemsDocumentStates: [ProblemsDocumentState] {
        paneManager.root.leafIDs.compactMap { paneID in
            guard paneManager.root.content(for: paneID) == .editor,
                  let tabManager = paneManager.tabManager(for: paneID) else {
                return nil
            }
            guard let tab = tabManager.activeTab,
                  let fileURL = tab.fileURL else {
                return nil
            }
            return ProblemsDocumentState(
                owner: problemsController.documentOwner(
                    paneID: paneID,
                    tabID: tab.id,
                    uri: fileURL.absoluteString
                ),
                contentRevision: tab.contentVersion,
                isFocusedPane: paneManager.activePaneID == paneID
            )
        }
    }

    /// Routes a Problems row to the editor instance that produced it. The
    /// controller proves freshness first, then this final check confirms the
    /// live pane/tab/URL/content revision before changing focus.
    @discardableResult
    func navigateToProblem(
        _ diagnostic: ProblemsFlatDiagnostic
    ) -> Bool {
        guard let target = problemsController.navigationTarget(
            for: diagnostic
        ),
        let tabManager = paneManager.tabManager(for: target.owner.paneID),
        let tab = tabManager.activeTab,
        let fileURL = tab.fileURL,
        tab.id == target.owner.tabID,
        fileURL.absoluteString == target.owner.uri else {
            return false
        }

        let expectedContentRevision: UInt64
        switch target.revision {
        case .editor(let revision):
            expectedContentRevision = revision
        case .lsp(_, let contentRevision):
            expectedContentRevision = contentRevision
        }
        guard tab.contentVersion == expectedContentRevision,
              paneManager.selectEditorTab(
                  target.owner.tabID,
                  in: target.owner.paneID
              ) else {
            return false
        }

        tabManager.pendingGoToLocation = EditorNavigationLocation(
            line: target.line,
            column: target.column
        )
        return true
    }

    /// Persists current session (project + open file tabs) to UserDefaults.
    /// Collects tabs from ALL panes so split-pane tabs are not lost on restore.
    func saveSession() {
        guard let rootURL = workspace.rootURL else { return }
        let rootPath = rootURL.path + "/"

        // Gather tabs from all panes (not just the primary tabManager)
        let everyTab = allTabs

        let openFileURLs = everyTab
            .compactMap(\.fileURL)
            .filter { $0.path.hasPrefix(rootPath) }

        // Only persist active file if it belongs to the project
        let activeFileURL: URL? = if let url = activeTabManager.activeTab?.fileURL,
                                      url.path.hasPrefix(rootPath) { url } else { nil }

        // Collect preview modes for markdown tabs that aren't in default (.source) state
        // and belong to the project root
        var previewModes: [String: String]?
        let mdTabs = everyTab.filter {
            $0.isMarkdownFile
                && $0.previewMode != .source
                && ($0.fileURL?.path.hasPrefix(rootPath) ?? false)
        }
        if !mdTabs.isEmpty {
            previewModes = [:]
            for tab in mdTabs {
                guard let fileURL = tab.fileURL else { continue }
                previewModes?[fileURL.path] = tab.previewMode.rawValue
            }
        }

        // Collect tabs with syntax highlighting disabled (large files), scoped to project root
        let disabledTabs = everyTab.filter {
            $0.syntaxHighlightingDisabled
                && ($0.fileURL?.path.hasPrefix(rootPath) ?? false)
        }
        let highlightingDisabledPaths: [String]? = disabledTabs.isEmpty
            ? nil
            : disabledTabs.compactMap(\.fileURL?.path)

        // Per-tab editor state (cursor, scroll, folds)
        var editorStates: [String: PerTabEditorState]?
        let tabsWithState = everyTab.filter { tab in
            (tab.fileURL?.path.hasPrefix(rootPath) ?? false)
                && tab.kind == .text
        }
        if !tabsWithState.isEmpty {
            editorStates = [:]
            for tab in tabsWithState {
                guard let fileURL = tab.fileURL else { continue }
                editorStates?[fileURL.path] =
                    PerTabEditorState.capture(from: tab)
            }
        }

        // Pinned tabs, scoped to project root
        let pinnedTabs = everyTab.filter {
            $0.isPinned && ($0.fileURL?.path.hasPrefix(rootPath) ?? false)
        }
        let pinnedPaths: [String]? = pinnedTabs.isEmpty
            ? nil
            : pinnedTabs.compactMap(\.fileURL?.path)

        // Pane layout — always persist (terminal panes need it even with a single editor pane)
        var paneLayoutData: Data?
        var paneTabAssignments: [String: [String]]?
        var activePaneIDString: String?
        var paneActiveEditorPaths: [String: String]?
        var panePinnedPaths: [String: [String]]?
        var paneTransientPreviewPaths: [String: String]?
        var globalTabSwitchOrder: [SessionTabReference]?
        var terminalPaneTabCounts: [String: Int]?
        var terminalPaneActiveIndices: [String: Int]?

        paneLayoutData = try? JSONEncoder().encode(paneManager.persistableRoot)
        var assignments: [String: [String]] = [:]
        var activeEditorPaths: [String: String] = [:]
        var pinnedPathsByPane: [String: [String]] = [:]
        var transientPreviewPaths: [String: String] = [:]
        for (paneID, tm) in paneManager.tabManagers {
            let paneKey = paneID.id.uuidString
            let paths = tm.tabs
                .compactMap(\.fileURL?.path)
                .filter { $0.hasPrefix(rootPath) }
            if !paths.isEmpty {
                assignments[paneKey] = paths
            }
            if let activePath = tm.activeTab?.fileURL?.path,
               activePath.hasPrefix(rootPath) {
                activeEditorPaths[paneKey] = activePath
            }
            let panePins = tm.tabs
                .filter {
                    $0.isPinned
                        && ($0.fileURL?.path.hasPrefix(rootPath) ?? false)
                }
                .compactMap(\.fileURL?.path)
            if !panePins.isEmpty {
                pinnedPathsByPane[paneKey] = panePins
            }
            if let previewPath = tm.tabs.first(where: {
                $0.isTransientPreview
                    && ($0.fileURL?.path.hasPrefix(rootPath) ?? false)
            })?.fileURL?.path {
                transientPreviewPaths[paneKey] = previewPath
            }
        }
        paneTabAssignments = assignments.isEmpty ? nil : assignments
        paneActiveEditorPaths = activeEditorPaths.isEmpty ? nil : activeEditorPaths
        panePinnedPaths = pinnedPathsByPane.isEmpty ? nil : pinnedPathsByPane
        paneTransientPreviewPaths = transientPreviewPaths.isEmpty ? nil : transientPreviewPaths
        activePaneIDString = paneManager.activePaneID.id.uuidString

        // Terminal pane state
        var tpCounts: [String: Int] = [:]
        var tpActiveIndices: [String: Int] = [:]
        for (paneID, state) in paneManager.terminalStates {
            tpCounts[paneID.id.uuidString] = state.tabCount
            if let activeID = state.activeTerminalID,
               let idx = state.terminalTabs.firstIndex(where: { $0.id == activeID }) {
                tpActiveIndices[paneID.id.uuidString] = idx
            }
        }
        terminalPaneTabCounts = tpCounts.isEmpty ? nil : tpCounts
        terminalPaneActiveIndices = tpActiveIndices.isEmpty ? nil : tpActiveIndices
        let persistedSwitchOrder: [SessionTabReference] = paneManager
            .validGlobalTabSwitchOrder().compactMap { identity -> SessionTabReference? in
            switch identity.contentType {
            case .editor:
                guard let path = paneManager.tabManager(for: identity.paneID)?.tabs
                    .first(where: { $0.id == identity.tabID })?.fileURL?.path,
                      path.hasPrefix(rootPath) else { return nil }
                return SessionTabReference.editor(paneID: identity.paneID, filePath: path)
            case .terminal:
                guard let index = paneManager.terminalState(for: identity.paneID)?
                    .terminalTabs.firstIndex(where: { $0.id == identity.tabID }) else {
                    return nil
                }
                return SessionTabReference.terminal(paneID: identity.paneID, tabIndex: index)
            }
        }
        globalTabSwitchOrder = persistedSwitchOrder.isEmpty ? nil : persistedSwitchOrder

        SessionState.save(
            projectURL: rootURL,
            openFileURLs: openFileURLs,
            activeFileURL: activeFileURL,
            previewModes: previewModes,
            highlightingDisabledPaths: highlightingDisabledPaths,
            editorStates: editorStates,
            pinnedPaths: pinnedPaths,
            terminalPaneTabCounts: terminalPaneTabCounts,
            terminalPaneActiveIndices: terminalPaneActiveIndices,
            paneLayoutData: paneLayoutData,
            paneTabAssignments: paneTabAssignments,
            activePaneID: activePaneIDString,
            paneActiveEditorPaths: paneActiveEditorPaths,
            panePinnedPaths: panePinnedPaths,
            paneTransientPreviewPaths: paneTransientPreviewPaths,
            globalTabSwitchOrder: globalTabSwitchOrder,
            defaults: sessionDefaults
        )
    }

    // MARK: - Convenience accessors (workspace)

    var rootNodes: [FileNode] { workspace.rootNodes }
    var projectName: String { workspace.projectName }
    var rootURL: URL? { workspace.rootURL }
    var gitProvider: GitStatusProvider { workspace.gitProvider }

    func openFolder() {
        let context = DialogPresenter.forProject(self)
        Task { @MainActor in
            await workspace.openFolder(context: context)
        }
    }
    func loadDirectory(
        url: URL,
        agentTaskProject: AgentTaskProjectIdentity? = nil,
        filesystemAdmission:
            RecentAgentTaskFilesystemValidationLease? = nil
    ) {
        let projectIdentity = agentTaskProject ?? AgentTaskProjectIdentity(
                canonicalProjectPath: url.path,
                canonicalWorktreePath: url.path
        )
        replaceAgentTaskFilesystemAdmission(
            filesystemAdmission,
            identity: projectIdentity
        )
        let admissionGeneration = agentTaskFilesystemAdmissionGeneration
        let workspaceValidator: (@Sendable () async -> Bool)?
        if filesystemAdmission != nil {
            workspaceValidator = { [weak self] in
                guard let self else { return false }
                return await self.revalidateAgentTaskFilesystemAdmission(
                    expectedGeneration: admissionGeneration,
                    workingDirectory: url
                )
            }
        } else {
            workspaceValidator = nil
        }
        workspace.loadDirectory(
            url: url,
            filesystemValidator: workspaceValidator
        )
        terminal.configureAgentTaskProject(projectIdentity)
        setupRecovery(projectURL: url)
        agentHistory.updateProjectRoot(url)
        synchronizeAgentHandoff(projectRoot: url)
        lspManager.setWorkspaceRoot(url)
        #if DEBUG
        seedAgentActivityUITestFixture(projectURL: url)
        seedAgentAttentionUITestFixture(projectURL: url)
        #endif
    }

    /// Replaces only an already-proved descriptor lease. No filesystem work
    /// occurs on MainActor; a new generation fences every load/PTY validation
    /// still in flight for the prior admitted instance.
    func replaceAgentTaskFilesystemAdmission(
        _ admission: RecentAgentTaskFilesystemValidationLease?,
        identity: AgentTaskProjectIdentity
    ) {
        agentTaskFilesystemAdmission = admission
        agentTaskFilesystemIdentity = identity
        agentTaskFilesystemAdmissionGeneration = UUID()
        paneManager.allTerminalTabs.forEach(configureFilesystemAdmission)
    }

    private func configureFilesystemAdmission(for tab: TerminalTab) {
        guard agentTaskFilesystemAdmission != nil else {
            tab.configureWorkingDirectoryValidation(nil)
            return
        }
        tab.configureWorkingDirectoryValidation { [weak self] directory in
            guard let self else { return false }
            return await self.revalidateAgentTaskFilesystemAdmission(
                workingDirectory: directory
            )
        }
    }

    func revalidateAgentTaskFilesystemAdmission(
        expectedIdentity: AgentTaskProjectIdentity? = nil,
        expectedGeneration: UUID? = nil,
        workingDirectory: URL? = nil
    ) async -> Bool {
        guard let identity = agentTaskFilesystemIdentity else { return false }
        if let expectedIdentity, expectedIdentity != identity { return false }
        if let workingDirectory,
           workingDirectory.standardizedFileURL.path
            != identity.canonicalWorktreePath { return false }
        if identity.canonicalProjectPath == identity.canonicalWorktreePath {
            return true
        }
        guard let admission = agentTaskFilesystemAdmission else { return false }
        let generation = agentTaskFilesystemAdmissionGeneration
        if let expectedGeneration, expectedGeneration != generation {
            return false
        }
        let valid = await Task.detached(priority: .utility) {
            admission.revalidate()
        }.value
        return !Task.isCancelled
            && valid
            && agentTaskFilesystemAdmission === admission
            && agentTaskFilesystemAdmissionGeneration == generation
            && agentTaskFilesystemIdentity == identity
    }

    // MARK: - Agent activity file-system correlation (#1072)

    /// Modified paths (relative to the project root) already attributed to an
    /// agent session, so the same change isn't recorded repeatedly while the
    /// `FileSystemWatcher` keeps firing for the same edit.
    private var attributedModifiedPaths: Set<String> = []
    /// Whether `attributedModifiedPaths` has been seeded with pre-existing
    /// modifications since an agent became active. Cleared when no agent is
    /// active, so a fresh run attributes only files changed *during* it.
    private var agentActivitySeeded = false

    #if DEBUG
    /// Seeds deterministic rows only when an explicit UI-test launch argument
    /// is present. Production builds contain no fixture path.
    private func seedAgentActivityUITestFixture(projectURL: URL) {
        let arguments = ProcessInfo.processInfo.arguments
        let seedAll = arguments.contains("--ui-test-agent-activity-all")
        let seedHeuristic = arguments.contains(
            "--ui-test-agent-activity-heuristic"
        )
        guard seedAll || seedHeuristic, agentActivity.actions.isEmpty else {
            return
        }

        let firstSession = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
        )
        let secondSession = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
        )
        let sessionLinkedActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1)
        )
        let inferredActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2)
        )
        let ambiguousActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3)
        )
        let toolActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4)
        )
        let mainFile = projectURL.appendingPathComponent("main.swift")

        if seedAll {
            agentActivity.record(
                AgentAction(
                    id: sessionLinkedActionID,
                    sessionID: firstSession,
                    agentType: .claudeCode,
                    kind: .command,
                    status: .completed,
                    summary: "UI fixture: session-linked"
                )
            )
            agentActivity.record(
                AgentAction(
                    id: toolActionID,
                    sessionID: secondSession,
                    agentType: .codex,
                    kind: .toolCall,
                    status: .inProgress,
                    summary: "UI fixture: tool"
                )
            )
        }
        agentActivity.record(
            AgentAction(
                id: inferredActionID,
                attribution: .inferred(
                    AgentActionCandidate(
                        sessionID: firstSession,
                        agentType: .claudeCode
                    )
                ),
                kind: .fileWrite,
                status: .completed,
                fileURL: mainFile,
                summary: "UI fixture: inferred"
            )
        )
        agentActivity.record(
            AgentAction(
                id: ambiguousActionID,
                attribution: .ambiguous(candidates: [
                    AgentActionCandidate(
                        sessionID: firstSession,
                        agentType: .claudeCode
                    ),
                    AgentActionCandidate(
                        sessionID: secondSession,
                        agentType: .codex
                    )
                ]),
                kind: .fileWrite,
                status: .failed,
                fileURL: mainFile,
                summary: "UI fixture: ambiguous"
            )
        )
    }

    /// Creates two deterministic terminal-backed summaries for keyboard and
    /// accessibility UI tests. Production and ordinary debug launches never
    /// enter this path.
    private func seedAgentAttentionUITestFixture(projectURL: URL) {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-attention"
        ) else {
            return
        }
        let paneID = paneManager.createTerminalPaneAtBottom(
            workingDirectory: projectURL
        )
        guard let state = paneManager.terminalState(for: paneID),
              let firstTab = state.activeTab else {
            return
        }
        firstTab.name = "Thinking agent"
        firstTab.agentSession = AgentSession(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 1
                )
            ),
            agentType: .claudeCode,
            state: .thinking
        )

        guard let secondTab = paneManager.addTerminalTab(
            in: paneID,
            workingDirectory: projectURL
        ) else {
            return
        }
        secondTab.name = "Executing agent"
        secondTab.agentSession = AgentSession(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 2
                )
            ),
            agentType: .codex,
            state: .executing
        )
        state.activeTerminalID = firstTab.id
    }
    #endif

    /// Minimal real data source for the Activity Panel (#1072): attributes
    /// file-tree refreshes to the active agent session(s). The
    /// `FileSystemWatcher` signals only that *something* changed — not which
    /// file — so the changed set is read from `gitProvider.fileStatuses`.
    ///
    /// Conservative heuristic: ignored when no agent is active; the first
    /// refresh after an agent appears seeds the seen-set with whatever was
    /// already changed (so pre-existing changes aren't misattributed), and
    /// only subsequently-changed files are recorded. With several live
    /// sessions the action retains every candidate as ambiguous and selects
    /// no owner (see `AgentActivityStore`).
    ///
    /// "Changed" covers every working-tree state except `.deleted` — agents
    /// routinely create brand-new files (` .untracked`), `git add` files
    /// (`.staged`), and modify already-staged files (`.mixed`); dropping any
    /// of those would make the panel miss the most common agent action.
    func correlateAgentActivity(rootURL: URL) {
        let active = terminal.projectOwnedActiveAgentSessions
        guard !active.isEmpty else {
            attributedModifiedPaths = []
            agentActivitySeeded = false
            return
        }
        let changed = gitProvider.fileStatuses
            .filter { Self.isAttributableStatus($0.value) }
            .map(\.key)
        if !agentActivitySeeded {
            // Seed: treat currently-changed files as pre-existing.
            attributedModifiedPaths = Set(changed)
            agentActivitySeeded = true
            return
        }
        // Prune paths no longer changed (e.g. an agent reverted a file) so a
        // later re-modification is recorded instead of silently dropped.
        attributedModifiedPaths.formIntersection(changed)
        for path in changed where !attributedModifiedPaths.contains(path) {
            attributedModifiedPaths.insert(path)
            agentActivity.noteFileSystemChange(
                at: rootURL.appendingPathComponent(path),
                activeSessions: active
            )
        }
    }

    /// `true` for working-tree states that represent a change an agent could
    /// have made. `.deleted` is excluded (the file no longer exists to open).
    /// `internal` so the attribution filter is unit-testable alongside the
    /// exact project-terminal ownership projection.
    static func isAttributableStatus(_ status: GitFileStatus) -> Bool {
        switch status {
        case .untracked, .modified, .staged, .added, .conflict, .mixed:
            return true
        case .deleted:
            return false
        }
    }

    // MARK: - Agent history finalization (#1073)

    /// Finalizes any `.done` agent sessions not yet logged into the durable
    /// `AgentHistoryStore`. Called on app termination (and safe to call
    /// periodically). Records heuristically attributed relative paths and a
    /// file-count summary for review. These observations do not authorize
    /// undo; safe reversal requires exact provenance and an inverse change set
    /// (#1183).
    ///
    /// The summary is intentionally file-count only (no `+/-` line counts):
    /// `GitStatusProvider.diffForFile` collapses consecutive diff lines into
    /// block entries, so a line count would be misleading, and computing it
    /// synchronously per file on the main thread at termination would stall
    /// the UI (S2/S3 from the #1075 review).
    func finalizeAgentSessionsForHistory() {
        guard let root = workspace.rootURL else { return }
        let doneSessions = terminal.takeProjectOwnedCompletedAgentSessions()
        guard !doneSessions.isEmpty else { return }
        for session in doneSessions {
            let relativePaths = session.filesModified.compactMap { relativePath(from: $0, root: root) }
            agentHistory.finalize(
                session: session,
                summary: "",
                affectedRelativePaths: relativePaths,
                attribution: .heuristic
            )
        }
    }

    /// Returns `url` relative to `root`, or `nil` if `url` is not under `root`.
    /// Resolves symlinks on both sides so a file recorded via a symlinked path
    /// still matches the (resolved) project root (S4 from the #1075 review).
    private func relativePath(from url: URL, root: URL) -> String? {
        // `URL.path(relativeTo:)` was removed in newer SDKs, so derive the
        // relative path manually. `resolvingSymlinksInPath()` canonicalizes
        // both sides so symlinked roots/paths still match.
        let rootPath = root.resolvingSymlinksInPath().path
        let urlPath = url.resolvingSymlinksInPath().path
        guard urlPath == rootPath || urlPath.hasPrefix(rootPath + "/") else { return nil }
        if urlPath == rootPath { return "" }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    // MARK: - Convenience accessors (terminal)

    /// All terminal tabs across all terminal panes.
    var allTerminalTabs: [TerminalTab] { terminal.allTerminalTabs }

    /// Whether any terminal pane exists in the layout.
    var hasTerminalPanes: Bool { !paneManager.terminalPaneIDs.isEmpty }

    func startTerminals() { terminal.startTerminals(workingDirectory: workspace.rootURL) }

    /// Creates a new terminal tab in the last-used terminal pane, or creates a new pane.
    func addTerminalTab() {
        terminal.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: workspace.rootURL
        )
    }

    // MARK: - Editor context for terminal

    /// Pushes the current editor context (active file, cursor position) to the
    /// context file writer. Called when the active tab or cursor position changes.
    func updateEditorContext() {
        guard presentationLifecycle == .visible else { return }
        publishEditorContext(projectRoot: workspace.rootURL)
    }

    /// Captures one complete desired handoff state on the main actor. Every
    /// asynchronous actor command carries a monotonic presentation generation,
    /// so a delayed hidden-window cleanup cannot delete a newer reopen publish
    /// (and a delayed old publish cannot resurrect a cleaned-up snapshot).
    private func publishEditorContext(projectRoot: URL?) {
        guard presentationLifecycle == .visible,
              let rootURL = projectRoot else { return }
        let tab = activeTabManager.activeTab
        let relativePath = ContextFileWriter.relativePath(
            fileURL: tab?.fileURL,
            rootURL: rootURL
        )
        let openFiles = allTabs.compactMap {
            ContextFileWriter.relativePath(
                fileURL: $0.fileURL,
                rootURL: rootURL
            )
        }
        editorContextCommandGeneration &+= 1
        let command = ContextPresentationCommand(
            identity: contextPresentationIdentity,
            sequence: editorContextCommandGeneration
        )
        let isEnabled = AgentHandoffSettings.shared.isReadOnlyContextEnabled
        let cursorLine = tab?.cursorLine
        let cursorColumn = tab?.cursorColumn
        let payload = ContextFileWriter.Payload(
            openFiles: openFiles,
            currentFile: relativePath,
            cursorLine: cursorLine,
            cursorColumn: cursorColumn
        )
        Task {
            await contextFileWriter.publishPresentationSnapshot(
                projectRoot: rootURL,
                isReadOnlySharingEnabled: isEnabled,
                payload: payload,
                command: command
            )
        }
    }

    /// Cleans up the context file. Called when the project window closes.
    func cleanupEditorContext() {
        guard let rootURL = workspace.rootURL else { return }
        editorContextCommandGeneration &+= 1
        let command = ContextPresentationCommand(
            identity: contextPresentationIdentity,
            sequence: editorContextCommandGeneration
        )
        Task {
            await contextFileWriter.cleanupPresentationSnapshot(
                projectRoot: rootURL,
                command: command
            )
        }
    }

    /// Applies the global opt-in to this project and immediately publishes or
    /// revokes its bounded read-only snapshot.
    func synchronizeAgentHandoff(projectRoot: URL? = nil) {
        let rootURL = projectRoot ?? workspace.rootURL
        if presentationLifecycle == .visible, let rootURL {
            publishEditorContext(projectRoot: rootURL)
        } else {
            cleanupEditorContext()
        }
    }

    /// Shuts down all language servers for this project. Called on window
    /// close and app termination so no orphan language-server process
    /// survives (acceptance criterion #1010). Safe to call multiple times.
    func shutdownLanguageServers() {
        lspManager.shutdownAll()
    }

    /// Requests cancellation without waiting. Closing a project window does
    /// not call this: background projects intentionally keep both terminals
    /// and tasks alive.
    func requestUserTaskShutdown() {
        taskRunStore.requestShutdown()
    }

    func captureUserTaskShutdownAuthorization()
        -> UserTaskExecutionAuthorization {
        taskRunStore.captureShutdownAuthorization()
    }

    func userTaskShutdownAuthorizationStillCovers(
        _ authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        taskRunStore.shutdownAuthorizationStillCovers(authorization)
    }

    @discardableResult
    func requestUserTaskShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        taskRunStore.requestShutdown(authorizedBy: authorization)
    }

    @discardableResult
    func waitForUserTaskShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        await taskRunStore.waitForShutdown(
            authorizedBy: authorization,
            until: deadline
        )
    }

    func userTaskShutdownIsPreparedForCommit(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        taskRunStore.shutdownIsPreparedForCommit(
            authorizedBy: authorization
        )
    }

    func commitPreparedUserTaskShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) {
        taskRunStore.commitPreparedShutdown(
            authorizedBy: authorization
        )
    }

    /// Waits for project-owned user tasks only until the shared absolute
    /// deadline, requesting cancellation first when needed.
    @discardableResult
    func shutdownUserTasks(until deadline: DispatchTime) async -> Bool {
        await taskRunStore.shutdownAll(until: deadline)
    }

    /// `true` while destroying this project would drop task cleanup ownership.
    var hasOutstandingUserTaskExecution: Bool {
        taskRunStore.hasOutstandingExecutionOwnership
    }
}
