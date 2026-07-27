//
//  TerminalSettingsView.swift
//  Pine
//
//  Settings pane for terminal themes and appearance policy (#1244).
//
//  Shows a theme selector (curated built-in themes), an appearance policy
//  picker (Follow System / Always Light / Always Dark), and a live preview
//  swatch grid. All changes apply immediately — the selected theme's colors
//  are applied to every live terminal session through the
//  `terminalThemeChanged` notification.
//

import SwiftUI

@MainActor
struct TerminalSettingsView: View {
    let settings: TerminalThemeSettings
    private let locale: Locale

    init(settings: TerminalThemeSettings, locale: Locale = .current) {
        self.settings = settings
        self.locale = locale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.terminalThemeSettingsTitle)
                .font(.title2.weight(.semibold))

            Text(Strings.terminalThemeSettingsSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // MARK: - Appearance policy

            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.terminalAppearanceLabel)
                    .font(.headline)

                Picker(
                    Strings.terminalAppearanceLabel,
                    selection: Binding(
                        get: { settings.appearancePolicy },
                        set: { settings.appearancePolicy = $0 }
                    )
                ) {
                    ForEach(
                        TerminalAppearancePolicy.allCases,
                        id: \.self
                    ) { policy in
                        Text(LocalizedStringKey(policy.nameKey))
                            .tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(
                    AccessibilityID.terminalAppearancePicker
                )

                Text(Strings.terminalAppearanceHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // MARK: - Theme picker

            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.terminalThemeSelectionLabel)
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(
                            TerminalTheme.builtIn,
                            id: \.id
                        ) { theme in
                            themeRow(theme)
                        }
                    }
                }
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .environment(\.locale, locale)
    }

    // MARK: - Theme row with preview

    @ViewBuilder
    private func themeRow(_ theme: TerminalTheme) -> some View {
        let isSelected = settings.selectedThemeID == theme.id
        Button {
            settings.setTheme(id: theme.id)
        } label: {
            HStack(spacing: 12) {
                // Color swatch preview — shows both light and dark variants.
                swatchPreview(
                    light: theme.light,
                    dark: theme.dark
                )
                .frame(width: 88, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(theme.nameKey))
                        .foregroundStyle(.primary)
                    Text(Strings.terminalThemePreviewLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

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
        .accessibilityIdentifier("terminal-theme-row-\(theme.id)")
    }

    /// A compact two-half swatch: left half renders the dark variant's
    /// background + foreground accent colors, right half the light variant's.
    @ViewBuilder
    private func swatchPreview(
        light: TerminalColorScheme,
        dark: TerminalColorScheme
    ) -> some View {
        HStack(spacing: 0) {
            swatchHalf(dark)
            swatchHalf(light)
        }
    }

    @ViewBuilder
    private func swatchHalf(_ scheme: TerminalColorScheme) -> some View {
        ZStack {
            scheme.background.makeNSColor().suColor
            HStack(spacing: 1) {
                ForEach(0..<8, id: \.self) { index in
                    scheme.ansiColors[index]
                        .makeNSColor()
                        .suColor
                }
            }
            .padding(1)
        }
    }
}

// MARK: - NSColor → SwiftUI bridge

private extension NSColor {
    /// Converts to a SwiftUI `Color` in the sRGB color space.
    var suColor: Color {
        let resolved = usingColorSpace(.sRGB) ?? self
        return Color(
            srgbRed: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            opacity: resolved.alphaComponent
        )
    }
}
