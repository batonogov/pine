//
//  KeyBindingsTasksSettingsView.swift
//  Pine
//
//  Issue #337: "Key Bindings & Tasks" pane of the consolidated Settings
//  scene. This pane is read-only discovery: it reports where the user
//  configuration files live, how many entries are active, and which
//  commands are bound. Editing happens through the Tasks menu (which opens
//  the JSON files in the user's editor) and reloading — the same entry
//  points already wired into the menu bar.
//

import SwiftUI

/// Key Bindings & Tasks preferences pane.
///
/// The pane does not mutate configuration directly. Instead it surfaces:
/// - The discovery paths for `keybindings.json` and `tasks.json`
/// - The effective entry counts from the shared registries
/// - The list of currently bound commands (built-in + overrides)
/// - Entry points to open / reload the configuration files
///
/// All counts reflect the live `ExtensibilityManager.shared` registries, so
/// they update immediately after a reload.
@MainActor
struct KeyBindingsTasksSettingsView: View {
    struct Presentation {
        let keybindingsFileURL: URL
        let keybindingCount: Int
        let tasksFileURL: URL
        let taskCount: Int
        let effectiveEntries: [ResolvedUserKeybinding]
    }

    @Environment(\.locale) private var locale
    @State private var reloadSummary: String?
    private let presentation: Presentation?

    init(presentation: Presentation? = nil) {
        self.presentation = presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.settingsKeyBindingsTitle)
                .font(.title2.weight(.semibold))

            configSection(
                title: Strings.settingsKeyBindingsKeybindings,
                fileURL:
                    presentation?.keybindingsFileURL
                    ?? UserConfigurationPaths.userKeybindingsFile,
                count:
                    presentation?.keybindingCount
                    ?? ExtensibilityManager.shared.keybindings.count,
                openAction: {
                    let presenter = AppKitUserConfigurationAlertPresenter(
                        context: DialogPresenter.forKeyWindow()
                    )
                    Task {
                        await UserConfigurationEditor.openKeybindings(
                            alertPresenter: presenter
                        )
                    }
                }
            )

            configSection(
                title: Strings.settingsKeyBindingsTasks,
                fileURL:
                    presentation?.tasksFileURL
                    ?? UserConfigurationPaths.userTasksFile,
                count:
                    presentation?.taskCount
                    ?? ExtensibilityManager.shared.tasks.count,
                openAction: {
                    let presenter = AppKitUserConfigurationAlertPresenter(
                        context: DialogPresenter.forKeyWindow()
                    )
                    Task {
                        await UserConfigurationEditor.openTasks(
                            alertPresenter: presenter
                        )
                    }
                }
            )

            effectiveBindings

            HStack {
                Button(Strings.settingsKeyBindingsReload) {
                    Task {
                        await Self.reloadAndRefresh()
                        reloadSummary = Self.reloadSummaryText(locale: locale)
                    }
                }
                if let reloadSummary {
                    Text(reloadSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .accessibilityIdentifier(
            AccessibilityID.keyBindingsSettingsPane
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private func configSection(
        title: LocalizedStringKey,
        fileURL: URL,
        count: Int,
        openAction: @escaping () -> Void
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Strings.settingsKeyBindingsActiveCount(
                        count,
                        locale: locale
                    ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(Strings.settingsKeyBindingsOpenFile, action: openAction)
                }
                Text(fileURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var effectiveBindings: some View {
        let entries =
            presentation?.effectiveEntries
            ?? ExtensibilityManager.shared.keybindings.entries
        GroupBox(Strings.settingsKeyBindingsEffective) {
            if entries.isEmpty {
                Text(Strings.settingsKeyBindingsNoOverrides)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(entry.command.localizedTitle)
                                    .lineLimit(1)
                                Spacer()
                                Text(Self.chordDescription(entry.chord))
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func reloadAndRefresh() async {
        await ExtensibilityManager.shared.reload()
    }

    @MainActor
    private static func reloadSummaryText(locale: Locale) -> String {
        let report = ExtensibilityManager.shared.lastReloadReport
        if let report, report.diagnostics.isEmpty {
            return Strings.settingsKeyBindingsReloadSummary(
                tasks: report.tasks.activeEntryCount,
                keybindings: report.keybindings.activeEntryCount,
                locale: locale
            )
        }
        if let report, !report.diagnostics.isEmpty {
            return Strings.settingsKeyBindingsReloadProblems(
                report.diagnostics.count,
                locale: locale
            )
        }
        return ""
    }

    /// Renders a `ParsedKeyChord` as a human-readable shortcut string
    /// (e.g. `cmd+shift+f`). Modifiers are listed in a stable order.
    static func chordDescription(_ chord: ParsedKeyChord) -> String {
        var parts: [String] = []
        let modifiers = chord.modifiers
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(chord.key)
        return parts.joined(separator: "+")
    }
}
