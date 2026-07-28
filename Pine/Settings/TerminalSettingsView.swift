//
//  TerminalSettingsView.swift
//  Pine
//
//  Issue #337: "Terminal" pane of the consolidated Settings scene.
//  Exposes shell launch settings and terminal appearance in one pane.
//

import SwiftUI

/// Terminal preferences pane.
///
/// Shell and theme changes persist and apply immediately — no Apply button.
/// Theme changes repaint existing project and Quick Terminal sessions through
/// `.terminalThemeChanged` without restarting their processes.
@MainActor
struct TerminalSettingsView: View {
    @Bindable var shell: ShellSettings
    @Bindable var theme: TerminalThemeSettings
    @State private var customArgsText: String
    private let locale: Locale

    init(
        shell: ShellSettings,
        theme: TerminalThemeSettings = .shared,
        locale: Locale = .current
    ) {
        self.shell = shell
        self.theme = theme
        self.locale = locale
        _customArgsText = State(
            initialValue: shell.shellArgs.joined(separator: "\n")
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(Strings.settingsTerminalTitle)
                    .font(.title2.weight(.semibold))

                shellSettings

                argumentSettings

                appearanceSettings

                themeSettings

                quickTerminalSettings
            }
            .padding(20)
        }
        .frame(width: 720, height: 500)
        .environment(\.locale, locale)
    }

    private var shellSettings: some View {
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
    }

    private var argumentSettings: some View {
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
                .disabled(
                    shell.shellArgs == ["--login"]
                        && shell.shellPath == ShellSettings.systemShellPath()
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .onChange(of: customArgsText) { _, newValue in
            shell.shellArgs = parsedArguments(newValue)
        }
    }

    private var appearanceSettings: some View {
        GroupBox(Strings.terminalAppearanceLabel) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    Strings.terminalAppearanceLabel,
                    selection: $theme.appearancePolicy
                ) {
                    ForEach(TerminalAppearancePolicy.allCases, id: \.self) { policy in
                        Text(LocalizedStringKey(policy.nameKey))
                            .tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.terminalAppearancePicker)

                Text(Strings.terminalAppearanceHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var themeSettings: some View {
        GroupBox(Strings.terminalThemeSelectionLabel) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.terminalThemeSettingsSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(TerminalTheme.builtIn) { terminalTheme in
                        themeRow(terminalTheme)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var quickTerminalSettings: some View {
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
    }

    private func themeRow(_ terminalTheme: TerminalTheme) -> some View {
        let isSelected = theme.selectedThemeID == terminalTheme.id
        return Button {
            theme.setTheme(id: terminalTheme.id)
        } label: {
            HStack(spacing: 10) {
                swatchPreview(
                    light: terminalTheme.light,
                    dark: terminalTheme.dark
                )
                .frame(width: 72, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(terminalTheme.nameKey))
                        .foregroundStyle(.primary)
                    Text(Strings.terminalThemePreviewLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal-theme-row-\(terminalTheme.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func swatchPreview(
        light: TerminalColorScheme,
        dark: TerminalColorScheme
    ) -> some View {
        HStack(spacing: 0) {
            swatchHalf(dark)
            swatchHalf(light)
        }
    }

    private func swatchHalf(_ scheme: TerminalColorScheme) -> some View {
        ZStack {
            scheme.background.makeNSColor().terminalSettingsColor
            HStack(spacing: 1) {
                ForEach(0..<8, id: \.self) { index in
                    scheme.ansiColors[index]
                        .makeNSColor()
                        .terminalSettingsColor
                }
            }
            .padding(1)
        }
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

private extension NSColor {
    var terminalSettingsColor: Color {
        let resolved = usingColorSpace(.sRGB) ?? self
        return Color(
            .sRGB,
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            opacity: resolved.alphaComponent
        )
    }
}
