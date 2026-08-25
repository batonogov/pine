//
//  ProjectWindowSession.swift
//  Pine
//
//  One native window containing several independent project contexts.
//

import CryptoKit
import Foundation
import Observation

nonisolated struct ProjectAgentLaunchOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let command: String

    @MainActor
    var descriptor: AgentDescriptor {
        AgentDescriptor(
            agentType: AgentType(stableIdentifier: id)
                ?? .generic(name: displayName),
            launchExecutable: command
        )
    }
}

nonisolated struct ProjectWindowGroup: Identifiable, Equatable, Sendable {
    let projectURL: URL
    let worktrees: [AgentManagedWorktree]

    var id: URL { projectURL }
}

enum ProjectWindowRestorationResult: Equatable {
    case restored
    case unavailable
    case alreadyRestored
}

@MainActor
@Observable
final class ProjectWindowSession {
    private struct PersistedState: Codable {
        let version: Int
        let projectURLs: [URL]
        let worktrees: [AgentManagedWorktree]
        let activeURL: URL
        /// Set once the user closes the project this window's scene is keyed
        /// by. Optional so states written before project closing existed still
        /// decode, and so the version does not have to move.
        let closedAnchor: Bool?
    }

    let id = UUID()
    let sceneProjectURL: URL

    /// The project this scene was created for, before any persisted state had
    /// a say. An explicit open request is matched against this — not against
    /// ``sceneProjectURL``, which is the anchor of whatever window adopts it.
    let requestedProjectURL: URL

    private(set) var projectURLs: [URL]
    private(set) var managedWorktrees: [URL: AgentManagedWorktree]
    private(set) var activeProjectURL: URL
    private(set) var isLaunchingAgent = false
    var alertMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let worktreeService: AgentWorktreeService
    @ObservationIgnored private let toolResolver: ExternalToolResolver
    @ObservationIgnored private var backgroundLeases: [URL: UUID] = [:]
    @ObservationIgnored private var pendingRestoredActiveURL: URL?
    @ObservationIgnored private var didRestore = false
    /// Whether anything has moved this window off the project its scene was
    /// created with. Distinguishes a fresh scene from one routing has already
    /// placed, which decides whether a pending open request still applies.
    @ObservationIgnored private var didTransition = false
    /// Whether the user closed the project this scene is keyed by. Persisted,
    /// because the reopening scene would otherwise hand that project straight
    /// back on the next launch.
    @ObservationIgnored private var didCloseAnchor = false

    init(
        initialProjectURL: URL,
        defaults: UserDefaults = .standard,
        worktreeService: AgentWorktreeService = AgentWorktreeService(),
        toolResolver: ExternalToolResolver = .fromEnvironment()
    ) {
        let initial = initialProjectURL.standardizedFileURL
        requestedProjectURL = initial
        self.defaults = defaults
        self.worktreeService = worktreeService
        self.toolResolver = toolResolver
        let anchor = Self.persistenceAnchor(
            for: initial,
            defaults: defaults
        )
        sceneProjectURL = anchor

        if let restored = Self.loadState(
            for: anchor,
            defaults: defaults
        ) {
            var projects = restored.projectURLs.map(\.standardizedFileURL)
            var worktrees: [URL: AgentManagedWorktree] = [:]
            for worktree in restored.worktrees {
                worktrees[worktree.worktreeRoot.standardizedFileURL] = worktree
            }
            // The scene is keyed by the anchor project, so a window reopening
            // always arrives asking for it. Re-adding it is right for a window
            // that simply never had it — and wrong once the user closed it
            // here, which would otherwise resurrect the project on every
            // relaunch. `projects` is never emptied by closing (the last one
            // closes the window instead), so this cannot leave a window with
            // nothing to show.
            let didCloseAnchor = restored.closedAnchor == true
                && initial == anchor
                && !projects.isEmpty
            if worktrees[initial] == nil,
               !projects.contains(initial),
               !didCloseAnchor {
                projects.insert(initial, at: 0)
            }
            let uniqueProjects = Self.uniqued(projects)
            projectURLs = uniqueProjects
            managedWorktrees = worktrees
            self.didCloseAnchor = didCloseAnchor
            let restoredActive = restored.activeURL.standardizedFileURL
            let members = Set(uniqueProjects + Array(worktrees.keys))
            let restoredIsMember = members.contains(restoredActive)
            // With the anchor gone it is not a candidate for the active
            // project either; fall back to whatever the window does hold.
            activeProjectURL = didCloseAnchor
                ? (restoredIsMember ? restoredActive : uniqueProjects[0])
                : initial
            pendingRestoredActiveURL = initial == anchor && restoredIsMember
                ? restoredActive
                : activeProjectURL
        } else {
            projectURLs = [initial]
            managedWorktrees = [:]
            activeProjectURL = initial
            // A restored SwiftUI WindowGroup scene starts with a fresh
            // ProjectRegistry. Treat its scene value as restoration work even
            // when this window never wrote multi-project state of its own.
            pendingRestoredActiveURL = initial
        }
    }

    var groups: [ProjectWindowGroup] {
        projectURLs.map { projectURL in
            ProjectWindowGroup(
                projectURL: projectURL,
                worktrees: managedWorktrees.values
                    .filter { $0.repositoryRoot == projectURL }
                    .sorted { lhs, rhs in
                        if lhs.branchName != rhs.branchName {
                            return lhs.branchName < rhs.branchName
                        }
                        return lhs.taskID.uuidString < rhs.taskID.uuidString
                    }
            )
        }
    }

    /// Whether this window holds `url` — as one of its projects, or as an
    /// agent worktree hanging off one. Callers routing to a project (the Agent
    /// Inbox, a notification) ask this to find the window that already owns it
    /// instead of opening a second one.
    ///
    /// Expects an already-canonical URL: the window stores standardized paths,
    /// and resolving symlinks here would suspend a synchronous lookup.
    func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        return projectURLs.contains(target) || managedWorktrees[target] != nil
    }

    #if DEBUG
    /// Seeds a managed worktree without running the real create/launch path,
    /// so membership and close behaviour can be tested without a repository.
    func adoptWorktreeForTesting(_ worktree: AgentManagedWorktree) {
        managedWorktrees[worktree.worktreeRoot.standardizedFileURL] = worktree
    }

    /// The defaults key a window with this anchor persists under. Lets a test
    /// plant a state written by an older build.
    static func persistenceKeyForTesting(for projectURL: URL) -> String {
        persistenceKey(for: projectURL)
    }
    #endif

    var activeRepositoryURL: URL {
        managedWorktrees[activeProjectURL]?.repositoryRoot
            ?? activeProjectURL
    }

    /// Display name per project root, each shortened to the least path that
    /// still tells it apart from the others in this window. Two checkouts
    /// named `infra` are ordinary in a monorepo-per-client layout, and the
    /// switcher has to be readable in that case, not just in the easy one.
    var projectDisplayNames: [URL: String] {
        ProjectDisplayNames.resolve(for: projectURLs)
    }

    /// Name for one root of this window. A URL the window does not hold —
    /// a worktree root, or a project already removed — keeps its folder name:
    /// there is nothing here for it to collide with.
    func displayName(for url: URL) -> String {
        projectDisplayNames[url.standardizedFileURL] ?? url.lastPathComponent
    }

    /// The active repository alone, with no branch suffix. This is what the
    /// window title falls back to when no file is open.
    var activeProjectDisplayName: String {
        displayName(for: activeRepositoryURL)
    }

    var activeDisplayName: String {
        let projectName = activeProjectDisplayName
        guard let worktree = managedWorktrees[activeProjectURL] else {
            return projectName
        }
        return "\(projectName) — \(Self.shortBranchName(worktree.branchName))"
    }

    var availableAgentOptions: [ProjectAgentLaunchOption] {
        let options = FirstPartyAgentCompatibilityCatalog.records.compactMap { record ->
            ProjectAgentLaunchOption? in
            let commands = record.executableAliases.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs < rhs
            }
            guard let command = commands.first(where: {
                toolResolver.resolve(tool: $0) != nil
            }) else { return nil }
            return ProjectAgentLaunchOption(
                id: record.stableIdentifier,
                displayName: record.displayName,
                command: command
            )
        }
        let lastIdentifier = defaults.string(
            forKey: Self.lastAgentIdentifierKey
        )
        return options.sorted { lhs, rhs in
            if lhs.id == lastIdentifier { return true }
            if rhs.id == lastIdentifier { return false }
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    func restoreIfNeeded(
        registry: ProjectRegistry
    ) async -> ProjectWindowRestorationResult {
        guard !didRestore else { return .alreadyRestored }
        didRestore = true
        var pendingTarget = pendingRestoredActiveURL
        pendingRestoredActiveURL = nil
        // A named request outranks a remembered one. Restoring the project
        // this window last showed is right when macOS is putting the window
        // back, and wrong when the user just picked a project by name — those
        // two arrive as the same scene, so the request has to say which it is
        // (#1543).
        //
        // Spend the request either way, but only act on it while this window
        // is still where its scene left it: routing (the Agent Inbox, a
        // notification) can reach a scene before its restore task runs, and a
        // request must not undo a placement the window has already made.
        let hasExplicitRequest = registry.consumeExplicitProjectOpenRequest(
            for: requestedProjectURL
        )
        if hasExplicitRequest, !didTransition {
            readmitRequestedProject()
            pendingTarget = requestedProjectURL
        }
        guard let target = pendingTarget else {
            return .unavailable
        }
        await activate(target, registry: registry, reportFailure: false)
        guard registry.projectManagerIfAdmitted(for: activeProjectURL) != nil
        else { return .unavailable }
        // `activate` only persists when it actually switches, and the common
        // case here is that it did not have to. Write the honoured request
        // through anyway so the window stops remembering a project the user
        // has moved off.
        saveState()
        return .restored
    }

    /// Puts the requested project back into this window's membership when the
    /// user closed it out of the window earlier. Reopening a project by name
    /// asks for it to be here again; without this the scene would restore with
    /// the project absent from `projectURLs` and nothing to show.
    private func readmitRequestedProject() {
        guard managedWorktrees[requestedProjectURL] == nil,
              !projectURLs.contains(requestedProjectURL) else { return }
        projectURLs.insert(requestedProjectURL, at: 0)
        if requestedProjectURL == sceneProjectURL {
            didCloseAnchor = false
        }
    }

    func openProject(
        _ url: URL,
        registry: ProjectRegistry,
        allowAlreadyOpenTarget: Bool = false
    ) async {
        guard !isLaunchingAgent else { return }
        let canonical = registry.canonicalProjectURL(url)
        let belongsToSession = projectURLs.contains(canonical)
            || managedWorktrees[canonical] != nil
        guard allowAlreadyOpenTarget
                || belongsToSession
                || !registry.isWindowOpen(canonical) else {
            alertMessage = Strings.projectSwitcherAlreadyOpenText
            return
        }
        if !projectURLs.contains(canonical) {
            projectURLs.append(canonical)
        }
        await activate(canonical, registry: registry)
    }

    func activate(
        _ url: URL,
        registry: ProjectRegistry,
        reportFailure: Bool = true
    ) async {
        guard !isLaunchingAgent else { return }
        let target = url.standardizedFileURL

        let manager: ProjectManager?
        if let worktree = managedWorktrees[target] {
            manager = await registry.projectManager(for: worktree)
        } else {
            manager = registry.projectManager(for: target)
        }
        guard let manager else {
            if reportFailure {
                alertMessage = Strings.projectSwitcherOpenFailureText(
                    target.lastPathComponent
                )
            }
            removeUnavailableTarget(target)
            return
        }
        guard target != activeProjectURL else {
            _ = registry.reconcileKeyProjectPresentation(manager)
            return
        }

        transition(
            to: target,
            manager: manager,
            registry: registry
        )
    }

    /// Whether ``closeProject(_:registry:)`` can take `url` out of this window.
    ///
    /// False for the last project: a window with nothing in it is not a state
    /// this app has, so the caller closes the window instead.
    func canCloseProject(_ url: URL) -> Bool {
        guard !isLaunchingAgent, projectURLs.count > 1 else { return false }
        return projectURLs.contains(url.standardizedFileURL)
    }

    /// Takes a project out of this window, leaving it running in the
    /// background exactly as closing its window would.
    ///
    /// Nothing is destroyed: `closeProject` on the registry suspends the
    /// manager, and terminals and agents keep running. A project with unsaved
    /// work or a live agent is pinned against background reclamation by
    /// ``ProjectManager/requiresBackgroundRetention``, so what the user gets
    /// back through Open Recent is the project as they left it.
    ///
    /// Agent worktrees created off this project leave with it — they are its
    /// children in the switcher and would otherwise outlive their heading.
    @discardableResult
    func closeProject(_ url: URL, registry: ProjectRegistry) async -> Bool {
        let target = registry.canonicalProjectURL(url).standardizedFileURL
        guard canCloseProject(target),
              let successor = successorAfterClosing(target) else {
            return false
        }

        let departingWorktrees = managedWorktrees.filter {
            $0.value.repositoryRoot.standardizedFileURL == target
        }
        // Switch away first: the transition suspends whatever is on screen
        // through the normal path, so the closing project never has to be
        // torn down mid-display.
        let isShowingDepartingProject = activeProjectURL == target
            || departingWorktrees[activeProjectURL] != nil
        if isShowingDepartingProject {
            await activate(successor, registry: registry)
            guard activeProjectURL == successor else { return false }
        }

        for worktreeRoot in departingWorktrees.keys {
            managedWorktrees[worktreeRoot] = nil
            releaseBackgroundLease(for: worktreeRoot, registry: registry)
            registry.closeProject(worktreeRoot)
        }
        projectURLs.removeAll { $0 == target }
        // A presentation lease outlives the window that took it, and a leased
        // project is never reclaimed. Hand it back, or the project leaks for
        // the rest of the session.
        releaseBackgroundLease(for: target, registry: registry)
        registry.closeProject(target)
        if target == sceneProjectURL {
            didCloseAnchor = true
        }
        saveState()
        return true
    }

    /// The project to show once `target` leaves: the one after it, or the one
    /// before when it was last.
    private func successorAfterClosing(_ target: URL) -> URL? {
        guard let index = projectURLs.firstIndex(of: target) else { return nil }
        let following = projectURLs.index(after: index)
        if following < projectURLs.endIndex {
            return projectURLs[following]
        }
        return index > projectURLs.startIndex
            ? projectURLs[projectURLs.index(before: index)]
            : nil
    }

    private func releaseBackgroundLease(
        for url: URL,
        registry: ProjectRegistry
    ) {
        guard let leaseID = backgroundLeases.removeValue(forKey: url) else {
            return
        }
        registry.releaseBackgroundProjectPresentation(leaseID, for: url)
    }

    func launchAgent(
        _ option: ProjectAgentLaunchOption,
        registry: ProjectRegistry
    ) async {
        guard !isLaunchingAgent else { return }
        isLaunchingAgent = true
        defer { isLaunchingAgent = false }

        guard toolResolver.resolve(tool: option.command) != nil else {
            alertMessage = Strings.projectSwitcherAgentMissingText(
                option.displayName
            )
            return
        }

        let repository = activeRepositoryURL.standardizedFileURL
        let worktreeID = UUID()
        let managedRoot: URL
        do {
            managedRoot = try await Task.detached(priority: .utility) {
                try Self.prepareManagedRoot(for: repository)
            }.value
        } catch {
            alertMessage = Strings.projectSwitcherWorktreeFailureText(
                error.localizedDescription
            )
            return
        }

        let branch = Self.branchName(
            agentIdentifier: option.id,
            worktreeID: worktreeID
        )
        let result = await worktreeService.create(AgentWorktreeCreateRequest(
            taskID: worktreeID,
            repositoryRoot: repository,
            managedRoot: managedRoot,
            branchName: branch,
            startPoint: "HEAD"
        ))
        guard case .created(let worktree) = result else {
            alertMessage = Strings.projectSwitcherWorktreeFailureText(
                Self.worktreeFailureDescription(result)
            )
            return
        }
        guard let manager = await registry.projectManager(for: worktree) else {
            alertMessage = Strings.projectSwitcherOpenFailureText(
                worktree.worktreeRoot.lastPathComponent
            )
            return
        }

        if !projectURLs.contains(repository) {
            projectURLs.append(repository)
        }
        managedWorktrees[worktree.worktreeRoot.standardizedFileURL] = worktree
        transition(
            to: worktree.worktreeRoot,
            manager: manager,
            registry: registry
        )
        saveState()

        let launch = await manager.terminal.launchAgentInNewTerminal(
            option.command,
            descriptor: option.descriptor,
            workingDirectory: worktree.worktreeRoot
        )
        guard case .reserved = launch else {
            alertMessage = Strings.projectSwitcherAgentLaunchFailureText(
                option.displayName
            )
            return
        }
        defaults.set(option.id, forKey: Self.lastAgentIdentifierKey)
    }

    func windowDidClose(registry: ProjectRegistry) {
        for (url, leaseID) in backgroundLeases {
            registry.releaseBackgroundProjectPresentation(
                leaseID,
                for: url
            )
        }
        backgroundLeases.removeAll()
        saveState()
    }

    func worktreeTask(
        _ worktree: AgentManagedWorktree,
        registry: ProjectRegistry
    ) -> AgentTask? {
        registry.agentTasks.tasks
            .filter {
                $0.project.canonicalProjectPath
                    == worktree.repositoryRoot.path
                    && $0.project.canonicalWorktreePath
                        == worktree.worktreeRoot.path
            }
            .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
    }

    private func transition(
        to target: URL,
        manager: ProjectManager,
        registry: ProjectRegistry
    ) {
        let previous = activeProjectURL
        if let previousManager = registry.projectManagerIfAdmitted(
            for: previous
        ) {
            if backgroundLeases[previous] == nil,
               let leaseID = registry.retainBackgroundProjectForPresentation(
                   previous,
                   manager: previousManager
               ) {
                backgroundLeases[previous] = leaseID
            }
            registry.closeProjectWindow(
                previous,
                expectedManager: previousManager,
                expectedWindowGeneration: nil
            )
        }

        if let leaseID = backgroundLeases.removeValue(forKey: target) {
            registry.releaseBackgroundProjectPresentation(
                leaseID,
                for: target
            )
        }
        _ = registry.reconcileKeyProjectPresentation(manager)
        activeProjectURL = target
        didTransition = true
        saveState()
    }

    private func removeUnavailableTarget(_ target: URL) {
        managedWorktrees[target] = nil
        if target != sceneProjectURL {
            projectURLs.removeAll { $0 == target }
        }
        saveState()
    }

    private func saveState() {
        let state = PersistedState(
            version: 1,
            projectURLs: projectURLs,
            worktrees: Array(managedWorktrees.values),
            activeURL: activeProjectURL,
            closedAnchor: didCloseAnchor
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: persistenceKey)
        saveMembershipIndex()
    }

    private func saveMembershipIndex() {
        var membership = defaults.dictionary(
            forKey: Self.membershipIndexKey
        ) as? [String: String] ?? [:]
        membership = membership.filter { _, anchorPath in
            anchorPath != sceneProjectURL.path
        }
        let memberURLs = projectURLs + Array(managedWorktrees.keys)
        for url in memberURLs {
            membership[url.standardizedFileURL.path] = sceneProjectURL.path
        }
        defaults.set(membership, forKey: Self.membershipIndexKey)
    }

    private var persistenceKey: String {
        Self.persistenceKey(for: sceneProjectURL)
    }

    private static func loadState(
        for projectURL: URL,
        defaults: UserDefaults
    ) -> PersistedState? {
        guard let data = defaults.data(
            forKey: persistenceKey(for: projectURL)
        ), let state = try? JSONDecoder().decode(
            PersistedState.self,
            from: data
        ), state.version == 1 else { return nil }
        return state
    }

    private static func persistenceAnchor(
        for initialURL: URL,
        defaults: UserDefaults
    ) -> URL {
        guard let membership = defaults.dictionary(
            forKey: membershipIndexKey
        ) as? [String: String],
        let anchorPath = membership[initialURL.path] else {
            return initialURL
        }
        let anchor = URL(
            fileURLWithPath: anchorPath,
            isDirectory: true
        ).standardizedFileURL
        guard let state = loadState(for: anchor, defaults: defaults) else {
            return initialURL
        }
        let members = Set(
            state.projectURLs.map { $0.standardizedFileURL.path }
                + state.worktrees.map {
                    $0.worktreeRoot.standardizedFileURL.path
                }
        )
        return members.contains(initialURL.path) ? anchor : initialURL
    }

    private static func persistenceKey(for projectURL: URL) -> String {
        let digest = SHA256.hash(data: Data(projectURL.path.utf8))
        let hex = digest.prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
        return "projectWindowSession.\(hex)"
    }

    nonisolated private static func prepareManagedRoot(
        for repository: URL
    ) throws -> URL {
        let digest = SHA256.hash(data: Data(repository.path.utf8))
        let name = digest.prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Pine", isDirectory: true)
            .appendingPathComponent("AgentWorktrees", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root.standardizedFileURL
    }

    private static func branchName(
        agentIdentifier: String,
        worktreeID: UUID
    ) -> String {
        let safeAgent = String(agentIdentifier.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
        let prefix = String(worktreeID.uuidString.lowercased().prefix(8))
        return "pine/agent/\(safeAgent)/\(prefix)"
    }

    private static func shortBranchName(_ branch: String) -> String {
        branch.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private static func worktreeFailureDescription(
        _ result: AgentWorktreeCreateResult
    ) -> String {
        guard case .failed(let failure) = result else { return "" }
        switch failure {
        case .invalidRepository:
            return String(localized: "projectSwitcher.error.notGitRepository")
        case .destinationAlreadyExists:
            return String(localized: "projectSwitcher.error.destinationExists")
        case .gitRejected(let message):
            return message
        default:
            return String(describing: failure)
        }
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static let lastAgentIdentifierKey =
        "projectWindowSession.lastAgentIdentifier"
    private static let membershipIndexKey =
        "projectWindowSession.membership"
}
