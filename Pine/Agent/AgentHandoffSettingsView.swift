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

    var body: some View {
        TabView {
            LSPSettingsView(settings: lspSettings)
                .tabItem {
                    Label(
                        Strings.settingsLanguageServersTab,
                        systemImage: "server.rack"
                    )
                }

            AgentHandoffSettingsView(settings: handoffSettings)
                .tabItem {
                    Label(
                        Strings.settingsAgentHandoffTab,
                        systemImage: "lock.shield"
                    )
                }

            QuickTerminalSettingsView(settings: .shared)
                .tabItem {
                    Label(
                        Strings.settingsQuickTerminalTab,
                        systemImage: "terminal"
                    )
                }
        }
        .frame(width: 720, height: 540)
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
