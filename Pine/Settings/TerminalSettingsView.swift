//
//  TerminalSettingsView.swift
//  Pine
//
//  Issue #337: "Terminal" pane of the consolidated Settings scene.
//  Exposes the shell path and launch arguments (ShellSettings) with the
//  same immediate-apply semantics as the rest of the scene, and links to
//  the Quick Terminal controls.
//

import SwiftUI

/// Terminal preferences pane.
///
/// Shell path and arguments bind directly to `ShellSettings`, which persists
/// via `UserDefaults` `didSet` on every change — no Apply button. The Quick
/// Terminal section summarizes the global hotkey and offers entry points to
/// its controls; the hotkey itself is managed by `QuickTerminalController`
/// and cannot be rebound here yet (tracked as a follow-up).
@MainActor
struct TerminalSettingsView: View {
    @Bindable var shell: ShellSettings
    @State private var customArgsText: String

    init(shell: ShellSettings) {
        self.shell = shell
        _customArgsText = State(
            initialValue: shell.shellArgs.joined(separator: "\n")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.settingsTerminalTitle)
                .font(.title2.weight(.semibold))

            GroupBox(Strings.settingsTerminalShell) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(Strings.settingsTerminalShellPicker, selection: shellPathBinding) {
                        ForEach(ShellSettings.commonShells) { option in
                            Text(option.name)
                                .tag(option.path)
                        }
                        if !ShellSettings.commonShells.contains(where: { $0.path == shell.shellPath }) {
                            Text(shell.shellPath)
                                .tag(shell.shellPath)
                        }
                        Text(Strings.settingsTerminalShellOther)
                            .tag(String?.none)
                    }

                    if !isPresetPath {
                        TextField(
                            Strings.settingsTerminalShellPathPlaceholder,
                            text: shellPathTextBinding
                        )
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    }

                    (Text(Strings.settingsTerminalResolvedPrefix) + Text(verbatim: shell.resolvedShellPath))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(Strings.settingsTerminalArguments) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Strings.settingsTerminalArgumentsHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $customArgsText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        }
                        .frame(minHeight: 70)

                    Button(Strings.settingsTerminalResetArgs) {
                        shell.reset()
                        customArgsText = shell.shellArgs.joined(separator: "\n")
                    }
                    .disabled(shell.shellArgs == ["--login"] && shell.shellPath == ShellSettings.systemShellPath())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onChange(of: customArgsText) { _, newValue in
                shell.shellArgs = parsedArguments(newValue)
            }

            GroupBox(Strings.settingsTerminalQuickTerminal) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        Strings.settingsTerminalQuickTerminalHotkey,
                        systemImage: "keyboard"
                    )
                    .foregroundStyle(.secondary)
                    Text(Strings.settingsTerminalQuickTerminalHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 500)
    }

    // MARK: - Bindings

    /// The picker uses an optional tag so "Other…" can be selected. When the
    /// user picks "Other…", we keep the current path and reveal the text field.
    private var shellPathBinding: Binding<String?> {
        Binding(
            get: { isPresetPath ? shell.shellPath : nil },
            set: { selection in
                if let path = selection {
                    if let option = ShellSettings.commonShells.first(where: { $0.path == path }) {
                        shell.shellPath = option.path
                        shell.shellArgs = option.defaultArgs
                        customArgsText = option.defaultArgs.joined(separator: "\n")
                    } else {
                        shell.shellPath = path
                    }
                }
            }
        )
    }

    private var shellPathTextBinding: Binding<String> {
        Binding(
            get: { shell.shellPath },
            set: { shell.shellPath = $0 }
        )
    }

    private var isPresetPath: Bool {
        ShellSettings.commonShells.contains { $0.path == shell.shellPath }
    }

    /// Each line is one literal process argument — mirrors the LSP arguments
    /// convention. No shell tokenization is performed.
    private func parsedArguments(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
