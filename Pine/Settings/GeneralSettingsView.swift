//
//  GeneralSettingsView.swift
//  Pine
//
//  Issue #337: "General / Editor" pane of the consolidated Settings scene.
//  Surfaces the editor formatting defaults (EditorSettings), font size
//  (FontSizeSettings), and the default visibility of the minimap and word
//  wrap. Every control binds directly to the same source of truth used by
//  the File / View menus, so changes apply immediately and the menu
//  checkmarks stay in sync.
//

import SwiftUI

/// General / Editor preferences pane.
///
/// All toggles use immediate-apply semantics: there is no Apply button.
/// `EditorSettings` persists via `UserDefaults` `didSet`; font size, minimap,
/// and word wrap are bound to the same `@AppStorage` keys the menus and
/// editors observe, so a change here is instantly reflected everywhere.
@MainActor
struct GeneralSettingsView: View {
    @Bindable var editor: EditorSettings
    @Bindable var fontSizeSettings: FontSizeSettings
    @AppStorage("minimapVisible") private var defaultMinimapVisible = true
    @AppStorage("wordWrapEnabled") private var defaultWordWrap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.settingsGeneralTitle)
                .font(.title2.weight(.semibold))

            GroupBox(Strings.settingsGeneralFormatting) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        Strings.settingsGeneralInsertFinalNewline,
                        isOn: $editor.insertFinalNewline
                    )
                    Toggle(
                        Strings.settingsGeneralStripTrailingWhitespace,
                        isOn: $editor.stripTrailingWhitespace
                    )
                    Toggle(
                        Strings.settingsGeneralFormatOnSave,
                        isOn: $editor.formatOnSave
                    )
                    Toggle(
                        Strings.settingsGeneralSmartListContinuation,
                        isOn: $editor.smartListContinuation
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(Strings.settingsGeneralDisplay) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        Strings.settingsGeneralWordWrap,
                        isOn: $defaultWordWrap
                    )
                    Toggle(
                        Strings.settingsGeneralMinimap,
                        isOn: $defaultMinimapVisible
                    )

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        Text(Strings.settingsGeneralFontSize)
                        Slider(
                            value: $fontSizeSettings.fontSize,
                            in: FontSizeSettings.minSize ... FontSizeSettings.maxSize,
                            step: 1
                        ) {
                            Text(Strings.settingsGeneralFontSize)
                        } minimumValueLabel: {
                            Text("\(Int(FontSizeSettings.minSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("\(Int(FontSizeSettings.maxSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Int(fontSizeSettings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 500)
    }
}
