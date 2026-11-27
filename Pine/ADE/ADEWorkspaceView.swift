//
//  ADEWorkspaceView.swift
//  Pine
//
//  The Pine 3 project window: one project, its tasks, and the selected
//  task's result (#1760).
//

import SwiftUI

/// Restores the project's saved tab set with no editor on screen.
///
/// The window still saves its session on close. Without this restore that
/// save would replace the user's open files with an empty list; with it the
/// saved set is written back unchanged until the editor migration owns it.
@MainActor
enum ADELegacySession {
    static func restoreIfNeeded(projectManager: ProjectManager) {
        guard let rootURL = projectManager.rootURL,
              projectManager.allTabs.isEmpty,
              projectManager.allTerminalTabs.isEmpty,
              let session = SessionState.load(
                for: rootURL, defaults: projectManager.sessionDefaults
              ) else { return }
        let result = ProjectSessionRestorer.restore(
            session, into: projectManager, rootURL: rootURL
        )
        if result.restoredTerminalPanes {
            projectManager.terminal.ensureAgentDetectionStarted()
        }
    }
}

struct ADEWorkspaceView: View {
    @State private var model: ADEWorkspaceModel
    @State private var isAgentInboxPresented = false
    @State private var isOpenCodeTaskPresented = false
    @State private var agentInboxToggleRelay = AgentInboxPopoverToggleRelay()

    private let registry: ProjectRegistry
    private let onInboxSuccessfulNavigation: @MainActor () -> Void
    @Environment(ProjectManager.self) private var projectManager
    @Environment(ProjectWindowSession.self) private var projectWindowSession
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.locale) private var locale

    init(
        projectURL: URL,
        registry: ProjectRegistry,
        onInboxSuccessfulNavigation: @escaping @MainActor () -> Void
    ) {
        self.registry = registry
        self.onInboxSuccessfulNavigation = onInboxSuccessfulNavigation
        #if DEBUG
        ADEWorkspaceUITestFixture.seedIfNeeded(registry: registry, projectURL: projectURL)
        #endif
        _model = State(initialValue: ADEWorkspaceModel(registry: registry, projectURL: projectURL))
    }

    private var projectURL: URL { model.projectURL }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ADEProjectColumn(model: model, registry: registry)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
                .accessibilityIdentifier(AccessibilityID.workspaceProjectColumn)
        } detail: {
            ADEWorkspaceDetail(model: model, registry: registry)
        }
        .navigationTitle(projectURL.lastPathComponent)
        .toolbar {
            // Legacy entry points, kept working until their removal lanes retire them.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isOpenCodeTaskPresented = true
                } label: {
                    Label(Strings.openCodeTaskRequest, systemImage: "arrow.up.message")
                }
                .accessibilityIdentifier(AccessibilityID.openCodeTaskToolbarButton)
            }
            ToolbarItem(placement: .primaryAction) {
                AgentInboxToolbarButton(
                    attentionCount: registry.agentInboxAttentionCount(for: projectURL)
                ) {
                    if !agentInboxToggleRelay.toggle() {
                        isAgentInboxPresented = true
                    }
                }
                .agentInboxPopover(
                    isPresented: $isAgentInboxPresented,
                    registry: registry,
                    toggleRelay: agentInboxToggleRelay,
                    onSuccessfulNavigation: onInboxSuccessfulNavigation
                )
            }
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
        .modifier(UserTaskRunPresenter(store: projectManager.taskRunStore))
        .frame(minWidth: 800, minHeight: 500)
        .background {
            RepresentedFileTracker(url: projectURL)
            WindowTitleVisibilityTracker()
        }
        .accessibilityIdentifier(AccessibilityID.workspace)
        .task {
            // Mounts the live wiring on the stored model exactly once;
            // `State(initialValue:)` constructions during body evaluation
            // stay inert (pure init) and never touch the registry.
            model.activate()
            model.locale = locale
            ADELegacySession.restoreIfNeeded(projectManager: projectManager)
        }
        .onChange(of: controlActiveState, initial: true) { _, _ in
            reconcileKeyPresentation()
        }
        .onChange(of: locale) { _, locale in
            model.locale = locale
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTask)) { notification in
            guard ContentView.shouldHandleTargetedCommand(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key
            ) else { return }
            // A menu click arrives while AppKit is still tracking the menu.
            NativeCommandDelivery.deferToNextMainRunLoop {
                model.startNewTask()
                model.newTaskFocusRequest = UUID()
            }
        }
        .sheet(isPresented: $isOpenCodeTaskPresented) {
            OpenCodeTaskView(
                registry: registry,
                project: model.projectIdentity,
                onDismiss: { isOpenCodeTaskPresented = false }
            )
        }
    }

    /// Becoming key is what makes this the window "here" means: it is where a
    /// project with no window of its own is routed, and where state changes
    /// are spoken.
    private func reconcileKeyPresentation() {
        model.isKey = controlActiveState == .key
        guard model.isKey else { return }
        registry.noteKeyWindowSession(projectWindowSession)
        registry.reconcileKeyProjectPresentation(projectManager)
    }
}

/// The main area: the selected task, or the project overview when none is.
struct ADEWorkspaceDetail: View {
    @Bindable var model: ADEWorkspaceModel
    let registry: ProjectRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let row = model.selectedRow {
                ADETaskDetailView(model: model, registry: registry, row: row)
                    .id(row.id)
                    .transition(.opacity)
            } else {
                ADEProjectOverviewView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(PineAnimation.content(reduceMotion: reduceMotion), value: model.selectedTaskID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
