//
//  AgentHandoffSettingsView.swift
//  Pine
//
//  Explicit permission UI for the read-only editor/agent handoff (#933).
//

import SwiftUI
import AppKit

nonisolated enum AgentNotificationSettingsProjection {
    static func projectOptions(
        tasks: [AgentTask]
    ) -> [(path: String, label: String)] {
        let values = tasks
            .filter { $0.route.surface.isProjectBacked }
            .map {
                let path = $0.project.canonicalProjectPath
                return (
                    path,
                    URL(fileURLWithPath: path).lastPathComponent
                )
            }
        return Dictionary(
            values,
            uniquingKeysWith: { current, _ in current }
        )
        .map { (path: $0.key, label: $0.value) }
        .sorted {
            $0.label.localizedStandardCompare($1.label)
                == .orderedAscending
        }
    }
}

@MainActor
struct PineSettingsView: View {
    let lspSettings: LSPSettings
    let handoffSettings: AgentHandoffSettings
    let notificationController: AgentNotificationController
    let agentTasks: AgentTaskRegistry
    let shellSettings: ShellSettings
    let editorSettings: EditorSettings
    let terminalThemeSettings: TerminalThemeSettings
    let terminalCursorSettings: TerminalCursorSettings
    let quickTerminalSettings: QuickTerminalSettings

    /// Persists the last-selected pane across sessions (issue #337).
    @AppStorage(Self.selectedPaneKey) private var selectedPane: SettingsPane.SettingsPaneID = .general

    /// The tab strip is sized from the titles it is about to draw, so the
    /// window follows the locale instead of a fixed 720 pt (#1531).
    @Environment(\.locale) private var locale

    init(
        lspSettings: LSPSettings,
        handoffSettings: AgentHandoffSettings,
        notificationController: AgentNotificationController,
        agentTasks: AgentTaskRegistry,
        shellSettings: ShellSettings,
        editorSettings: EditorSettings,
        terminalThemeSettings: TerminalThemeSettings = .shared,
        terminalCursorSettings: TerminalCursorSettings = .shared,
        quickTerminalSettings: QuickTerminalSettings = .shared
    ) {
        self.lspSettings = lspSettings
        self.handoffSettings = handoffSettings
        self.notificationController = notificationController
        self.agentTasks = agentTasks
        self.shellSettings = shellSettings
        self.editorSettings = editorSettings
        self.terminalThemeSettings = terminalThemeSettings
        self.terminalCursorSettings = terminalCursorSettings
        self.quickTerminalSettings = quickTerminalSettings
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettingsView(
                editor: editorSettings,
                fontSizeSettings: .shared
            )
            .tabItem {
                Label(Strings.settingsTabGeneral, systemImage: "gearshape")
            }
            .tag(SettingsPane.SettingsPaneID.general)

            TerminalSettingsView(
                shell: shellSettings,
                theme: terminalThemeSettings,
                cursor: terminalCursorSettings,
                quickTerminal: quickTerminalSettings
            )
            .tabItem {
                Label(Strings.settingsTabTerminal, systemImage: "terminal")
            }
            .tag(SettingsPane.SettingsPaneID.terminal)

            LSPSettingsView(settings: lspSettings)
                .tabItem {
                    Label(
                        Strings.settingsLanguageServersTab,
                        systemImage: "server.rack"
                    )
                }
                .tag(SettingsPane.SettingsPaneID.languages)

            AgentSettingsView(
                handoffSettings: handoffSettings,
                notificationController: notificationController,
                agentTasks: agentTasks
            )
                .tabItem {
                    Label(
                        Strings.settingsAgentHandoffTab,
                        systemImage: "lock.shield"
                    )
                }
                .tag(SettingsPane.SettingsPaneID.agents)

            KeyBindingsTasksSettingsView()
                .tabItem {
                    Label(
                        Strings.settingsTabKeyBindings,
                        systemImage: "keyboard"
                    )
                }
                .tag(SettingsPane.SettingsPaneID.keyBindings)
        }
        .settingsWindowSize(
            tabTitles: Strings.settingsTabTitles(locale: locale)
        )
        .overlay(alignment: .bottomTrailing) {
            HelpLink(
                anchor: selectedPane.helpAnchor,
                book: PineHelp.bookName
            )
            .accessibilityIdentifier(AccessibilityID.settingsHelpButton)
            .padding(14)
        }
    }

    nonisolated static let selectedPaneKey = "settings.selectedPane"
}

@MainActor
private struct AgentSettingsView: View {
    let handoffSettings: AgentHandoffSettings
    let notificationController: AgentNotificationController
    let agentTasks: AgentTaskRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AgentNotificationSettingsView(
                    controller: notificationController,
                    agentTasks: agentTasks
                )
                Divider()
                AgentHandoffSettingsView(settings: handoffSettings)
                    .frame(
                        minHeight: SettingsWindowMetrics
                            .handoffSectionMinimumHeight
                    )
            }
            .padding(20)
        }
        .settingsPaneSize()
    }
}

@MainActor
private struct AgentNotificationSettingsView: View {
    let controller: AgentNotificationController
    let agentTasks: AgentTaskRegistry

    private var agentOptions: [(String, String)] {
        let values = agentTasks.tasks.map {
            ($0.descriptor.typeIdentifier, $0.descriptor.agentType.displayName)
        }
        return Dictionary(values, uniquingKeysWith: { current, _ in current })
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    private var projectOptions: [(String, String)] {
        AgentNotificationSettingsProjection.projectOptions(
            tasks: agentTasks.tasks
        )
    }

    private var taskOptions: [(UUID, String)] {
        agentTasks.tasks
            .filter { $0.lifecycle != .dismissed }
            .map { task in
                let fallback = task.descriptor.agentType.displayName
                return (task.id, task.title ?? fallback)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.agentNotificationsSettingsTitle)
                .font(.title2.weight(.semibold))
            Text(Strings.agentNotificationsPermissionExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionControl

            GroupBox(Strings.agentNotificationsEvents) {
                VStack(alignment: .leading, spacing: 10) {
                    eventToggle(.waitingInput, Strings.agentNotificationsWaiting)
                    eventToggle(.failed, Strings.agentNotificationsFailed)
                    eventToggle(.completed, Strings.agentNotificationsCompleted)
                    eventToggle(.processEnded, Strings.agentNotificationsProcessEnded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .disabled(!controller.settings.isEnabled)

            if !agentOptions.isEmpty {
                preferenceGroup(
                    Strings.agentNotificationsAgents,
                    options: agentOptions,
                    isEnabled: { !controller.settings.disabledAgentIDs.contains($0) },
                    setEnabled: controller.settings.setAgent
                )
            }
            if !projectOptions.isEmpty {
                preferenceGroup(
                    Strings.agentNotificationsProjects,
                    options: projectOptions,
                    isEnabled: { !controller.settings.disabledProjectPaths.contains($0) },
                    setEnabled: controller.settings.setProject
                )
            }
            if !taskOptions.isEmpty {
                GroupBox(Strings.agentNotificationsTasks) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(taskOptions, id: \.0) { taskID, displayName in
                            Toggle(
                                displayName,
                                isOn: Binding(
                                    get: {
                                        !controller.settings.mutedTaskIDs.contains(taskID)
                                    },
                                    set: {
                                        controller.settings.setTask(taskID, enabled: $0)
                                    }
                                )
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .disabled(!controller.settings.isEnabled)
            }

            Text(Strings.agentNotificationsFocusHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(AccessibilityID.agentNotificationSettings)
        .task { await controller.refreshAuthorizationStatus() }
    }

    @ViewBuilder
    private var permissionControl: some View {
        switch controller.authorizationStatus {
        case .notDetermined:
            Button(Strings.agentNotificationsEnable) {
                Task { await controller.requestAuthorization() }
            }
            .accessibilityIdentifier(AccessibilityID.agentNotificationEnableButton)
        case .denied:
            HStack {
                Label(Strings.agentNotificationsDenied, systemImage: "bell.slash")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(Strings.agentNotificationsOpenSystemSettings) {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        case .authorized:
            Toggle(
                Strings.agentNotificationsMainToggle,
                isOn: Binding(
                    get: { controller.settings.isEnabled },
                    set: {
                        if $0 {
                            controller.settings.setEnabled(true)
                        } else {
                            controller.disable()
                        }
                    }
                )
            )
            .accessibilityIdentifier(AccessibilityID.agentNotificationMainToggle)
        }
    }

    private func eventToggle(
        _ kind: AgentNotificationEventKind,
        _ title: LocalizedStringKey
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { controller.settings.enabledEvents.contains(kind) },
                set: { controller.settings.setEvent(kind, enabled: $0) }
            )
        )
    }

    private func preferenceGroup(
        _ title: LocalizedStringKey,
        options: [(String, String)],
        isEnabled: @escaping (String) -> Bool,
        setEnabled: @escaping (String, Bool) -> Void
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(options, id: \.0) { identifier, displayName in
                    Toggle(
                        displayName,
                        isOn: Binding(
                            get: { isEnabled(identifier) },
                            set: { setEnabled(identifier, $0) }
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .disabled(!controller.settings.isEnabled)
    }
}

/// Identifiers for the Settings scene panes (issue #337). The raw value is
/// persisted so the last-selected pane is restored on reopen.
enum SettingsPane {
    enum SettingsPaneID: String, CaseIterable {
        case general
        case terminal
        case languages
        case agents
        case keyBindings
    }
}

private extension SettingsPane.SettingsPaneID {
    var helpAnchor: NSHelpManager.AnchorName {
        switch self {
        case .general, .keyBindings:
            PineHelp.Anchor.settings
        case .terminal:
            PineHelp.Anchor.terminal
        case .languages:
            PineHelp.Anchor.languageServers
        case .agents:
            PineHelp.Anchor.agentSettings
        }
    }
}

@MainActor
struct AgentHandoffSettingsView: View {
    let settings: AgentHandoffSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.agentHandoffSettingsTitle)
                .font(.title2.weight(.semibold))

            Toggle(
                isOn: Binding(
                    get: { settings.isReadOnlyContextEnabled },
                    set: { settings.setReadOnlyContextEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.agentHandoffReadOnlyContext)
                    Text(Strings.agentHandoffReadOnlyContextHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(
                AccessibilityID.agentHandoffReadOnlyContextToggle
            )

            Divider()

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    handoffGuarantee(
                        Strings.agentHandoffMetadataOnly,
                        systemImage: "doc.text.magnifyingglass"
                    )
                    handoffGuarantee(
                        Strings.agentHandoffNoMutation,
                        systemImage: "hand.raised"
                    )
                    handoffGuarantee(
                        Strings.agentHandoffNewTerminals,
                        systemImage: "terminal"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Label(
                    Strings.agentHandoffSecurityBoundary,
                    systemImage: "lock.shield"
                )
            }

            Label(
                settings.isReadOnlyContextEnabled
                    ? Strings.agentHandoffStatusEnabled
                    : Strings.agentHandoffStatusDisabled,
                systemImage: settings.isReadOnlyContextEnabled
                    ? "checkmark.circle.fill"
                    : "circle.slash"
            )
            .foregroundStyle(
                settings.isReadOnlyContextEnabled ? Color.green : .secondary
            )
            .accessibilityIdentifier(AccessibilityID.agentHandoffStatus)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func handoffGuarantee(
        _ text: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
