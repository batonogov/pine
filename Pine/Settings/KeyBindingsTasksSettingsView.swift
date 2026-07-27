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
    @State private var reloadSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.settingsKeyBindingsTitle)
                .font(.title2.weight(.semibold))

            configSection(
                title: Strings.settingsKeyBindingsKeybindings,
                fileURL: UserConfigurationPaths.userKeybindingsFile,
                count: ExtensibilityManager.shared.keybindings.count,
                openAction: { Task { await UserConfigurationEditor.openKeybindings() } }
            )

            configSection(
                title: Strings.settingsKeyBindingsTasks,
                fileURL: UserConfigurationPaths.userTasksFile,
                count: ExtensibilityManager.shared.tasks.count,
                openAction: { Task { await UserConfigurationEditor.openTasks() } }
            )

            effectiveBindings

            HStack {
                Button(Strings.settingsKeyBindingsReload) {
                    Task {
                        await Self.reloadAndRefresh()
                        reloadSummary = Self.reloadSummaryText()
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
                    Text(Strings.settingsKeyBindingsActiveCount(count))
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
        let entries = ExtensibilityManager.shared.keybindings.entries
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
                        ForEach(entries, id: \.self) { entry in
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
    private static func reloadSummaryText() -> String {
        let report = ExtensibilityManager.shared.lastReloadReport
        if let report, report.diagnostics.isEmpty {
            return String(
                localized: "settings.keyBindings.reloadSuccess \\\(report.tasks.activeEntryCount) \\\(report.keybindings.activeEntryCount)",
                defaultValue: "Reloaded: \(report.tasks.activeEntryCount) tasks, \(report.keybindings.activeEntryCount) keybindings."
            )
        }
        if let report, !report.diagnostics.isEmpty {
            return String(
                localized: "settings.keyBindings.reloadHadProblems \\\(report.diagnostics.count)",
                defaultValue: "Reloaded with \(report.diagnostics.count) problem(s)."
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
