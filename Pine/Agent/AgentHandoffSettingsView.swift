//
//  AgentHandoffSettingsView.swift
//  Pine
//
//  Explicit permission UI for the read-only editor/agent handoff (#933).
//

import SwiftUI

@MainActor
struct PineSettingsView: View {
    let lspSettings: LSPSettings
    let handoffSettings: AgentHandoffSettings
    let shellSettings: ShellSettings
    let editorSettings: EditorSettings

    /// Persists the last-selected pane across sessions (issue #337).
    @AppStorage(Self.selectedPaneKey) private var selectedPane: SettingsPane.SettingsPaneID = .general

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

            TerminalSettingsView(shell: shellSettings)
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

            AgentHandoffSettingsView(settings: handoffSettings)
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
        .frame(width: 720, height: 540)
    }

    nonisolated static let selectedPaneKey = "settings.selectedPane"
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
        .frame(width: 720, height: 500)
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
